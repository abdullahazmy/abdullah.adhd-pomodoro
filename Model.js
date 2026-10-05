// ADHD Pomodoro — pure helpers.
//
// Loaded by PomodoroService.qml (service) and Panel.qml (popup). Has no Qt
// object dependencies so it stays trivially testable from `quickshell -c ...`
// if we ever wire that up, and so the same helpers are usable from both the
// long-running service and the lazily-instantiated panel.
//
// State persistence is JSON. The service owns the timer; the panel reads from
// it via `bar.shell.serviceFor(...)` rather than reading the file itself, so
// the two never disagree about which second the timer is on.
//
// Timing model: the service stores `phaseStartedAt` (epoch ms) and
// `phaseDurationSecs`, then derives `secondsLeft` from the wall clock. It
// wakes only for real events (the next pre-warning or phase end, capped at
// 60 s so a suspend/resume is noticed promptly) and keeps a 1 Hz tick only
// while the popup is open. A paused or idle plugin uses no timers at all.

// ---------- Phase constants -------------------------------------------------

var PHASE_IDLE = "IDLE";
var PHASE_WORK = "WORK";
var PHASE_SHORT_BREAK = "SHORT_BREAK";
var PHASE_LONG_BREAK = "LONG_BREAK";
var PHASE_PAUSED = "PAUSED";

// Pre-warning is a transient phase tag, not a real state: it lives in a
// transient field on the service so the bar can pulse without affecting the
// state machine.

function isRunningPhase(phase) {
  return phase === PHASE_WORK || phase === PHASE_SHORT_BREAK || phase === PHASE_LONG_BREAK;
}

function phaseMinutes(phase, settings) {
  if (phase === PHASE_WORK) return settings.workMinutes;
  if (phase === PHASE_SHORT_BREAK) return settings.shortBreakMinutes;
  if (phase === PHASE_LONG_BREAK) return settings.longBreakMinutes;
  return 0;
}

function phaseSeconds(phase, settings) {
  return phaseMinutes(phase, settings) * 60;
}

function phaseLabel(phase) {
  switch (phase) {
    case PHASE_WORK: return "Focus";
    case PHASE_SHORT_BREAK: return "Short break";
    case PHASE_LONG_BREAK: return "Long break";
    case PHASE_PAUSED: return "Paused";
    default: return "Idle";
  }
}

function phaseGlyph(phase) {
  switch (phase) {
    case PHASE_WORK: return "󰐉";          // nf-md-timer (play-ish)
    case PHASE_SHORT_BREAK: return "󰾶";   // nf-md-coffee-outline
    case PHASE_LONG_BREAK: return "󰘧";    // nf-md-weather-sunny
    case PHASE_PAUSED: return "󰏤";        // nf-md-pause
    default: return "󰥛";                  // nf-md-timer-sand-empty
  }
}

// ---------- Time formatting -------------------------------------------------

function formatMMSS(totalSeconds) {
  var s = Math.max(0, Math.floor(totalSeconds || 0));
  var m = Math.floor(s / 60);
  var r = s % 60;
  return (m < 10 ? "0" : "") + m + ":" + (r < 10 ? "0" : "") + r;
}

// "Minutes enough" formatter used by the bar widget and popup hero:
// more than a minute left -> "25m" (round up so the bar never reads
// "0m" while a phase is still running); the final minute switches to
// "0:42" so the user can see the last seconds precisely.
function formatCoarse(totalSeconds) {
  var s = Math.max(0, Math.floor(totalSeconds || 0));
  if (s > 60) {
    // Round up — "25m" through "24:01" reads as "25m". This matches the
    // way the user thinks about the timer ("about 25 minutes, almost
    // done is still 25 minutes") and avoids a confusing flicker to
    // "24m" the instant the phase crosses the minute boundary.
    return Math.ceil(s / 60) + "m";
  }
  // Last minute — drop the leading "0:" and show seconds.
  var m = Math.floor(s / 60);
  var r = s % 60;
  return m + ":" + (r < 10 ? "0" + r : r);
}

// ---------- Timing math -----------------------------------------------------

// Compute secondsLeft for a running phase from `phaseStartedAt` and the
// current epoch ms. Returns 0 once the phase has ended.
function secondsLeftFromStart(phaseStartedAt, phaseDurationSecs, nowMs) {
  if (!phaseStartedAt || !phaseDurationSecs) return 0
  if (nowMs === undefined) nowMs = Date.now()
  var elapsed = Math.floor((nowMs - phaseStartedAt) / 1000)
  return Math.max(0, phaseDurationSecs - elapsed)
}

