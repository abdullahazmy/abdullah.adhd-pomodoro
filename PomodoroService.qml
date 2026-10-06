import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Long-running Pomodoro service. One instance lives in the omarchy-shell
// process; the bar widget and popup panel reach into it via
// `bar.shell.serviceFor("abdullah.adhd-pomodoro")`.
//
// The service owns:
//   - Persistent state in ~/.local/state/abdullah.adhd-pomodoro/state.json
//     and an append-only history.jsonl, both written through the hardened
//     helper in bin/adhd-pomodoro-helper.py.
//   - IPC routes on `abdullah.adhd-pomodoro` for the panel and any future
//     CLI helper.
//
// Timing model: the service stores `phaseStartedAt` (epoch ms) and
// `phaseDurationSecs`, then computes `secondsLeft` from the wall clock.
// Two timers:
//
//   phaseTimer (single-shot) — armed for the next real event: the next
//                              pre-warning boundary or phase end, capped
//                              at 60 s so a suspend/resume is noticed
//                              promptly. No polling in between.
//
//   displayTick (1 s)        — runs only while the popup is open, to drive
//                              the panel's countdown. The bar widget keeps
//                              its own 1 Hz clock.
//
// State is written only when something actually changes (start, pause,
// phase end, a pre-warning firing, a settings edit) — never on a tick.
// A paused or idle plugin uses no timers at all.
Item {
  id: root

  // Shell injection, set by PluginFirstPartyServiceApi during mount. The
  // service tolerates it being null for the first few ticks.
  property var shell: null
  readonly property string omarchyPath: Quickshell.env("OMARCHY_PATH") || ""

  // ---- Paths ----------------------------------------------------------------
  readonly property string stateHome: (Quickshell.env("HOME") || "") + "/.local/state/abdullah.adhd-pomodoro"
  readonly property string statePath: stateHome + "/state.json"
  readonly property string historyPath: stateHome + "/history.jsonl"

  // Helper script that all file IO goes through. Resolved next to this
  // file so non-standard plugin locations work; override with
  // `ADHD_POMODORO_HOME` if needed.
  readonly property string pluginHome: (function() {
    var override = Quickshell.env("ADHD_POMODORO_HOME")
    if (override) return override
    var here = String(Qt.resolvedUrl("."))
    if (here.indexOf("file://") === 0) {
      return decodeURIComponent(here.substring(7)).replace(/\/$/, "")
    }
    return (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/abdullah.adhd-pomodoro"
  })()
  readonly property string helperScript: pluginHome + "/bin/adhd-pomodoro-helper.py"
  // -I: isolated (ignore PYTHON* env and user site), -S: skip `site`.
  // Cuts interpreter start-up time and memory for every helper call.
  readonly property var helperArgv: ["/usr/bin/python3", "-I", "-S", helperScript]

  function helperCommand(args) {
    return root.helperArgv.concat(args)
  }

  // State bodies and history lines carry task labels, so they must never
  // travel in argv: /proc/<pid>/cmdline is world-readable on a default
  // procfs mount. They go in the environment instead, and
  // /proc/<pid>/environ is readable only by the same user (and root).
  // argv carries nothing but the mode, the path and numeric limits.
  readonly property string payloadVar: "ADHD_POMODORO_PAYLOAD"

  function runHelperWithPayload(proc, args, payload) {
    var env = {}
    env[root.payloadVar] = payload
    proc.environment = env
    proc.command = helperCommand(args)
    proc.running = true
  }

  // Cap on a single state.json read. The document is a few hundred bytes.
  readonly property int stateMaxBytes: 262144     // 256 KiB
  // Cap on the history tail scanned for today's entries. A day of
  // sessions is a few KiB; the helper seeks to the tail and filters to
  // today, so only today's lines ever reach the shell.
  readonly property int historyMaxBytes: 65536    // 64 KiB

  // ---- Persistent state ----------------------------------------------------
  property string phase: Model.PHASE_IDLE
  // epoch ms when the current phase began; null while IDLE / PAUSED.
  property var phaseStartedAt: null
  property int phaseDurationSecs: 0
  // Frozen secondsLeft captured at pause time. Source of truth while
  // phase === PAUSED so a paused timer never drifts.
  property int phasePausedSecondsLeft: 0
  // The running phase a PAUSED timer will resume into.
  property string pausedPhase: ""
  property int completedWorkSessionsToday: 0
  property string lastResetDate: ""
  property string taskLabel: ""
  // Pre-warning seconds already announced in this phase.
  property var lastFiredWarningSeconds: []

  // Settings — mutated only through updateSettings(), which persists.
  property var settings: Model.defaultSettings()

  // ---- Derived live state --------------------------------------------------
  property int secondsLeft: 0

  // True while PAUSED at the very start of a phase, i.e. waiting for the
  // user to start the next block (autostartNext off).
  readonly property bool awaitingStart: phase === Model.PHASE_PAUSED
    && pausedPhase !== ""
    && phasePausedSecondsLeft === phaseDurationSecs

  function recomputeSeconds() {
    var s
    if (phase === Model.PHASE_PAUSED) {
      s = Math.max(0, phasePausedSecondsLeft)
    } else if (Model.isRunningPhase(phase) && phaseStartedAt && phaseDurationSecs) {
      s = Model.secondsLeftFromStart(phaseStartedAt, phaseDurationSecs, Date.now())
    } else {
      // IDLE: show the upcoming WORK duration.
      s = Model.phaseSeconds(Model.PHASE_WORK, settings)
    }
    if (s !== root.secondsLeft) root.secondsLeft = s
    return s
  }

  // Whether the popup wants second-resolution. Set by the bar widget.
  property bool popupOpen: false

  function setPopupOpen(open) {
    var next = !!open
    if (next === root.popupOpen) return
    root.popupOpen = next
    recomputeSeconds()
    displayTick.running = next && Model.isRunningPhase(root.phase)
  }

  // ---- Today's history (in memory) ------------------------------------------
  // Only today's entries are held, newest first. Loaded once at startup
  // (and again after midnight); completed sessions are prepended in
  // memory, so an append never triggers a re-read.
  property var todayEntries: []
  property string historyDay: ""
  property bool historyReadQueued: false

  function readHistory() {
    if (historyReadProc.running) {
      root.historyReadQueued = true
      return
    }
    root.historyDay = Model.todayKey()
    historyReadProc.command = helperCommand([
      "history-read", root.historyPath,
      String(root.historyMaxBytes), Model.localMidnightIso()
    ])
    historyReadProc.running = true
  }

  // Re-read only when the cached list belongs to an earlier day.
  function refreshHistory() {
    if (root.historyDay !== Model.todayKey()) readHistory()
  }

  Process {
    id: historyReadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: function(text) {
        var t = text === undefined || text === null ? "" : String(text)
        // Sentinel on the first line: NO_HISTORY, HISTORY_OK or
        // HISTORY_TRUNCATED. The helper already dropped partial lines
        // and everything before local midnight.
        var nl = t.indexOf("\n")
        var head = nl >= 0 ? t.substring(0, nl) : t
        var body = (head === "HISTORY_OK" || head === "HISTORY_TRUNCATED") && nl >= 0
          ? t.substring(nl + 1) : ""
        root.todayEntries = Model.todayHistoryEntries(Model.parseHistoryFile(body))
      }
    }
    onExited: {
      if (root.historyReadQueued) {
        root.historyReadQueued = false
        root.readHistory()
      }
    }
  }

  // Lines that arrived while a previous append was still running.
  property var pendingHistoryLines: []

  function appendHistory(entry) {
    var line = Model.formatHistoryLine(entry)
    if (line.indexOf("\n") >= 0) {
      console.warn("adhd-pomodoro: refusing to append history line containing newline")
      return
    }
    // Keep the in-memory list current without touching the disk again.
    var today = Model.todayKey()
    if (root.historyDay !== today) {
      root.historyDay = today
      root.todayEntries = []
    }
    root.todayEntries = [entry].concat(root.todayEntries)

    if (historyAppendProc.running) {
      root.pendingHistoryLines = root.pendingHistoryLines.concat([line])
      return
    }
    runHelperWithPayload(historyAppendProc, ["history-append", root.historyPath], line)
  }

  Process {
    id: historyAppendProc
    onExited: {
      if (root.pendingHistoryLines.length === 0) return
      var next = root.pendingHistoryLines[0]
      root.pendingHistoryLines = root.pendingHistoryLines.slice(1)
      root.runHelperWithPayload(historyAppendProc, ["history-append", root.historyPath], next)
    }
  }

  // ---- Persistence ----------------------------------------------------------
  function buildStateObject() {
    return {
      phase: root.phase,
      phaseStartedAt: root.phaseStartedAt,
      phaseDurationSecs: root.phaseDurationSecs,
      phasePausedSecondsLeft: root.phasePausedSecondsLeft,
      pausedPhase: root.pausedPhase,
      completedWorkSessionsToday: root.completedWorkSessionsToday,
      lastResetDate: root.lastResetDate,
      taskLabel: root.taskLabel,
      settings: root.settings,
      lastFiredWarningSeconds: root.lastFiredWarningSeconds
    }
  }

  // Last-write-wins queue: every body carries the full state, so only the
  // newest one needs to reach disk.
  property string pendingStateBody: ""
  // Don't write until the initial read has finished, or a save racing
  // the read would clobber the user's stored state with defaults.
  property bool stateLoaded: false

  function saveState() {
    if (!root.stateLoaded) return
    var body = JSON.stringify(buildStateObject()) + "\n"
    if (stateWriteProc.running) {
      root.pendingStateBody = body
      return
    }
    runHelperWithPayload(stateWriteProc, ["state-write", root.statePath], body)
  }

  Process {
    id: stateWriteProc
    onExited: {
      if (root.pendingStateBody === "") return
      var queued = root.pendingStateBody
      root.pendingStateBody = ""
      root.runHelperWithPayload(stateWriteProc, ["state-write", root.statePath], queued)
    }
  }

  Process {
    id: stateReadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: function(text) {
        var t = text === undefined || text === null ? "" : String(text)
        var nl = t.indexOf("\n")
        var head = nl >= 0 ? t.substring(0, nl) : t
        var body = nl >= 0 ? t.substring(nl + 1) : ""
        root.stateLoaded = true
        if (head !== "STATE_OK") {
          // NO_STATE: first run, write a clean file. A truncated
          // (suspicious) file or a helper error: run on defaults but
          // leave the file alone until the user changes something.
          root.applyState(Model.defaultState())
          if (head === "NO_STATE") root.saveState()
          return
        }
        root.applyState(Model.rolloverIfNewDay(Model.parseStateFile(body)))
      }
    }
  }

  function applyState(s) {
    if (Model.isRunningPhase(s.phase) && !s.phaseStartedAt) s.phase = Model.PHASE_IDLE
    root.phase = s.phase
    root.phaseStartedAt = s.phaseStartedAt
    root.phaseDurationSecs = s.phaseDurationSecs
    root.phasePausedSecondsLeft = s.phasePausedSecondsLeft
    root.pausedPhase = s.pausedPhase || ""
    root.completedWorkSessionsToday = s.completedWorkSessionsToday
    root.lastResetDate = s.lastResetDate
    root.taskLabel = s.taskLabel
    root.settings = s.settings
    root.lastFiredWarningSeconds = s.lastFiredWarningSeconds
    recomputeSeconds()
    rescheduleTimers()
  }

  // ---- Phase transitions ----------------------------------------------------

  function phaseSeconds(phaseName) {
    return Model.phaseSeconds(phaseName, root.settings)
  }

  // Move into `next`. With `run` false the phase is parked as PAUSED at
  // full duration so the user starts it with one click.
  function enterPhase(next, run) {
    var duration = phaseSeconds(next)
    root.phaseDurationSecs = duration
    root.lastFiredWarningSeconds = []
    if (run) {
      root.phase = next
      root.phaseStartedAt = Date.now()
      root.phasePausedSecondsLeft = 0
      root.pausedPhase = ""
    } else {
      root.phaseStartedAt = null
      root.phasePausedSecondsLeft = duration
      root.pausedPhase = next
      root.phase = Model.PHASE_PAUSED
    }
  }

  function commit() {
    recomputeSeconds()
    rescheduleTimers()
    saveState()
  }

  function start() {
    if (root.phase === Model.PHASE_PAUSED) {
      resume()
      return
    }
    if (Model.isRunningPhase(root.phase)) return
    enterPhase(Model.PHASE_WORK, true)
    commit()
  }

  function pause() {
    if (!Model.isRunningPhase(root.phase)) return
    // Freeze the countdown so it reads the same however long we stay paused.
    root.phasePausedSecondsLeft = recomputeSeconds()
    root.pausedPhase = root.phase
    root.phaseStartedAt = null
    root.phase = Model.PHASE_PAUSED
    commit()
  }

  function resume() {
    if (root.phase !== Model.PHASE_PAUSED) return
    var phaseName = Model.isRunningPhase(root.pausedPhase) ? root.pausedPhase : inferPhaseFromPaused()
    var duration = root.phaseDurationSecs > 0 ? root.phaseDurationSecs : phaseSeconds(phaseName)
    var remaining = Math.min(duration, Math.max(0, root.phasePausedSecondsLeft))
    var fresh = remaining === duration
    root.phase = phaseName
    root.phaseDurationSecs = duration
    root.phaseStartedAt = Date.now() - (duration - remaining) * 1000
    root.phasePausedSecondsLeft = 0
    root.pausedPhase = ""
    if (fresh) announcePhaseStart(phaseName)
    commit()
  }

  function reset() {
    root.phase = Model.PHASE_IDLE
    root.phaseStartedAt = null
    root.phaseDurationSecs = 0
    root.phasePausedSecondsLeft = 0
    root.pausedPhase = ""
    root.lastFiredWarningSeconds = []
    commit()
  }

  function skip() {
    var current = root.phase === Model.PHASE_PAUSED ? root.pausedPhase : root.phase
    if (root.phase === Model.PHASE_PAUSED && !Model.isRunningPhase(current)) current = Model.PHASE_WORK
    if (!Model.isRunningPhase(current)) return
    var next = Model.nextPhase(current, root.completedWorkSessionsToday, root.settings)
    enterPhase(next, true)
    announcePhaseStart(next)
    commit()
  }

  function setTask(label) {
    var next = String(label || "").trim()
    if (next === root.taskLabel) return
    root.taskLabel = next
    saveState()
  }

  function updateSettings(newSettings) {
    if (!newSettings || typeof newSettings !== "object") return
    var merged = Model.mergeSettings(newSettings)
    merged.workMinutes = clamp(Number(merged.workMinutes) || 25, 1, 180)
    merged.shortBreakMinutes = clamp(Number(merged.shortBreakMinutes) || 5, 1, 60)
    merged.longBreakMinutes = clamp(Number(merged.longBreakMinutes) || 15, 1, 90)
    merged.longBreakInterval = clamp(Number(merged.longBreakInterval) || 4, 2, 12)
    merged.dailyGoal = clamp(Number(merged.dailyGoal) || 8, 1, 30)
    merged.soundOnPhaseEnd = !!merged.soundOnPhaseEnd
    merged.autostartNext = !!merged.autostartNext
    merged.preWarningSeconds = merged.preWarningSeconds
      .map(function(n) { return Math.floor(Number(n)) })
      .filter(function(n) { return isFinite(n) && n > 0 })
      .slice(0, 8)
    if (merged.preWarningSeconds.length === 0) merged.preWarningSeconds = [120, 30]
    if (JSON.stringify(merged) === JSON.stringify(root.settings)) return
    root.settings = merged
    // A parked phase that hasn't started yet picks up the new length.
    if (root.awaitingStart) {
      var d = phaseSeconds(root.pausedPhase || Model.PHASE_WORK)
      root.phaseDurationSecs = d
      root.phasePausedSecondsLeft = d
    }
    commit()
  }

  function clamp(n, lo, hi) { return Math.max(lo, Math.min(hi, n)) }

  function inferPhaseFromPaused() {
    // Legacy state files (pre-0.1.13) did not store pausedPhase; infer it
    // from the duration, defaulting to WORK.
    var d = root.phaseDurationSecs
    if (d === phaseSeconds(Model.PHASE_SHORT_BREAK)) return Model.PHASE_SHORT_BREAK
    if (d === phaseSeconds(Model.PHASE_LONG_BREAK)) return Model.PHASE_LONG_BREAK
    return Model.PHASE_WORK
  }

  // ---- Timers ---------------------------------------------------------------

  Timer {
    id: phaseTimer
    repeat: false
    onTriggered: root.phaseTimerFired()
  }

  Timer {
    id: displayTick
    interval: 1000
    repeat: true
    onTriggered: root.recomputeSeconds()
  }

  function rescheduleTimers() {
    if (!Model.isRunningPhase(root.phase)) {
      phaseTimer.stop()
      displayTick.running = false
      return
    }
    displayTick.running = root.popupOpen
    var s = recomputeSeconds()
    if (s <= 0) {
      phaseTimer.interval = 1
      phaseTimer.restart()
      return
    }
    var pending = root.phase === Model.PHASE_WORK
      ? Model.pendingWarnings(root.settings.preWarningSeconds, root.lastFiredWarningSeconds, root.phaseDurationSecs)
      : []
    var boundary = Model.nextWakeBoundary(s, pending)
    // Wall-clock instant at which secondsLeft reaches `boundary`, plus a
    // small margin because coarse timers may fire a little early.
    var dueAt = root.phaseStartedAt + (root.phaseDurationSecs - boundary) * 1000 + 50
    phaseTimer.interval = Math.max(50, Math.min(60000, dueAt - Date.now()))
    phaseTimer.restart()
  }

  function phaseTimerFired() {
    if (!Model.isRunningPhase(root.phase)) return
    var s = recomputeSeconds()
    if (s <= 0) {
      finishPhase()
      return
    }
    if (root.phase === Model.PHASE_WORK) fireDueWarnings(s)
    rescheduleTimers()
  }

  // Announce the closest pre-warning we have crossed. Boundaries crossed
  // long ago (e.g. resuming at 1:40 with a 2:00 warning) are marked as
  // fired without a stale notification.
  function fireDueWarnings(s) {
    var pending = Model.pendingWarnings(root.settings.preWarningSeconds, root.lastFiredWarningSeconds, root.phaseDurationSecs)
    var crossed = pending.filter(function(t) { return s <= t })
    if (crossed.length === 0) return
    root.lastFiredWarningSeconds = root.lastFiredWarningSeconds.concat(crossed)
    var closest = crossed[crossed.length - 1]
    if (closest - s <= 5) notifyPreWarning(closest)
    saveState()
  }

  function finishPhase() {
    var justFinished = root.phase
    var today = Model.todayKey()
    if (root.lastResetDate !== today) {
      root.completedWorkSessionsToday = 0
      root.lastResetDate = today
    }
    if (justFinished === Model.PHASE_WORK) {
      root.completedWorkSessionsToday = root.completedWorkSessionsToday + 1
      appendHistory({
        ts: new Date().toISOString(),
        taskLabel: root.taskLabel || "",
        plannedMinutes: Math.round(root.phaseDurationSecs / 60),
        actualSeconds: root.phaseDurationSecs
      })
    }
    var next = Model.nextPhase(justFinished, root.completedWorkSessionsToday, root.settings)
    var run = !!root.settings.autostartNext
    enterPhase(next, run)

    announcePhaseEnd(justFinished, next, run)
    if (run) announcePhaseStart(next)
    commit()
  }

  // ---- Notifications + sound ----------------------------------------------

  // Notification text is passed to omarchy-notification-send as argv,
  // which other local users can read via /proc, so it never includes the
  // task label — only fixed, non-personal strings.
  function notify(headline, body, urgency) {
    if (!root.omarchyPath) return
    Quickshell.execDetached([
      root.omarchyPath + "/bin/omarchy-notification-send",
      "-u", urgency || "normal", "-a", "ADHD Pomodoro", headline, body
    ])
  }

  function notifyPreWarning(seconds) {
    var body = "Wrap up your current task"
    var left = seconds >= 60 && seconds % 60 === 0 ? (seconds / 60) + " min" : seconds + "s"
    notify(left + " left in focus", body, "low")
  }

  function announcePhaseEnd(phaseName, next, run) {
    var upNext = run ? "" : " Click the bar to start the " + Model.phaseLabel(next).toLowerCase() + "."
    if (phaseName === Model.PHASE_WORK) {
      notify("Focus complete", "Nice work. Time for a break." + upNext, "normal")
    } else {
      notify(Model.phaseLabel(phaseName) + " over", "Back to focus." + upNext, "normal")
    }
    playChime()
  }

  function announcePhaseStart(phaseName) {
    if (phaseName === Model.PHASE_WORK) {
      notify("Focus starts now", "Starting focus.", "low")
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

  // ---- IPC -----------------------------------------------------------------
  //
  // Routes on `abdullah.adhd-pomodoro` for the panel and any future CLI:
  //   start, pause, resume, reset, skip, toggleSound
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
      try { parsed = JSON.parse(jsonString || "{}") } catch (e) { return }
      root.updateSettings(Object.assign({}, root.settings, parsed))
    }

    function status(): var {
      root.recomputeSeconds()
      return {
        phase: root.phase,
        pausedPhase: root.pausedPhase,
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
      root.refreshHistory()
      return root.todayEntries
    }

    function refreshHistory(): void { root.readHistory() }

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
    function setPanelOpen(open: bool): void { root.setPopupOpen(open) }
  }

  // ---- Startup ----------------------------------------------------------------
  // Create the state directory with mode 0700 (the helper refuses to
  // operate otherwise), then load state and today's history.
  Process {
    id: mkdirProc
    command: ["mkdir", "-p", "-m", "0700", root.stateHome]
    onExited: {
      stateReadProc.command = root.helperCommand(["state-read", root.statePath, String(root.stateMaxBytes)])
      stateReadProc.running = true
      root.readHistory()
    }
  }

  Component.onCompleted: mkdirProc.running = true

  Component.onDestruction: {
    phaseTimer.stop()
    displayTick.running = false
  }
}
