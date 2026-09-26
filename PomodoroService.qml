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
//     (atomic write via FileView) and an append-only history file.
//   - IPC routes on `abdullah.adhd-pomodoro` for the panel and any future
//     CLI helper.
//
// Timing model (v0.1.5+): the service stores `phaseStartedAt` (epoch ms)
// and `phaseDurationSecs`, then computes `secondsLeft` on demand from the
// wall clock. Two timers:
//
//   slowTick (60s)        — runs while a phase is active. Handles phase-end
//                           detection, recomputes secondsLeft so the bar
//                           stays within a second of true time, and fires
//                           any pre-warning notifications whose boundary
//                           fell inside the minute we just slept through.
//
//   fastTick (1s)         — runs only while the popup is open or while
//                           secondsLeft <= 60. Drives the visible
//                           countdown to second resolution and detects
//                           phase end promptly in the last minute.
//
// A paused or idle plugin uses no timers at all.
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

  // Helper script that all sensitive file IO is shelled through. Defaults
  // to the canonical third-party install location. Override with
  // `ADHD_POMODORO_HOME` for non-standard layouts.
  readonly property string pluginHome: (function() {
    var override = Quickshell.env("ADHD_POMODORO_HOME")
    if (override) return override
    return (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/abdullah.adhd-pomodoro"
  })()
  readonly property string helperScript: pluginHome + "/bin/adhd-pomodoro-helper.py"
  readonly property string pythonBin: "/usr/bin/python3"

  // Cap on a single state.json read. The state document is small (a
  // few hundred bytes); 256 KiB is plenty of headroom and still small
  // enough to be safe if someone plants a huge file at the path.
  readonly property int stateMaxBytes: 262144    // 256 KiB hard cap

  // ---- Persistent state ----------------------------------------------------
  // `phase`, `phaseStartedAt`, `phaseDurationSecs`, and
  // `phasePausedSecondsLeft` mirror state.json. Reactive so the bar and
  // popup can bind to them. `secondsLeft` is *not* stored — it is derived
  // from the wall clock and the timestamp fields via the function below.
  property string phase: Model.PHASE_IDLE
  // epoch ms when the current phase began; null while IDLE.
  property var phaseStartedAt: null
  property int phaseDurationSecs: 0
  // Frozen secondsLeft captured at pause time. Source of truth while
  // phase === PAUSED so a paused timer never drifts.
  property int phasePausedSecondsLeft: 0
  property int completedWorkSessionsToday: 0
  property string lastResetDate: ""
  property string taskLabel: ""
  // Memo of pre-warning seconds we have already announced in this phase.
  property var lastFiredWarningSeconds: []

  // Settings — mutated only through updateSettings(), which persists.
  property var settings: Model.defaultSettings()

  // ---- Derived live state --------------------------------------------------
  // Cached integer recomputed by `recomputeSeconds()` so that bindings on
  // the bar widget update on every tick (or on every slowTick, when the
  // popup is closed). When IDLE or PAUSED, returns the static value.
  property int secondsLeft: 0

  function recomputeSeconds() {
    var s
    if (phase === Model.PHASE_PAUSED) {
      s = Math.max(0, phasePausedSecondsLeft)
    } else if (Model.isRunningPhase(phase) && phaseStartedAt && phaseDurationSecs) {
      s = Model.secondsLeftFromStart(phaseStartedAt, phaseDurationSecs, Date.now())
    } else {
      // IDLE: nothing running. Show the upcoming WORK duration so the
      // panel can render the "Start focus" hero with a sensible number.
      s = Model.phaseSeconds(Model.PHASE_WORK, settings)
    }
    if (s !== root.secondsLeft) root.secondsLeft = s
    return s
  }

  // Whether the popup wants second-resolution. Set by the bar widget and
  // panel as they open/close. Cleared on destruction.
  property bool popupOpen: false

  function setPopupOpen(open) {
    var next = !!open
    if (next === root.popupOpen) return
    root.popupOpen = next
    // Toggling the popup may move us in or out of the "last minute"
    // fast-tick window. Recompute and reschedule.
    if (Model.isRunningPhase(root.phase)) rescheduleTimers()
  }

  // ---- Load on startup ------------------------------------------------------
  Component.onCompleted: {
    mkdirProc.running = true
  }

  // ---- File-backed state ----------------------------------------------------
  // The state file is loaded and saved via the secure helper script
  // (`bin/adhd-pomodoro-helper.py`). The helper checks that the file is
  // a regular file (not a symlink), bounds reads to ~256 KiB, opens
  // writes with O_NOFOLLOW, and persists them via an atomic rename().
  // FileView here is watch-only — we never call `text()` on it, so we
  // never load the file path blindly into memory. We deliberately do
  // NOT auto-trigger stateReadProc on the FileView's onFileChanged,
  // because our own helper writes touch the file and would otherwise
  // create a write/read loop.
  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: false   // helper does its own atomic write
    blockLoading: true    // never preload
    blockAllReads: true   // never let text() succeed
    printErrors: false
  }

  // Watch-only FileView for history.jsonl. Used to detect external
  // writes (e.g. another process appends) so we can refresh.
  FileView {
    id: historyWatcher
    path: root.historyPath
    watchChanges: true
    atomicWrites: false
    blockLoading: true    // never preload
    blockAllReads: true   // never let text() succeed
    printErrors: false
    onFileChanged: historyReadProc.running = true
  }

  // ---- History file: bounded read, append-via-Process -------------------
  //
  // history.jsonl is append-only and grows forever, so we deliberately
  // do NOT load it through FileView — that would put the whole file in
  // memory and stay there for the lifetime of the shell. All read and
  // append IO goes through `bin/adhd-pomodoro-helper.py`, which:
  //   * verifies the parent directory is owned by the running user and
  //     is not group/world-writable;
  //   * verifies the path is a regular file (rejects symlinks, FIFOs,
  //     /dev/zero redirects) before opening it;
  //   * bounds reads to 1 MiB (~5000 session lines);
  //   * appends via `fcntl.flock(LOCK_EX)` + `O_WRONLY|O_APPEND|O_NOFOLLOW`
  //     so concurrent appenders serialize and a planted symlink cannot
  //     redirect writes off-host.
  readonly property int historyMaxBytes: 1048576    // 1 MiB hard cap
  // Pending read result, populated by historyReadProc. Empty until the
  // first read completes after startup or after onHistoryFileChanged.
  property string pendingHistoryText: ""
  // Pending read error message, populated when the bound process fails
  // (file missing, regular-file check failed, symlink, owner mismatch,
  // etc.). Empty on success.
  property string pendingHistoryError: ""

  // Re-read history whenever the underlying file changes (e.g. another
  // shell instance wrote to it). The watcher is a watch-only FileView;
  // the read itself comes from historyReadProc.
  function historyFileChanged() {
    historyReadProc.running = true
  }

  Process {
    id: historyReadProc
    command: [
      root.pythonBin, root.helperScript,
      "history-read", root.historyPath,
      String(root.historyMaxBytes)
    ]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: function(text) {
        var t = text === undefined || text === null ? "" : String(text)
        // Helper prefixes its response with a sentinel line:
        //   "NO_HISTORY"             -> file absent or symlink
        //   "HISTORY_OK\n..."        -> regular bounded read
        //   "HISTORY_TRUNCATED\n..." -> file was larger than the cap
        // Anything else is treated as a raw JSONL payload (helper
        // changes shouldn't break us silently).
        var body = t
        var firstNewline = t.indexOf("\n")
        var firstLine = firstNewline >= 0 ? t.substring(0, firstNewline) : t
        if (firstLine === "NO_HISTORY" || firstLine === "HISTORY_OK"
            || firstLine === "HISTORY_TRUNCATED") {
          if (firstLine === "NO_HISTORY") {
            body = ""
          } else {
            body = firstNewline >= 0 ? t.substring(firstNewline + 1) : ""
            // On HISTORY_TRUNCATED the helper returned the last
            // `historyMaxBytes` bytes, which may start with a partial
            // line — trim the head up to the first newline so JSONL
            // parsing doesn't choke on a half-record.
            if (firstLine === "HISTORY_TRUNCATED" && body.length > 0
                && body.charCodeAt(0) !== 10
                && body.indexOf("\n") >= 0) {
              body = body.substring(body.indexOf("\n") + 1)
            }
          }
          root.pendingHistoryText = body
          root.pendingHistoryError = ""
        } else {
          // Helper did not produce a sentinel — treat as plain body
          // for backward compatibility, but flag it so we notice.
          root.pendingHistoryText = body
          root.pendingHistoryError = ""
        }
        root.historyChanged()
      }
      onTextChanged: {}
    }
    stderr: StdioCollector {
      waitForEnd: true
      onTextChanged: {}
    }
  }

  // Signal fired after every successful bounded read. The popup panel
  // listens via Qt.binding to `todayEntries`, which we recompute here.
  signal historyChanged()