// Configured pre-warning seconds that apply to a phase of
// `phaseDurationSecs`: finite, positive, shorter than the phase, and not
// yet announced. Sorted descending (the order they come due).
function pendingWarnings(preWarningSeconds, lastFiredSeconds, phaseDurationSecs) {
  var out = [];
  if (!Array.isArray(preWarningSeconds)) return out;
  var fired = Array.isArray(lastFiredSeconds) ? lastFiredSeconds : [];
  for (var i = 0; i < preWarningSeconds.length; i++) {
    var t = Math.floor(Number(preWarningSeconds[i]));
    if (!isFinite(t) || t <= 0 || t >= phaseDurationSecs) continue;
    if (fired.indexOf(t) !== -1 || out.indexOf(t) !== -1) continue;
    out.push(t);
  }
  out.sort(function (x, y) { return y - x; });
  return out;
}

// The next secondsLeft value the service must wake up at: the largest
// pending pre-warning below `secondsLeft`, or 0 (phase end).
function nextWakeBoundary(secondsLeft, pending) {
  for (var i = 0; i < pending.length; i++) {
    if (pending[i] < secondsLeft) return pending[i];
  }
  return 0;
}

// ---------- State machine ---------------------------------------------------

// Given the current phase, completed-sessions-today, and settings, return the
// phase we should transition into when the current phase's timer hits zero.
// WORK -> SHORT_BREAK unless we just hit a long-break boundary.
// SHORT_BREAK / LONG_BREAK -> WORK.
function nextPhase(currentPhase, completedWorkSessions, settings) {
  if (currentPhase === PHASE_WORK) {
    var next = completedWorkSessions + 1;
    return (next % settings.longBreakInterval === 0) ? PHASE_LONG_BREAK : PHASE_SHORT_BREAK;
  }
  if (currentPhase === PHASE_SHORT_BREAK || currentPhase === PHASE_LONG_BREAK) {
    return PHASE_WORK;
  }
  return PHASE_IDLE;
}

// ---------- Default settings ----------------------------------------------

function defaultSettings() {
  return {
    workMinutes: 25,
    shortBreakMinutes: 5,
    longBreakMinutes: 15,
    longBreakInterval: 4,
    dailyGoal: 8,
    soundOnPhaseEnd: true,
    preWarningSeconds: [120, 30],
    autostartNext: false
  };
}

// Build a freshly-initialised state. We deliberately do not store
// `secondsLeft`; the service computes it from `phaseStartedAt` and the
// wall clock. `phaseStartedAt` is null in IDLE — there is nothing
// running. PAUSED uses `phasePausedSecondsLeft` as the source of truth
// because we want a paused timer to read the same value no matter how
// long the pause lasts.
function defaultState() {
  var s = defaultSettings();
  return {
    phase: PHASE_IDLE,
    phaseStartedAt: null,
    phaseDurationSecs: 0,
    phasePausedSecondsLeft: 0,
    completedWorkSessionsToday: 0,
    pausedPhase: "",
    lastResetDate: todayKey(),
    taskLabel: "",
    settings: s,
    lastFiredWarningSeconds: []
  };
}

// ---------- Date helpers ----------------------------------------------------

function todayKey() {
  return dateKey(new Date());
}

function dateKey(d) {
  return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate());
}

function pad2(n) { return n < 10 ? "0" + n : "" + n; }

// Roll the daily counters over if the stored lastResetDate isn't today.
// Mutates and returns the state object.
function rolloverIfNewDay(state) {
  var today = todayKey();
  if (state.lastResetDate !== today) {
    state.completedWorkSessionsToday = 0;
    state.lastResetDate = today;
    state.lastFiredWarningSeconds = [];
  }
  return state;
}

// ---------- File I/O --------------------------------------------------------
//
// Two files: state.json (single object, written atomically) and
// history.jsonl (one line per completed WORK session). The service owns
// reads/writes; the panel reaches into the service, not the files.

// Merge persisted state with defaults so newly-added fields don't blow up
// older state.json files.
function mergeSettings(persisted) {
  var s = defaultSettings();
  if (!persisted || typeof persisted !== "object") return s;
  for (var k in s) {
    if (persisted[k] !== undefined && persisted[k] !== null) s[k] = persisted[k];
  }
  // preWarningSeconds: tolerate JSON string from hand-edited files.
  if (typeof s.preWarningSeconds === "string") {
    var parts = s.preWarningSeconds.split(",").map(function (x) { return Number(x.trim()); });
    s.preWarningSeconds = parts.filter(function (n) { return isFinite(n) && n >= 0; });
    if (s.preWarningSeconds.length === 0) s.preWarningSeconds = [120, 30];
  }
  if (!Array.isArray(s.preWarningSeconds)) s.preWarningSeconds = [120, 30];
  return s;
}

