# ADHD Pomodoro

An Omarchy shell plugin: a Pomodoro timer tuned for ADHD, with a visible
countdown in the bar, gentle pre-warnings, plain-text task labels, and a
per-day session log.

## What you get

- A bar widget that shows the current phase (Focus / Short break / Long
  break / Paused / Idle), a live `mm:ss` countdown, the task label you set
  for the current block, and a row of progress dots toward today's goal.
- A popup panel anchored to the bar widget with Start / Pause / Reset /
  Skip, a task label input, today's progress toward the daily goal, a
  list of completed sessions today, and a settings drawer.
- Persistent state in `~/.local/state/abdullah.adhd-pomodoro/state.json`
  and an append-only session history in `history.jsonl`.
- IPC routes on `abdullah.adhd-pomodoro` so a future CLI helper or
  keybinding can drive the same timer.

## Bar clicks

| Button | Action |
|---|---|
| Left   | Open / close the popup panel |
| Right  | Pause the running phase; right-click again to resume |
| Middle | Skip to the next phase (no history recorded) |

## ADHD-friendly defaults

- **Pre-warnings at 2 min and 30 s** before a focus block ends, via a
  desktop notification. Editable in the settings drawer.
- **Last-30-seconds visual pulse** in the bar — the glyph and `mm:ss`
  switch to the urgent colour so the user notices even when they have
  drifted to a different window.
- **Autostart next phase is OFF by default.** The user has to click to
  start the next phase, which avoids the guilt-driven auto-cycle that
  tends to backfire for ADHD brains.
- **Task label is encouraged, not required.** Naming what you are
  working on turns an abstract timer into "I am doing X right now".
- **Session log surfaced in the panel.** Visible proof of progress
  counters the "I did nothing today" feeling.

## Install

The plugin lives in `~/.config/omarchy/plugins/abdullah.adhd-pomodoro/`,
which is the user plugin directory Omarchy scans on startup. If you got
this from a git repo, drop the folder there.

Then enable and restart the shell:

```bash
omarchy plugin enable abdullah.adhd-pomodoro
omarchy restart shell
```

Add the bar widget to your bar layout:

```bash
omarchy bar move abdullah.adhd-pomodoro --section center
```

(or edit `~/.config/omarchy/shell.json` by hand if you want it
somewhere specific).

## Validate

```bash
omarchy plugin validate ~/.config/omarchy/plugins/abdullah.adhd-pomodoro
```

## Files

- `manifest.json` — plugin manifest (service + bar-widget kinds)
- `PomodoroService.qml` — long-running service, owns the timer, persists state
- `BarWidget.qml` — bar slot
- `Panel.qml` — popup panel
- `Model.js` — pure helpers: state machine, persistence, formatting
- `LICENSE` — MIT

## Settings

All settings live in `~/.local/state/abdullah.adhd-pomodoro/state.json`
under `settings` and are also editable from the popup's settings drawer:

| Key | Default | Notes |
|---|---|---|
| `workMinutes` | 25 | Length of one focus block |
| `shortBreakMinutes` | 5 | Length of short break |
| `longBreakMinutes` | 15 | Length of long break |
| `longBreakInterval` | 4 | Long break every N work sessions |
| `dailyGoal` | 8 | Pomodoros per day target |
| `soundOnPhaseEnd` | true | Play a chime on phase transition |
| `preWarningSeconds` | [120, 30] | Notifications fire at these seconds-remaining |
| `autostartNext` | false | Auto-start the next phase without clicking |

## IPC

For scripts and keybindings:

```
abdullah.adhd-pomodoro.start
abdullah.adhd-pomodoro.pause
abdullah.adhd-pomodoro.resume
abdullah.adhd-pomodoro.reset
abdullah.adhd-pomodoro.skip
abdullah.adhd-pomodoro.setTask  "Write the design doc"
abdullah.adhd-pomodoro.status        # returns a JSON snapshot
abdullah.adhd-pomodoro.history       # returns today's history JSON array
abdullah.adhd-pomodoro.togglePanel
```

Example keybinding in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER SHIFT, P", function() Quickshell.execDetached({"omarchy-shell", "ipc", "call", "abdullah.adhd-pomodoro", "togglePanel"}) end)
```

## Out of scope (v1)

- Strict break overlay / app blocking
- Obsidian / TaskNotes integration
- CLI helper binary (call IPC from a shell wrapper if you want one)
- Weekly / monthly charts