function appendHistory(entry) {
    // Append a single JSONL line. The helper handles locking, the
    // no-symlink check, and O_NOFOLLOW atomic writes; we pass the line
    // as argv (no embedded newlines possible that way) so we don't
    // rely on stdin/Process.write timing. formatHistoryLine guarantees
    // no embedded newlines, but we double-check defensively.
    var line = Model.formatHistoryLine(entry)
    if (line.indexOf("\n") >= 0) {
      console.warn("adhd-pomodoro: refusing to append history line containing newline")
      return
    }
    if (historyAppendProc.running) {
      pendingHistoryLine = line
      return
    }
    historyAppendProc.command = [
      root.pythonBin, root.helperScript,
      "history-append", root.historyPath, line
    ]
    historyAppendProc.running = true
  }

  // Append runs as a one-shot Process. The line is passed as argv. On
  // exit we refresh the bounded read so the popup reflects the latest
  // file contents.
  Process {
    id: historyAppendProc
    command: [
      root.pythonBin, root.helperScript,
      "history-append", root.historyPath, ""
    ]
    onExited: {
      if (root.pendingHistoryLine !== "") {
        var queued = root.pendingHistoryLine
        root.pendingHistoryLine = ""
        historyAppendProc.command = [
          root.pythonBin, root.helperScript,
          "history-append", root.historyPath, queued
        ]
        historyAppendProc.running = true
        return
      }
      historyReadProc.running = true
    }
  }

  // One-deep queue for a history line that arrived while the previous
  // append was still running. Set by appendHistory, cleared by
  // historyAppendProc.onExited.
  property string pendingHistoryLine: ""

  function applyParsedState(parsed) {
    root.phase = parsed.phase
    root.phaseStartedAt = parsed.phaseStartedAt
    root.phaseDurationSecs = parsed.phaseDurationSecs
    root.phasePausedSecondsLeft = parsed.phasePausedSecondsLeft
    root.completedWorkSessionsToday = parsed.completedWorkSessionsToday
    root.lastResetDate = parsed.lastResetDate
    root.taskLabel = parsed.taskLabel
    root.settings = parsed.settings
    root.lastFiredWarningSeconds = parsed.lastFiredWarningSeconds
    recomputeSeconds()
    rescheduleTimers()
    broadcastStatus()
  }

  // ---- Persistence ----------------------------------------------------------
  function buildStateObject() {
    return {
      phase: root.phase,
      phaseStartedAt: root.phaseStartedAt,
      phaseDurationSecs: root.phaseDurationSecs,
      phasePausedSecondsLeft: root.phasePausedSecondsLeft,
      completedWorkSessionsToday: root.completedWorkSessionsToday,
      lastResetDate: root.lastResetDate,
      taskLabel: root.taskLabel,
      settings: root.settings,
      lastFiredWarningSeconds: root.lastFiredWarningSeconds
    }
  }

  function saveState() {
    // State is persisted via the secure helper. The helper writes to a
    // sibling tempfile with O_NOFOLLOW|O_EXCL, fsyncs, and os.replace()
    // it into place — atomic and symlink-safe. We pass the JSON body as
    // an argv element to avoid relying on stdin/Process.write timing.
    // If a save is already running, queue the latest body (last write
    // wins is fine because every saveState() carries the full state).
    var body = JSON.stringify(buildStateObject(), null, 2) + "\n"
    if (stateWriteProc.running) {
      root.pendingStateBody = body
      return
    }
    stateWriteProc.command = [
      root.pythonBin, root.helperScript,
      "state-write", root.statePath, body
    ]
    stateWriteProc.running = true
  }

  // Bounded, no-symlink read of state.json via the helper.
  Process {
    id: stateReadProc
    environment: ({ "PYTHONUNBUFFERED": "1" })
    command: [
      root.pythonBin, root.helperScript,
      "state-read", root.statePath, String(root.stateMaxBytes)
    ]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: function(text) {
        var t = text === undefined || text === null ? "" : String(text)
        console.warn("adhd-pomodoro: stateRead raw_len=" + t.length + " hex_first=" + (t.length > 0 ? t.charCodeAt(0).toString(16) : ""))
        // Sentinel on first line:
        //   "NO_STATE"          -> file absent
        //   "STATE_OK\n..."     -> bounded read OK
        //   "STATE_TRUNCATED\n" -> file larger than the cap (suspicious)
        var firstNewline = t.indexOf("\n")
        var firstLine = firstNewline >= 0 ? t.substring(0, firstNewline) : t
        var body = firstNewline >= 0 ? t.substring(firstNewline + 1) : ""
        if (firstLine === "NO_STATE") {
          // No prior state — write defaults so subsequent saves are clean
          root.saveState()
          return
        }
        try {
          var parsed = JSON.parse(body)
          Model.rolloverIfNewDay(parsed)
          applyParsedState(parsed)
        } catch (e) {
          console.warn("adhd-pomodoro: state.json parse failed, body_len="
            + body.length + " first_char='" + body.charCodeAt(0)
            + "' last_char='" + (body.length > 0 ? body.charCodeAt(body.length - 1) : "") + "'")
          root.saveState()
        }
      }
      onTextChanged: {}
    }
    stderr: StdioCollector {
      waitForEnd: true
      onTextChanged: {}
    }
  }

  // No-symlink atomic state write via the helper. Command is set on each