// Accept both the new timestamp schema and the old `secondsLeft`-based
// schema. On a running phase with the old schema, seed `phaseStartedAt`
// so that `secondsLeftFromStart(...)` returns the previously-stored
// `secondsLeft` at the moment of load — preserving the user's progress
// without forcing a phase restart.
function mergeState(persisted) {
  var base = defaultState();
  if (!persisted || typeof persisted !== "object") return base;

  var phases = [PHASE_IDLE, PHASE_WORK, PHASE_SHORT_BREAK, PHASE_LONG_BREAK, PHASE_PAUSED];
  if (phases.indexOf(persisted.phase) !== -1) base.phase = persisted.phase;
  if (isRunningPhase(persisted.pausedPhase)) base.pausedPhase = persisted.pausedPhase;
  base.completedWorkSessionsToday = Number(persisted.completedWorkSessionsToday) || 0;
  base.lastResetDate = persisted.lastResetDate || base.lastResetDate;
  base.taskLabel = typeof persisted.taskLabel === "string" ? persisted.taskLabel : "";
  base.settings = mergeSettings(persisted.settings);
  base.lastFiredWarningSeconds = Array.isArray(persisted.lastFiredWarningSeconds)
    ? persisted.lastFiredWarningSeconds.slice() : [];

  // New schema: explicit timestamps.
  if (typeof persisted.phaseDurationSecs === "number" && persisted.phaseDurationSecs > 0) {
    base.phaseDurationSecs = Math.floor(persisted.phaseDurationSecs);
  }
  if (typeof persisted.phaseStartedAt === "number" && typeof persisted.phaseDurationSecs === "number") {
    base.phaseStartedAt = persisted.phaseStartedAt;
    base.phaseDurationSecs = persisted.phaseDurationSecs;
  }
  if (typeof persisted.phasePausedSecondsLeft === "number") {
    base.phasePausedSecondsLeft = persisted.phasePausedSecondsLeft;
  }

  // Old schema migration: a running phase with `secondsLeft` gets a
  // synthetic `phaseStartedAt` so the wall-clock math gives the same value.
  if (base.phase === PHASE_PAUSED && typeof persisted.phasePausedSecondsLeft === "undefined"
      && typeof persisted.secondsLeft === "number") {
    base.phasePausedSecondsLeft = Math.max(0, Math.floor(persisted.secondsLeft));
  }
  if (isRunningPhase(base.phase) && !base.phaseStartedAt
      && typeof persisted.secondsLeft === "number") {
    var remaining = Math.max(0, Math.floor(persisted.secondsLeft));
    var duration = phaseSeconds(base.phase, base.settings);
    if (duration > 0) {
      base.phaseDurationSecs = duration;
      // Anchor phaseStartedAt so that `secondsLeftFromStart` returns
      // `remaining` at "now". The 1000 ms drift is harmless: the slow
      // timer will correct it within a second.
      base.phaseStartedAt = Date.now() - (duration - remaining) * 1000;
    }
  }

  return base;
}

function parseStateFile(text) {
  if (!text || !text.trim()) return defaultState();
  try { return mergeState(JSON.parse(text)); }
  catch (e) { return defaultState(); }
}

// History entries are JSONL: each line is { ts, taskLabel, plannedMinutes, actualSeconds }.
function parseHistoryFile(text) {
  if (!text) return [];
  var lines = text.split("\n");
  var out = [];
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim();
    if (!line) continue;
    try {
      var obj = JSON.parse(line);
      if (obj && obj.ts) out.push(obj);
    } catch (e) { /* skip malformed line */ }
  }
  return out;
}

function formatHistoryLine(entry) {
  return JSON.stringify(entry);
}

// History rows for the panel's "Today" list. Filters to entries on today's
// local date and returns newest-first. `ts` is stored as UTC ISO, so the
// comparison has to go through a Date — slicing the string would file a
// session at 01:00 local (UTC+3) under yesterday.
function todayHistoryEntries(allEntries) {
  var today = todayKey();
  var filtered = [];
  for (var i = 0; i < allEntries.length; i++) {
    var e = allEntries[i];
    if (!e || typeof e.ts !== "string") continue;
    var d = new Date(e.ts);
    if (isNaN(d.getTime())) continue;
    if (dateKey(d) === today) filtered.push(e);
  }
  filtered.sort(function (a, b) { return a.ts < b.ts ? 1 : -1; });
  return filtered;
}

// Local midnight as a UTC ISO string. The helper keeps only history lines
// whose `ts` sorts at or after this, so the shell never holds more than
// today's entries.
function localMidnightIso() {
  var d = new Date();
  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).toISOString();
}

// Short clock for the history row, e.g. "09:14".
function formatLocalTime(isoString) {
  if (!isoString) return "";
  var d = new Date(isoString);
  if (isNaN(d.getTime())) return "";
  return pad2(d.getHours()) + ":" + pad2(d.getMinutes());
}
