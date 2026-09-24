import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar slot for the ADHD Pomodoro plugin.
//
// Renders a compact "phase glyph + mm:ss + task label + progress dots" pill.
// Click behaviour:
//   left   — open the popup panel
//   right  — pause / resume the running phase
//   middle — skip to the next phase
//
// All timer state lives in PomodoroService.qml; this widget only binds to
// its reactive properties. The popup panel lives in Panel.qml and is
// loaded via a Loader so the bar can hand it the button as its anchor
// (mirrors the omarchy.clock pattern).
BarWidget {
  id: root
  moduleName: "abdullah.adhd-pomodoro"

  // Resolve the service fresh on every access. Caching it in a `var`
  // makes QML bindings through that `var` freeze on first evaluation
  // when the inner QObject's properties change, because the binding
  // system tracks the `var` reassignment, not the property access
  // through it. Going through the helper on every binding evaluation
  // keeps the inner QObject live in the binding so its property
  // changes propagate.
  function _service() {
    return bar && bar.shell && typeof bar.shell.serviceFor === "function"
      ? bar.shell.serviceFor("abdullah.adhd-pomodoro")
      : null
  }

  // Convenience alias kept for click handlers and the injectPanel
  // contract. Resolves fresh on every access via the helper above.
  readonly property var service: _service()

  // Mirrors of service state. We re-resolve the service on every access
  // so QML can track property changes through the resulting QObject
  // rather than freezing on the `var` reference.
  readonly property string phase: _service() ? _service().phase : Model.PHASE_IDLE
  readonly property int completedToday: _service() ? _service().completedWorkSessionsToday : 0
  readonly property int dailyGoal: _service() ? _service().settings.dailyGoal : 8

  // Wall-clock derived countdown. The service stores `phaseStartedAt` and
  // `phaseDurationSecs`; this widget does its own arithmetic from those
  // fields so the bar updates every second when its own Timer fires,
  // independent of the service's slowTick. (The service's slowTick at
  // 60 s resolution is enough for state changes — pre-warning boundaries,
  // phase-end detection, persisting `phaseStartedAt` — but the visible
  // bar countdown wants per-second resolution.)
  readonly property var phaseStartedAtMs: _service() ? _service().phaseStartedAt : null
  readonly property int phaseDurationSecs: _service() ? _service().phaseDurationSecs : 0
  readonly property string taskLabel: _service() ? (_service().taskLabel || "") : ""
  // The bar widget owns a 1 Hz Timer that drives this binding.
  property int localNowSec: Math.floor(Date.now() / 1000)
  property int secondsLeft: {
    var p = root.phase
    var s
    if (p === Model.PHASE_PAUSED) {
      s = _service() ? _service().phasePausedSecondsLeft : 0
    } else if (p === Model.PHASE_IDLE) {
      s = root.phaseDurationSecs > 0 ? root.phaseDurationSecs : 1500
    } else if (root.phaseStartedAtMs && root.phaseDurationSecs) {
      var startedSec = Math.floor(root.phaseStartedAtMs / 1000)
      s = Math.max(0, root.phaseDurationSecs - (root.localNowSec - startedSec))
    } else {
      s = 0
    }
    return s
  }

  // Visual constants
  readonly property string glyph: Model.phaseGlyph(phase)
  // Seconds-precision MM:SS readout. Updated once a second by barTick
  // (below) while the widget is alive and a phase is running.
  readonly property string mmss: Model.formatMMSS(secondsLeft)
  // The last 30 s of a focus block: pulse the bar label so the user notices
  // even when they have drifted to a different window.
  readonly property bool lastThirty: phase === Model.PHASE_WORK && secondsLeft <= 30 && secondsLeft > 0
  readonly property int goalFilled: Math.min(completedToday, dailyGoal)
  readonly property int goalTotal: Math.max(dailyGoal, 1)

  // ---- Panel wiring (popout contract) -------------------------------------
  // The shell's `findPanelWidget` walks each live bar-widget slot and
  // looks for `open()`, `close()`, and an `opened` property on the widget
  // root. Defining those three names here is what makes `bar.shell.summon(...)`
  // and `bar.shell.togglePanel(...)` actually reach our popup.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  // Push the panel's open state into the service so it can switch between
  // the 60-second slow tick and the per-second fast tick. Bound to the
  // resolved `opened` property above so it fires on every open/close,
  // including the very first time the panel is shown.
  onOpenedChanged: {
    if (root.service && typeof root.service.setPopupOpen === "function") {
      root.service.setPopupOpen(root.opened)
    }
  }

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }
  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }
  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = root.service
    // settings is intentionally NOT injected onto the panel. The panel reads
    // settings through `hostWidget` (the bar widget), mirroring the clock
    // pattern. Writing it here fights the bar host's injectProps() and
    // turns into a no-op read-only error.
  }

  implicitWidth: contentRow.implicitWidth + Style.space(16)
  implicitHeight: barSize

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  // ---- Per-second repaint of the bar label -------------------------------
  // The service does NOT tick at 1 Hz while the popup is closed — that
  // was the whole point of v0.1.5. The cost is that the bar widget only
  // gets a fresh `secondsLeft` value once a minute, so the visible MM:SS
  // digit appears to "stick" for up to a minute at a time.
  //
  // To keep the bar showing a smooth per-second countdown without paying
  // for a global 1 Hz timer in the shell process, this widget runs its own
  // 1 Hz Timer ONLY while it is mapped to a screen (i.e. the bar is
  // visible somewhere) AND a phase is running. The Timer just calls
  // `service.recomputeSeconds()` — no logic, no state, no I/O — so the
  // wake-up cost is a single property read + comparison + a property
  // assignment when the digit changes. The widget is destroyed when the
  // bar host unmounts the widget, so the Timer goes with it.
  Timer {
    id: barTick
    interval: 1000
    repeat: true
    running: Model.isRunningPhase(root.phase)
    onTriggered: root.localNowSec = Math.floor(Date.now() / 1000)
  }

  // React to phase transitions: start ticking when a phase begins, stop
  // when it ends (or pauses).
  onPhaseChanged: barTick.running = Model.isRunningPhase(root.phase)

  // ---- Panel loader --------------------------------------------------------
  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // ---- The button itself --------------------------------------------------
  // WidgetButton owns the click handler; we overlay the visual content via
  // anchors and use its built-in `pressed(int)` signal for click routing.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    horizontalMargin: 0
    verticalPadding: 0
    // The label is empty: we paint our own content on top so the bar gets a
    // rounded pill background, the slot reserves space, and we keep the
    // tooltip + cursor behaviour for free.
    text: ""
    labelVisible: false
    hasVisualContent: true

    onPressed: function(b) {
      if (!root.service) return
      if (b === Qt.RightButton) {
        if (root.phase === Model.PHASE_PAUSED) root.service.resume()
        else if (Model.isRunningPhase(root.phase)) root.service.pause()
      } else if (b === Qt.MiddleButton) {
        root.service.skip()
      } else {
        root.toggle()
      }
    }

    // -- horizontal layout: [glyph] [mm:ss task] [dots]
    Row {
      id: contentRow
      anchors.centerIn: parent
      spacing: Style.space(6)
      visible: !root.vertical

      Item {
        width: Style.bar.iconSlot
        height: Style.bar.iconSlot
        anchors.verticalCenter: parent.verticalCenter

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: root.glyph
          color: root.lastThirty ? Color.urgent : button.foreground
          font.family: button.fontFamily
          font.pixelSize: button.fontSize
          Behavior on color {
            enabled: !root.bar || root.bar.foregroundAnimationEnabled
            ColorAnimation { duration: 200 }
          }
        }
      }

      Column {
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0

        Row {
          spacing: Style.space(6)
          Text {
            textFormat: Text.PlainText
            text: root.mmss
            color: root.lastThirty ? Color.urgent : button.foreground
            font.family: button.fontFamily
            font.pixelSize: button.fontSize
            font.bold: true
            Behavior on color {
              enabled: !root.bar || root.bar.foregroundAnimationEnabled
              ColorAnimation { duration: 200 }
            }
          }
          Text {
            textFormat: Text.PlainText
            text: root.taskLabel
            color: Qt.darker(button.foreground, 1.4)
            font.family: button.fontFamily
            font.pixelSize: Math.round(button.fontSize * 0.85)
            elide: Text.ElideRight
            visible: root.taskLabel !== ""
            width: Math.min(implicitWidth, Style.space(120))
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Row {
          spacing: 2
          visible: root.goalFilled > 0
          anchors.horizontalCenter: parent.horizontalCenter

          Repeater {
            model: root.goalTotal
            Rectangle {
              required property int modelData
              width: 5
              height: 2
              radius: 1
              color: modelData < root.goalFilled ? Color.accent : Qt.darker(button.foreground, 1.7)
            }
          }
        }
      }
    }

    // -- vertical layout: glyph + label, no time digits
    Column {
      anchors.centerIn: parent
      spacing: 0
      visible: root.vertical

      Text {
        textFormat: Text.PlainText
        text: root.glyph
        color: root.lastThirty ? Color.urgent : button.foreground
        font.family: button.fontFamily
        font.pixelSize: Math.round(button.fontSize * 0.9)
        horizontalAlignment: Text.AlignHCenter
        anchors.horizontalCenter: parent.horizontalCenter
      }
      Text {
        textFormat: Text.PlainText
        text: root.phase === Model.PHASE_WORK ? "FOCUS"
              : root.phase === Model.PHASE_PAUSED ? "PAUSE"
              : "BREAK"
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: Math.round(button.fontSize * 0.65)
        horizontalAlignment: Text.AlignHCenter
        anchors.horizontalCenter: parent.horizontalCenter
      }
    }
  }
}