// invocation so the body (which varies) travels as argv instead of
// stdin — Quickshell Process.write() requires a precise startup order
// that is brittle across versions, and argv is dependable.
  Process {
    id: stateWriteProc
    command: [
      root.pythonBin, root.helperScript,
      "state-write", root.statePath, ""
    ]
    onExited: {
      // If saveState was called again while the process was still
      // running, drain the queued body now.
      if (root.pendingStateBody !== "") {
        var queued = root.pendingStateBody
        root.pendingStateBody = ""
        stateWriteProc.command = [
          root.pythonBin, root.helperScript,
          "state-write", root.statePath, queued
        ]
        stateWriteProc.running = true
      }
    }
  }

  // One-deep queue for state bodies that arrived while the previous
  // write was still running.
  property string pendingStateBody: ""

  // ---- Phase transitions ----------------------------------------------------

  function phaseSeconds(phaseName) {
    return Model.phaseMinutes(phaseName, root.settings) * 60
  }

  function start() {
    // IDLE / PAUSED -> start (or resume) a fresh WORK block.
    if (root.phase === Model.PHASE_PAUSED) {
      // Resume from the frozen paused value.
      var duration = phaseSeconds(inferPhaseFromPaused())
      var remaining = Math.max(0, root.phasePausedSecondsLeft)
      root.phase = inferPhaseFromPaused()
      root.phaseStartedAt = Date.now() - (duration - remaining) * 1000
      root.phaseDurationSecs = duration
      root.phasePausedSecondsLeft = 0
      root.lastFiredWarningSeconds = []
    } else if (!Model.isRunningPhase(root.phase)) {
      root.phase = Model.PHASE_WORK
      root.phaseDurationSecs = phaseSeconds(Model.PHASE_WORK)
      root.phaseStartedAt = Date.now()
      root.phasePausedSecondsLeft = 0
      root.lastFiredWarningSeconds = []
    }
    recomputeSeconds()
    rescheduleTimers()
    saveState()
    broadcastStatus()
  }

  function pause() {
    if (!Model.isRunningPhase(root.phase)) return
    // Freeze the current countdown so the user sees the same value no
    // matter how long they stay paused.
    var s = recomputeSeconds()
    root.phasePausedSecondsLeft = s
    root.phase = Model.PHASE_PAUSED
    rescheduleTimers()
    saveState()
    broadcastStatus()
  }

  function resume() {
    if (root.phase !== Model.PHASE_PAUSED) return
    // Convert the frozen paused value into a fresh timestamp.
    var phaseName = inferPhaseFromPaused()
    var duration = phaseSeconds(phaseName)
    var remaining = Math.max(0, root.phasePausedSecondsLeft)
    root.phase = phaseName
    root.phaseStartedAt = Date.now() - (duration - remaining) * 1000
    root.phaseDurationSecs = duration
    root.phasePausedSecondsLeft = 0
    recomputeSeconds()
    rescheduleTimers()
    saveState()
    broadcastStatus()
  }

  function reset() {
    root.phase = Model.PHASE_IDLE
    root.phaseStartedAt = null
    root.phaseDurationSecs = 0
    root.phasePausedSecondsLeft = 0
    root.lastFiredWarningSeconds = []
    recomputeSeconds()
    rescheduleTimers()
    saveState()
    broadcastStatus()
  }

  function skip() {
    if (!Model.isRunningPhase(root.phase) && root.phase !== Model.PHASE_PAUSED) return
    // Map PAUSED -> WORK so the nextPhase math is correct.
    var justFinished = root.phase === Model.PHASE_PAUSED ? Model.PHASE_WORK : root.phase
    var next = Model.nextPhase(justFinished, root.completedWorkSessionsToday, root.settings)
    root.phase = next
    root.phaseStartedAt = Date.now()
    root.phaseDurationSecs = phaseSeconds(next)
    root.phasePausedSecondsLeft = 0
    root.lastFiredWarningSeconds = []
    recomputeSeconds()
    announcePhaseStart(next)
    rescheduleTimers()
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

    // If a phase is currently running, only `lastFiredWarningSeconds`
    // depends on the previous duration. Re-evaluate pre-warnings against
    // the new settings without restarting the phase.
    var liveSeconds = recomputeSeconds()
    maybeFirePreWarnings(liveSeconds, liveSeconds)
    saveState()
    broadcastStatus()
  }

  function clamp(n, lo, hi) { return Math.max(lo, Math.min(hi, n)); }

  function inferPhaseFromPaused() {
    // The duration tells us which phase we paused in. If for some reason
    // we cannot infer, default to WORK — the most common case and the
    // one the user will be resuming from.
    var d = root.phaseDurationSecs
    if (d === phaseSeconds(Model.PHASE_WORK)) return Model.PHASE_WORK
    if (d === phaseSeconds(Model.PHASE_SHORT_BREAK)) return Model.PHASE_SHORT_BREAK
    if (d === phaseSeconds(Model.PHASE_LONG_BREAK)) return Model.PHASE_LONG_BREAK
    return Model.PHASE_WORK
  }

  // ---- Timer ladder ---------------------------------------------------------

  // Slow tick — every 60 s while a phase is running. Recomputes
  // secondsLeft and checks for pre-warning boundaries and phase end.
  Timer {
    id: slowTick
    interval: 60000
    running: false
    repeat: true
    onTriggered: root.slowTickFired()
  }

  // Fast tick — every second while the popup is open or while we are
  // within 60 s of phase end.
  Timer {
    id: fastTick
    interval: 1000
    running: false
    repeat: true
    onTriggered: root.fastTickFired()
  }

  function rescheduleTimers() {
    var running = Model.isRunningPhase(root.phase)
    slowTick.running = running
    if (!running) {
      fastTick.running = false
      return
    }
    var s = recomputeSeconds()
    var needsFast = root.popupOpen || s <= 60
    fastTick.running = needsFast
  }

  function slowTickFired() {
    if (!Model.isRunningPhase(root.phase)) {
      slowTick.running = false
      return
    }
    var s = recomputeSeconds()
    // Pre-warning boundaries may have been crossed during the long sleep.
    // We can't tell exactly which one fired, but we can check all of
    // them against the *current* value — only seconds that equal a
    // configured boundary and have not been announced yet will fire.
    maybeFirePreWarnings(s, s)

    // Promote to fast tick if we are now within the last minute — this
    // gives the user a smooth transition from minute-precision to
    // second-precision without waiting for the panel to open.
    if (!fastTick.running && s <= 60) {
      fastTick.running = true
    }

    if (s <= 0) {
      finishPhase()
    } else {
      saveState()
    }
    broadcastStatus()
  }

  function fastTickFired() {
    if (!Model.isRunningPhase(root.phase)) {
      fastTick.running = false
      return
    }
    var prev = root.secondsLeft
    var s = recomputeSeconds()
    // Detect any pre-warning seconds that the previous tick crossed
    // through. This handles the case where the fast tick catches a
    // boundary mid-second.
    if (s !== prev && Model.shouldFirePreWarning(s, settings.preWarningSeconds, lastFiredWarningSeconds)) {
      for (var i = 0; i < settings.preWarningSeconds.length; i++) {
        var t = Number(settings.preWarningSeconds[i])
        if (t === s && lastFiredWarningSeconds.indexOf(t) === -1) {
          root.lastFiredWarningSeconds = lastFiredWarningSeconds.concat([t])
          notifyPreWarning(t)
          break
        }
      }
    }

    if (s <= 0) {
      finishPhase()
    } else if (s % 10 === 0) {
      // Save state every 10 s during the last-minute window — cheap and
      // recovers cleanly from a shell restart in the final stretch.
      saveState()
    }
    broadcastStatus()
  }

  function maybeFirePreWarnings(currentSeconds, _ignored) {
    // Walk the configured pre-warning seconds and fire any whose value
    // equals `currentSeconds` and which we have not already announced in
    // this phase. Used by slowTick where we may have skipped past
    // several boundary crossings during one long sleep.
    if (!settings || !Array.isArray(settings.preWarningSeconds)) return
    for (var i = 0; i < settings.preWarningSeconds.length; i++) {
      var t = Number(settings.preWarningSeconds[i])
      if (!isFinite(t) || t < 0) continue
      if (t === currentSeconds && lastFiredWarningSeconds.indexOf(t) === -1) {
        root.lastFiredWarningSeconds = lastFiredWarningSeconds.concat([t])
        notifyPreWarning(t)
      }
    }
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
    root.phase = next
    root.phaseStartedAt = Date.now()
    root.phaseDurationSecs = phaseSeconds(next)
    root.phasePausedSecondsLeft = 0
    root.lastFiredWarningSeconds = []

    if (historyEntry) appendHistory(historyEntry)
    announcePhaseEnd(justFinished)
    announcePhaseStart(next)

    recomputeSeconds()
    rescheduleTimers()
    saveState()
    broadcastStatus()
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
      root.recomputeSeconds()
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
      // Use the bounded text held in memory (capped to historyMaxBytes)
      // rather than re-reading the file via FileView. The panel may ask
      // for this many times while it is open; reading is free here.
      var entries = Model.parseHistoryFile(root.pendingHistoryText)
      return Model.todayHistoryEntries(entries)
    }

    function refreshHistory(): void {
      // Re-run the bounded read Process. Cheap (head -c on a single
      // file) and idempotent. The panel calls this when the popup
      // opens or when the user toggles the "Show sessions list" switch.
      historyReadProc.running = true
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
    function setPanelOpen(open: bool): void { root.setPopupOpen(open) }
  }

  // ---- Process for directory bootstrap -------------------------------------
  // Create the state directory with mode 0700 owned by the current user
  // (the helper will refuse to operate otherwise). After the directory
  // is ready we kick off the bounded, no-symlink read for state.json.
  Process {
    id: mkdirProc
    command: ["mkdir", "-p", "-m", "0700", root.stateHome]
    onExited: {
      stateReadProc.running = true
      historyReadProc.running = true
    }
  }

  Component.onDestruction: {
    slowTick.running = false
    fastTick.running = false
    saveState()
  }
}

