import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Long-running Pomodoro service. One instance lives in the omarchy-shell
// process; the bar widget and popup panel reach into it via
// `bar.shell.serviceFor("abdullah.adhd-pomodoro")`.
//
// The service owns:
//   - The wall-clock Timer that ticks once per second while running.
//   - Persistent state in ~/.local/state/abdullah.adhd-pomodoro/state.json
//     (atomic write via FileView) and an append-only history file.
//   - IPC routes on `abdullah.adhd-pomodoro` for the panel and any future
//     CLI helper.
//
// The bar widget reads reactive properties off this object; the popup panel
// calls the public methods (start/pause/resume/reset/skip/setTask/updateSettings).
Item {
  id: root

  // Shell injection, set by PluginFirstPartyServiceApi during mount. The
  // service tolerates it being null for the first few ticks.
  property var shell: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  // ---- Paths ----------------------------------------------------------------
  readonly property string stateHome: (Quickshell.env("HOME") || "") + "/.local/state/abdullah.adhd-pomodoro"
  readonly property string statePath: stateHome + "/state.json"
  readonly property string historyPath: stateHome + "/history.jsonl"

  // ---- Live state (mirror of state.json, republish on every tick) ----------
  // These are reactive so bar widgets and the popup panel can bind directly.
  property string phase: Model.PHASE_IDLE
  property int secondsLeft: 0
  property int completedWorkSessionsToday: 0
  property string lastResetDate: ""
  property string taskLabel: ""
  // Last-fired-seconds memo is not exposed to the bar; it lives only on
  // this object so we can de-dupe pre-warning notifications.
  property var lastFiredWarningSeconds: []

  // Settings — mutated only through updateSettings(), which persists.
  property var settings: Model.defaultSettings()

  // ---- Load on startup ------------------------------------------------------
  Component.onCompleted: {
    // Ensure ~/.local/state/abdullah.adhd-pomodoro exists, then reload
    // the state and history files. mkdirProc triggers the reload on exit.
    mkdirProc.running = true
  }

  // ---- File-backed state ----------------------------------------------------
  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var parsed = Model.parseStateFile(text())
      Model.rolloverIfNewDay(parsed)
      applyParsedState(parsed)
    }
    onLoadFailed: {
      // Missing or unreadable: persist defaults so future saves are clean.
      saveState()
    }
    onFileChanged: reload()
  }

  FileView {
    id: historyFile
    path: root.historyPath
    watchChanges: true
    atomicWrites: false    // append-only; one line per completed WORK session
    printErrors: false
  }

  function applyParsedState(parsed) {
    root.phase = parsed.phase
    root.secondsLeft = parsed.secondsLeft
    root.completedWorkSessionsToday = parsed.completedWorkSessionsToday
    root.lastResetDate = parsed.lastResetDate
    root.taskLabel = parsed.taskLabel
    root.settings = parsed.settings
    root.lastFiredWarningSeconds = parsed.lastFiredWarningSeconds
    broadcastStatus()
  }

  // ---- Persistence ----------------------------------------------------------
  function buildStateObject() {
    return {
      phase: root.phase,
      secondsLeft: root.secondsLeft,
      completedWorkSessionsToday: root.completedWorkSessionsToday,
      lastResetDate: root.lastResetDate,
      taskLabel: root.taskLabel,
      settings: root.settings,
      lastFiredWarningSeconds: root.lastFiredWarningSeconds
    }
  }

  function saveState() {
    stateFile.setText(JSON.stringify(buildStateObject(), null, 2) + "\n")
  }

  function appendHistory(entry) {
    // Append a single JSONL line. The FileView is loaded on demand so the
    // current text() may be empty if the file does not yet exist.
    var existing = historyFile.text() || ""
    var sep = existing.length > 0 && existing.charAt(existing.length - 1) !== "\n" ? "\n" : ""
    historyFile.setText(existing + sep + Model.formatHistoryLine(entry) + "\n")
  }

  // ---- Phase transitions ----------------------------------------------------

  function phaseSeconds(phaseName) {
    return Model.phaseMinutes(phaseName, root.settings) * 60
  }

  function start() {
    // If we were paused, resume into the same phase. Otherwise, start a
    // fresh WORK block. The panel UI is the primary caller; IPC `start` is
    // here so an external CLI helper could kick the timer too.
    if (root.phase === Model.PHASE_PAUSED) {
      // Resume: figure out which phase we paused in from settings + state.
      // We store the paused phase implicitly by leaving secondsLeft where it
      // was, but phase itself says PAUSED. Easiest: infer from secondsLeft.
      var resumed = inferPhaseFromSecondsLeft()
      if (resumed) root.phase = resumed
    }
    if (!Model.isRunningPhase(root.phase)) {
      root.phase = Model.PHASE_WORK
      root.secondsLeft = phaseSeconds(Model.PHASE_WORK)
      root.lastFiredWarningSeconds = []
    }
    tickTimer.running = true
    saveState()
    broadcastStatus()
  }

  function pause() {
    if (!Model.isRunningPhase(root.phase)) return
    tickTimer.running = false
    root.phase = Model.PHASE_PAUSED
    saveState()
    broadcastStatus()
  }

  function resume() {
    if (root.phase !== Model.PHASE_PAUSED) return
    var resumed = inferPhaseFromSecondsLeft()
    if (resumed) root.phase = resumed
    tickTimer.running = true
    saveState()
    broadcastStatus()
  }

  function reset() {
    tickTimer.running = false
    root.phase = Model.PHASE_IDLE
    root.secondsLeft = phaseSeconds(Model.PHASE_WORK)
    root.lastFiredWarningSeconds = []
    saveState()
    broadcastStatus()
  }

  function skip() {
    // Move to the next phase immediately without recording history (the work
    // block was not actually completed).
    if (!Model.isRunningPhase(root.phase)) {
      // If we were paused mid-WORK, treat as a skip from WORK.
      if (root.phase === Model.PHASE_PAUSED) {
        root.phase = Model.PHASE_WORK
      } else {
        return
      }
    }
    var justFinished = root.phase
    var next = Model.nextPhase(justFinished, root.completedWorkSessionsToday, root.settings)
    tickTimer.running = false
    root.phase = next
    root.secondsLeft = phaseSeconds(next)
    root.lastFiredWarningSeconds = []
    announcePhaseStart(next)
    tickTimer.running = Model.isRunningPhase(next)
    saveState()
    broadcastStatus()
  }

  function setTask(label) {
    root.taskLabel = String(label || "").trim()
    saveState()
    broadcastStatus()
  }

  function updateSettings(newSettings) {
    if (!newSettings || typeof newSettings !== "object") return
    var merged = Model.mergeSettings(newSettings)
    // Clamp to sane bounds.
    merged.workMinutes = clamp(Number(merged.workMinutes) || 25, 1, 180)
    merged.shortBreakMinutes = clamp(Number(merged.shortBreakMinutes) || 5, 1, 60)
    merged.longBreakMinutes = clamp(Number(merged.longBreakMinutes) || 15, 1, 90)
    merged.longBreakInterval = clamp(Number(merged.longBreakInterval) || 4, 2, 12)
    merged.dailyGoal = clamp(Number(merged.dailyGoal) || 8, 1, 30)
    merged.soundOnPhaseEnd = !!merged.soundOnPhaseEnd
    merged.autostartNext = !!merged.autostartNext
    if (!Array.isArray(merged.preWarningSeconds)) merged.preWarningSeconds = [120, 30]
    root.settings = merged
    saveState()
    broadcastStatus()
  }

  function clamp(n, lo, hi) { return Math.max(lo, Math.min(hi, n)); }

  function inferPhaseFromSecondsLeft() {
    // We don't persist the paused phase explicitly, but we can pick the
    // closest one based on secondsLeft. This is good enough for the
    // short-lived PAUSED state.
    var s = root.secondsLeft
    if (s === phaseSeconds(Model.PHASE_WORK)) return Model.PHASE_WORK
    if (s === phaseSeconds(Model.PHASE_SHORT_BREAK)) return Model.PHASE_SHORT_BREAK
    if (s === phaseSeconds(Model.PHASE_LONG_BREAK)) return Model.PHASE_LONG_BREAK
    // Fall back: if it's close to work duration, treat as WORK.
    if (s > phaseSeconds(Model.PHASE_LONG_BREAK)) return Model.PHASE_WORK
    return Model.PHASE_WORK
  }

  // ---- Tick -----------------------------------------------------------------

  Timer {
    id: tickTimer
    interval: 1000
    running: false
    repeat: true
    onTriggered: root.tick()
  }

  function tick() {
    if (!Model.isRunningPhase(root.phase)) return
    root.secondsLeft = root.secondsLeft - 1

    // Pre-warning notifications.
    if (Model.shouldFirePreWarning(root.secondsLeft, root.settings.preWarningSeconds, root.lastFiredWarningSeconds)) {
      // Only fire one notification per tick — pick the first matching second.
      for (var i = 0; i < root.settings.preWarningSeconds.length; i++) {
        var t = Number(root.settings.preWarningSeconds[i])
        if (t === root.secondsLeft && root.lastFiredWarningSeconds.indexOf(t) === -1) {
          root.lastFiredWarningSeconds = root.lastFiredWarningSeconds.concat([t])
          notifyPreWarning(t)
          break
        }
      }
    }

    if (root.secondsLeft <= 0) {
      finishPhase()
    } else {
      saveState()
    }
    broadcastStatus()
  }

  function finishPhase() {
    var justFinished = root.phase
    var historyEntry = null
    if (justFinished === Model.PHASE_WORK) {
      historyEntry = {
        ts: new Date().toISOString(),
        taskLabel: root.taskLabel || "",
        plannedMinutes: root.settings.workMinutes,
        actualSeconds: root.settings.workMinutes * 60
      }
      root.completedWorkSessionsToday = root.completedWorkSessionsToday + 1
    }
    var next = Model.nextPhase(justFinished, root.completedWorkSessionsToday, root.settings)
    tickTimer.running = false
    root.phase = next
    root.secondsLeft = phaseSeconds(next)
    root.lastFiredWarningSeconds = []

    if (historyEntry) appendHistory(historyEntry)
    announcePhaseEnd(justFinished)
    announcePhaseStart(next)

    // Autostart behaviour is opt-in; default off (ADHD: breaks the
    // auto-cycle guilt trap).
    if (root.settings.autostartNext && Model.isRunningPhase(next)) {
      tickTimer.running = true
    }
    saveState()
  }

  // ---- Notifications + sound ----------------------------------------------

  function notify(headline, body, urgency) {
    var u = urgency || "normal"
    var args = [omarchyPath + "/bin/omarchy-notification-send", "-u", u, "-a", "ADHD Pomodoro", headline, body]
    Quickshell.execDetached(args)
  }

  function notifyPreWarning(seconds) {
    var body = root.taskLabel
      ? ("Wrap up: " + root.taskLabel)
      : "Wrap up your current task"
    notify(seconds + "s left in " + Model.phaseLabel(root.phase).toLowerCase(), body, "low")
  }

  function announcePhaseEnd(phaseName) {
    if (phaseName === Model.PHASE_WORK) {
      notify("Focus complete", root.taskLabel ? ("Nice work on: " + root.taskLabel) : "Time for a break.", "normal")
    } else if (phaseName === Model.PHASE_LONG_BREAK) {
      notify("Long break over", "Back to focus.", "normal")
    }
    playChime()
  }

  function announcePhaseStart(phaseName) {
    if (phaseName === Model.PHASE_WORK) {
      notify("Focus starts now", root.taskLabel ? ("Focus: " + root.taskLabel) : "Starting focus.", "low")
    } else if (phaseName === Model.PHASE_SHORT_BREAK) {
      notify("Short break", "Step away for a few minutes.", "low")
    } else if (phaseName === Model.PHASE_LONG_BREAK) {
      notify("Long break", "You've earned it. Step away.", "low")
    }
  }

  function playChime() {
    if (!root.settings.soundOnPhaseEnd) return
    // Best-effort sound — failures are silent (no paplay / no .oga file).
    Quickshell.execDetached(["sh", "-c",
      "(paplay /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null || " +
      "paplay /usr/share/sounds/freedesktop/stereo/bell.oga 2>/dev/null || true)"])
  }

  // ---- Broadcast to bar widgets and panels --------------------------------
  //
  // Both `phase`, `secondsLeft`, and friends are reactive QML properties, so
  // any widget bound to them re-renders automatically on tick. The
  // broadcastStatus() call here exists so an external caller can explicitly
  // ask for a refresh (e.g. after IPC start) without waiting for a tick.

  function broadcastStatus() {
    // No-op today: reactive properties already drive widgets. Kept as an
    // explicit hook so a future CLI helper or a "refresh now" IPC route has
    // a single place to fan out from.
  }

  // ---- IPC -----------------------------------------------------------------
  //
  // Routes on `abdullah.adhd-pomodoro` for the panel and any future CLI:
  //   start, pause, resume, reset, skip
  //   setTask <label>
  //   updateSettings <json>
  //   status (returns a snapshot object)
  //   history (returns today's history array)
  //   openPanel, closePanel, togglePanel

  IpcHandler {
    target: "abdullah.adhd-pomodoro"

    function start(): void { root.start() }
    function pause(): void { root.pause() }
    function resume(): void { root.resume() }
    function reset(): void { root.reset() }
    function skip(): void { root.skip() }
    function toggleSound(): void {
      var next = Object.assign({}, root.settings)
      next.soundOnPhaseEnd = !next.soundOnPhaseEnd
      root.updateSettings(next)
    }
    function setTask(label: string): void { root.setTask(label || "") }
    function updateSettings(jsonString: string): void {
      var parsed
      try { parsed = JSON.parse(jsonString || "{}") } catch (e) { parsed = ({}) }
      root.updateSettings(parsed)
    }

    function status(): var {
      return {
        phase: root.phase,
        secondsLeft: root.secondsLeft,
        completedWorkSessionsToday: root.completedWorkSessionsToday,
        dailyGoal: root.settings.dailyGoal,
        taskLabel: root.taskLabel,
        settings: root.settings,
        phaseLabel: Model.phaseLabel(root.phase),
        phaseGlyph: Model.phaseGlyph(root.phase),
        mmss: Model.formatMMSS(root.secondsLeft)
      }
    }

    function history(): var {
      var entries = Model.parseHistoryFile(historyFile.text())
      return Model.todayHistoryEntries(entries)
    }

    function openPanel(): void {
      if (root.shell && typeof root.shell.summon === "function") {
        try { root.shell.summon("abdullah.adhd-pomodoro", "{}") } catch (e) { /* ignored */ }
      }
    }
    function closePanel(): void {
      if (root.shell && typeof root.shell.hide === "function") {
        try { root.shell.hide("abdullah.adhd-pomodoro") } catch (e) { /* ignored */ }
      }
    }
    function togglePanel(): void {
      if (root.shell && typeof root.shell.toggle === "function") {
        try { root.shell.toggle("abdullah.adhd-pomodoro") } catch (e) { /* ignored */ }
      }
    }
  }

  // ---- Process for directory bootstrap -------------------------------------
  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.stateHome]
    onExited: {
      stateFile.reload()
      historyFile.reload()
      broadcastStatus()
    }
  }

  Component.onDestruction: {
    tickTimer.running = false
    saveState()
  }
}
