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

  // The service is mounted at shell startup. Tolerate it being absent
  // briefly during the very first frame after a plugin enable.
  //
  // We use `serviceFor`, not `firstPartyServiceFor`. The latter is gated by
  // `pluginOwnsTarget` and only succeeds once the shell has classified us as
  // first-party. As an installed third-party plugin, `serviceFor` is the
  // supported lookup path — see PluginShellApi.qml and the
  // ssh-tunnel-manager / screens plugins for reference.
  readonly property var service: bar?.shell?.serviceFor
    ? bar.shell.serviceFor("abdullah.adhd-pomodoro")
    : null
  readonly property bool serviceReady: service !== null && service !== undefined

  // Mirrors of service state, defaulting to IDLE/0 so we render before the
  // service has finished its first reload.
  readonly property string phase: serviceReady ? service.phase : Model.PHASE_IDLE
  readonly property int secondsLeft: serviceReady ? service.secondsLeft : 0
  readonly property string taskLabel: serviceReady ? (service.taskLabel || "") : ""
  readonly property int completedToday: serviceReady ? service.completedWorkSessionsToday : 0
  readonly property int dailyGoal: serviceReady ? service.settings.dailyGoal : 8

  // Visual constants
  readonly property string glyph: Model.phaseGlyph(phase)
  readonly property string mmss: Model.formatMMSS(secondsLeft)
  // The last 30 s of a focus block: pulse the bar label so the user notices
  // even when they have drifted to a different window.
  readonly property bool lastThirty: phase === Model.PHASE_WORK && secondsLeft <= 30 && secondsLeft > 0
  readonly property int goalFilled: Math.min(completedToday, dailyGoal)
  readonly property int goalTotal: Math.max(dailyGoal, 1)

  // ---- Panel wiring (popout contract) -------------------------------------
  // The shell's `findPanelWidget` walks each live bar-widget slot and looks
  // for `open()`, `close()`, and an `opened` property on the widget root.
  // Defining those three names here is what makes `bar.shell.summon(...)`
  // and `bar.shell.togglePanel(...)` actually reach our popup. (Naming the
  // functions `openPanel`/`closePanel` is the bug that made the IPC toggle
  // no-op with "summon: no live bar widget".)
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  // Push the panel's open state into the service so it can switch between
  // the 60-second slow tick and the per-second fast tick. Bound to the
  // resolved `opened` property above so it fires on every open/close,
  // including the very first time the panel is shown.
  onOpenedChanged: {
    if (root.serviceReady && root.service && typeof root.service.setPopupOpen === "function") {
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
      if (!root.serviceReady) return
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
