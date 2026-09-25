import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Popup panel anchored to the bar widget. Hosts the timer face, primary
// controls, today's session log, and a settings drawer.
//
// State lives in PomodoroService.qml. The panel binds to its reactive
// properties (phase, secondsLeft, completedWorkSessionsToday, taskLabel,
// settings) and writes back via service.start/pause/resume/reset/skip/
// setTask/updateSettings. The service persists every write to state.json
// so a shell crash mid-session does not lose progress.
Panel {
  id: root
  moduleName: "abdullah.adhd-pomodoro"
  ipcTarget: "abdullah.adhd-pomodoro"
  manageIpc: false    // The service owns the IPC handler so callers
                      // (bar widget, future CLI) reach the same methods.

  Component.onCompleted: {}

  property var anchorItem: null
  property var hostWidget: null
  property var service: null

  // ---- Live mirrors of the service state ----------------------------------
  // Each mirror points at the service's reactive property directly. Going
  // through a `var` intermediate (the earlier `readonly property var
  // settings`) breaks member-property change notifications, so bindings
  // like `checked: settings.soundOnPhaseEnd` would freeze on the first
  // value they saw and never re-evaluate when the service reassigned
  // its settings object. Binding straight to `service.settings.foo` keeps
  // the dependency chain on a real Q_PROPERTY.
  readonly property string phase: service ? service.phase : Model.PHASE_IDLE
  readonly property int secondsLeft: service ? service.secondsLeft : 0
  readonly property string taskLabel: service ? (service.taskLabel || "") : ""
  readonly property int completedToday: service ? service.completedWorkSessionsToday : 0
  readonly property var settings: service ? service.settings : Model.defaultSettings()
  readonly property int dailyGoal: service ? service.settings.dailyGoal : 8
  readonly property bool soundOnPhaseEnd: service ? service.settings.soundOnPhaseEnd : true
  readonly property bool autostartNext: service ? service.settings.autostartNext : false
  readonly property int workMinutes: service ? service.settings.workMinutes : 25
  readonly property int shortBreakMinutes: service ? service.settings.shortBreakMinutes : 5
  readonly property int longBreakMinutes: service ? service.settings.longBreakMinutes : 15
  readonly property int longBreakInterval: service ? service.settings.longBreakInterval : 4
  readonly property var preWarningSeconds: service ? service.settings.preWarningSeconds : [120, 30]

  // Seconds-precision MM:SS readout. The wall-clock-based service does
  // not tick at 1 Hz while the popup is closed; this binding re-evaluates
  // once a minute via the slow tick, then per second once the popup opens
  // or we are within 60 s of phase end.
  readonly property string mmss: Model.formatMMSS(secondsLeft)
  readonly property string phaseLabel: Model.phaseLabel(phase)
  readonly property string phaseGlyph: Model.phaseGlyph(phase)
  readonly property bool running: Model.isRunningPhase(phase)
  readonly property bool canStart: phase === Model.PHASE_IDLE || phase === Model.PHASE_PAUSED || !Model.isRunningPhase(phase)
  readonly property bool canPause: Model.isRunningPhase(phase)
  readonly property bool canResume: phase === Model.PHASE_PAUSED

  // ---- Settings drawer toggle --------------------------------------------
  property bool settingsOpen: false

  // ---- Today's history (lazy-loaded) -------------------------------------
  // history.jsonl is read by the service through a bounded Process (see
  // PomodoroService.qml historyReadProc). We do NOT load it here via a
  // FileView, since the file grows forever and an unbounded read on the
  // popup would balloon the shared shell's memory.
  property var todayEntries: []
  // Recompute todayEntries whenever the service refreshes its bounded
  // history read. The service exposes the bounded text as
  // `pendingHistoryText` and a `historyChanged` signal.
  function recomputeTodayEntries() {
    if (!root.service) {
      root.todayEntries = []
      return
    }
    var entries = Model.parseHistoryFile(root.service.pendingHistoryText || "")
    root.todayEntries = Model.todayHistoryEntries(entries)
  }
  Connections {
    target: root.service
    function onHistoryChanged() { root.recomputeTodayEntries() }
    function onPendingHistoryTextChanged() { root.recomputeTodayEntries() }
  }
  // Hide the entire SESSIONS list by default on days with many sessions,
  // so the Settings drawer is always reachable. Toggle "Show sessions
  // list" in the drawer to bring it back. Light days still show the list
  // automatically — the toggle only hides when there are enough entries
  // that the list would push settings below the fold.
  property int sessionsCollapseThreshold: 6
  readonly property bool sessionsListWouldOverflow:
    todayEntries.length > sessionsCollapseThreshold
  property bool sessionsHidden: false

  // Whenever the panel becomes visible, ask the service to refresh its
  // bounded history read. The result lands in service.pendingHistoryText,
  // which we recompute todayEntries from.
  onOpenedChanged: if (opened) {
    if (root.service && typeof root.service.refreshHistory === "function") {
      root.service.refreshHistory()
    }
    // Reseed the task field from the service and grab focus so the user
    // can immediately start typing or editing.
    Qt.callLater(function() {
      taskField.text = root.taskLabel
      taskField.forceActiveFocus()
    })
  }

  function reloadHistory() {
    if (root.service && typeof root.service.refreshHistory === "function") {
      root.service.refreshHistory()
    }
  }

  // ---- Actions ------------------------------------------------------------

  function toggleTimerControl() {
    if (!service) return
    // IDLE -> start a fresh WORK block.
    // PAUSED -> resume into the phase we paused in.
    // WORK / SHORT_BREAK / LONG_BREAK -> pause.
    if (canPause) service.pause()
    else if (canResume) service.resume()
    else if (canStart) service.start()
  }

  function updateSetting(key, value) {
    if (!service) return
    var next = Object.assign({}, settings)
    next[key] = value
    service.updateSettings(next)
  }

  function updatePreWarning(text) {
    var parts = String(text || "").split(",").map(function (s) { return Number(s.trim()); })
    var cleaned = parts.filter(function (n) { return isFinite(n) && n >= 0; })
    if (cleaned.length === 0) cleaned = [120, 30]
    updateSetting("preWarningSeconds", cleaned)
  }

  // ---- UI -----------------------------------------------------------------

  PopupCard {
    id: popup
    anchorItem: root.anchorItem
    bar: root.bar
    owner: root
    open: root.opened
    contentWidth: popup.fittedContentWidth(Style.space(360))
    contentHeight: popup.fittedContentHeight(contentColumn.implicitHeight)

    Column {
      id: contentColumn
      spacing: Style.space(12)
      width: popup.contentWidth - Style.space(24)

      // ---- Hero: phase glyph + countdown + task label -------------------
      Column {
        width: parent.width
        spacing: Style.space(6)

        Row {
          width: parent.width
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            text: root.phaseGlyph
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            width: parent.width - Style.space(48)

            Text {
              textFormat: Text.PlainText
              text: root.phaseLabel.toUpperCase()
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              font.letterSpacing: 1.5
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.mmss
              color: (root.running && root.secondsLeft <= 30 && root.secondsLeft > 0)
                ? Color.urgent
                : root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.displayLarge
              font.bold: true
              Behavior on color { ColorAnimation { duration: 200 } }
            }
          }
        }

        // Task label input. Required to Start is the soft ADHD nudge: we
        // do not block Start, but we keep the field focused when no label
        // is set so typing the first character immediately names the
        // session.
        Column {
          width: parent.width
          spacing: Style.space(4)

          Text {
            textFormat: Text.PlainText
            text: "Focusing on"
            color: Qt.darker(root.bar.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
          }

          Rectangle {
            width: parent.width
            // Single-line field, generous height so the glyphs are not
            // clipped by the rectangle bounds. The TextField itself is
            // padded above and below to give the text room to breathe.
            height: Math.round((Style.font.body * 1.25) + Style.space(16))
            color: Util.alpha(root.bar.foreground, 0.04)
            border.color: taskField.activeFocus
              ? Color.accent
              : Util.alpha(root.bar.foreground, 0.25)
            border.width: 1
            radius: Style.cornerRadius

            // TextField manages its own text. We seed it from the service
            // value and re-seed when the panel reopens; in-flight edits are
            // buffered in the field itself and committed on focus loss /
            // Enter. This avoids the binding loop where text: taskEdit and
            // onTextEdited: taskEdit = text fight each other, which leaves
            // the placeholder bleeding through the typed characters.
            //
            // We set both `color`/`placeholderTextColor` AND the QQC palette
            // — on some Qt stylesheets the implicit palette overrides the
            // top-level color, leaving typed text dimmed like a placeholder.
            // Forcing both makes the rendered colour deterministic.
            TextField {
              id: taskField
              anchors.fill: parent
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              verticalAlignment: TextInput.AlignVCenter
              wrapMode: TextEdit.NoWrap
              text: root.taskLabel
              placeholderText: root.running ? "What are you working on?" : "Name this focus block"
              color: root.bar.foreground
              placeholderTextColor: Util.alpha(root.bar.foreground, 0.45)
              selectionColor: Style.selectionFillFor(root.bar.foreground, Color.accent)
              selectedTextColor: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              font.bold: text.length > 0
              background: null
              selectByMouse: true
              palette.text: root.bar.foreground
              palette.placeholderText: Util.alpha(root.bar.foreground, 0.45)
              palette.base: "transparent"
              palette.highlight: Style.selectionFillFor(root.bar.foreground, Color.accent)
              palette.highlightedText: root.bar.foreground
              // Commit on focus loss / Enter. Editing the field does not
              // write back to root.taskLabel mid-keystroke, so the bar
              // widget only updates after the user confirms.
              onEditingFinished: {
                if (text !== root.taskLabel) root.service.setTask(text)
              }
              Keys.onReturnPressed: { taskField.editingFinished(); Qt.inputMethod.hide() }
              Keys.onEnterPressed: { taskField.editingFinished(); Qt.inputMethod.hide() }
            }
          }
        }
      }

      // ---- Controls -----------------------------------------------------
      RowLayout {
        width: parent.width
        spacing: Style.space(6)

        Button {
          objectName: "startButton"
          text: root.canPause ? "Pause"
                : root.canResume ? "Resume"
                : root.canStart ? "Start focus" : "Start"
          iconText: root.canPause ? "󰏤" : "󰐊"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          bordered: true
          focusable: true
          onClicked: root.toggleTimerControl()
          Layout.fillWidth: true
        }

        Button {
          text: "Reset"
          iconText: "󰜉"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          bordered: true
          focusable: true
          onClicked: if (root.service) root.service.reset()
        }

        Button {
          text: "Skip"
          iconText: "󰒭"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          bordered: true
          focusable: true
          onClicked: if (root.service) root.service.skip()
        }
      }

      // ---- Progress toward today's goal -------------------------------
      Column {
        width: parent.width
        spacing: Style.space(4)

        Text {
          textFormat: Text.PlainText
          text: "TODAY"
          color: Qt.darker(root.bar.foreground, 1.3)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.2
        }

        Row {
          width: parent.width
          spacing: Style.space(6)

          Row {
            spacing: 4
            anchors.verticalCenter: parent.verticalCenter

            Repeater {
              model: Math.max(root.dailyGoal, 1)
              Rectangle {
                required property int modelData
                width: Style.space(10)
                height: Style.space(10)
                radius: Style.space(5)
                color: modelData < root.completedToday
                  ? Color.accent
                  : "transparent"
                border.color: modelData < root.completedToday
                  ? Color.accent
                  : Util.alpha(root.bar.foreground, 0.35)
                border.width: 1
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            text: root.completedToday + " / " + root.dailyGoal + " pomodoros"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }

      // ---- Today's session log -----------------------------------------
      // The list is hidden when the user opts out via the settings drawer.
      // The TODAY header always shows the current count so the user can
      // still see their progress without having to open the list.
      Column {
        width: parent.width
        spacing: Style.space(4)
        visible: root.todayEntries.length > 0 && !root.sessionsHidden

        Text {
          textFormat: Text.PlainText
          text: "SESSIONS"
          color: Qt.darker(root.bar.foreground, 1.3)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.2
        }

        Repeater {
          model: root.todayEntries
          Row {
            required property var modelData
            width: parent.width
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              text: Model.formatLocalTime(modelData.ts)
              color: Qt.darker(root.bar.foreground, 1.3)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              textFormat: Text.PlainText
              text: (modelData.taskLabel && modelData.taskLabel.length > 0)
                ? modelData.taskLabel
                : "(no label)"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
              width: parent.width - Style.space(80)
              anchors.verticalCenter: parent.verticalCenter
            }
          }
        }
      }

      // ---- Settings drawer toggle --------------------------------------
      Item {
        width: parent.width
        height: Style.space(24)

        Button {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: root.settingsOpen ? "Hide settings" : "Settings"
          iconText: root.settingsOpen ? "󰅖" : "󰒓"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          bordered: true
          focusable: true
          onClicked: root.settingsOpen = !root.settingsOpen
        }
      }

      // ---- Settings drawer ---------------------------------------------
      Column {
        width: parent.width
        spacing: Style.space(8)
        visible: root.settingsOpen

        Rectangle {
          width: parent.width
          height: 1
          color: Util.alpha(root.bar.foreground, 0.18)
        }

        NumberField {
          width: parent.width
          label: "Focus minutes"
          value: root.workMinutes
          from: 1
          to: 180
          stepSize: 1
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          onModified: if (value !== root.workMinutes) root.updateSetting("workMinutes", value)
        }

        NumberField {
          width: parent.width
          label: "Short break minutes"
          value: root.shortBreakMinutes
          from: 1
          to: 60
          stepSize: 1
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          onModified: if (value !== root.shortBreakMinutes) root.updateSetting("shortBreakMinutes", value)
        }

        NumberField {
          width: parent.width
          label: "Long break minutes"
          value: root.longBreakMinutes
          from: 1
          to: 90
          stepSize: 1
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          onModified: if (value !== root.longBreakMinutes) root.updateSetting("longBreakMinutes", value)
        }

        NumberField {
          width: parent.width
          label: "Long break every N work sessions"
          value: root.longBreakInterval
          from: 2
          to: 12
          stepSize: 1
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          onModified: if (value !== root.longBreakInterval) root.updateSetting("longBreakInterval", value)
        }

        NumberField {
          width: parent.width
          label: "Daily goal (pomodoros)"
          value: root.dailyGoal
          from: 1
          to: 30
          stepSize: 1
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          onModified: if (value !== root.dailyGoal) root.updateSetting("dailyGoal", value)
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Text {
            textFormat: Text.PlainText
            text: "Pre-warning seconds (comma-separated)"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: preWarningField
            width: parent.width
            text: root.preWarningSeconds.join(", ")
            placeholderText: "e.g. 120, 30"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            background: Rectangle {
              color: "transparent"
              border.color: preWarningField.activeFocus
                ? Color.accent
                : Util.alpha(root.bar.foreground, 0.25)
              border.width: 1
              radius: Style.cornerRadius
            }
            padding: Style.space(6)
            onEditingFinished: root.updatePreWarning(text)
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(8)
          // Match the row height to the toggle so the MouseArea fills the
          // control and never gets clipped by an under-sized Row.
          height: Math.max(implicitHeight, Style.space(28))

          ToggleSwitch {
            id: soundToggle
            // Bind to the panel's mirror property so QML tracks the
            // change; `root.settings.soundOnPhaseEnd` (going through the
            // `var` settings alias above) freezes on first evaluation.
            checked: root.soundOnPhaseEnd
            foreground: root.bar.foreground
            interactive: true
            // ToggleSwitch's MouseArea fires `toggled()` but does NOT flip
            // its own `checked` — the consumer has to. The toggle reads
            // the previous value here, so flip it explicitly.
            onToggled: root.updateSetting("soundOnPhaseEnd", !checked)
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            textFormat: Text.PlainText
            text: "Sound at phase end"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(8)
          height: Math.max(implicitHeight, Style.space(28))

          ToggleSwitch {
            id: autostartToggle
            // Same mirror-property pattern as the sound toggle above.
            checked: root.autostartNext
            foreground: root.bar.foreground
            interactive: true
            onToggled: root.updateSetting("autostartNext", !checked)
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            textFormat: Text.PlainText
            text: "Auto-start next phase"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          ToggleSwitch {
            id: sessionsHiddenToggle
            // Bind to a `bool` mirror so the toggle's visual state tracks
            // the panel property directly (no `var` intermediate that
            // would freeze on first evaluation). `checked: !sessionsHidden`
            // because the toggle shows "Show sessions list" — checked
            // means the list is visible.
            checked: !root.sessionsHidden
            foreground: root.bar.foreground
            interactive: true
            // ToggleSwitch's MouseArea fires `toggled()` without flipping
            // its own `checked`. We toggle the underlying bool directly:
            // `sessionsHidden` starts at whatever the current value is,
            // and the new value is the negation.
            onToggled: root.sessionsHidden = !root.sessionsHidden
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            textFormat: Text.PlainText
            // Show the current count in the label so the user can tell
            // what they're hiding without opening the list first.
            text: "Show sessions list (" + root.todayEntries.length + ")"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }
    }
  }
}
