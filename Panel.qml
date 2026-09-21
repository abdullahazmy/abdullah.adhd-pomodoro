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

  property var anchorItem: null
  property var hostWidget: null
  property var service: null

  // ---- Live mirrors of the service state ----------------------------------
  readonly property string phase: service ? service.phase : Model.PHASE_IDLE
  readonly property int secondsLeft: service ? service.secondsLeft : 0
  readonly property string taskLabel: service ? (service.taskLabel || "") : ""
  readonly property int completedToday: service ? service.completedWorkSessionsToday : 0
  readonly property var settings: service ? service.settings : Model.defaultSettings()
  readonly property int dailyGoal: settings.dailyGoal

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
  property var todayEntries: []
  property string historyPath: (Quickshell.env("HOME") || "") + "/.local/state/abdullah.adhd-pomodoro/history.jsonl"

  FileView {
    id: historyFile
    path: root.historyPath
    watchChanges: true
    atomicWrites: false
    printErrors: false
    onLoaded: root.reloadHistory()
    onLoadFailed: root.todayEntries = []
    onFileChanged: reload()
  }

  Timer {
    id: historyRefreshTimer
    interval: 750
    repeat: false
    onTriggered: historyFile.reload()
  }

  // Whenever the panel becomes visible, re-read the history file. Cheap
  // because the file is small (one JSON line per completed WORK session).
  onOpenedChanged: if (opened) {
    historyFile.reload()
    // Reseed the task field from the service and grab focus so the user
    // can immediately start typing or editing.
    Qt.callLater(function() {
      taskField.text = root.taskLabel
      taskField.forceActiveFocus()
    })
  }

  function reloadHistory() {
    var entries = Model.parseHistoryFile(historyFile.text())
    root.todayEntries = Model.todayHistoryEntries(entries)
  }

  // ---- Actions ------------------------------------------------------------

  function startOrResume() {
    if (!service) return
    if (phase === Model.PHASE_PAUSED) service.resume()
    else service.start()
  }

  function togglePauseResume() {
    if (!service) return
    if (canPause) service.pause()
    else if (canResume) service.resume()
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
          onClicked: root.togglePauseResume()
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
      Column {
        width: parent.width
        spacing: Style.space(4)
        visible: root.todayEntries.length > 0

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
          value: root.settings.workMinutes
          from: 1
          to: 180
          stepSize: 1
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          onModified: if (value !== root.settings.workMinutes) root.updateSetting("workMinutes", value)
        }

        NumberField {
          width: parent.width
          label: "Short break minutes"
          value: root.settings.shortBreakMinutes
          from: 1
          to: 60
          stepSize: 1
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          onModified: if (value !== root.settings.shortBreakMinutes) root.updateSetting("shortBreakMinutes", value)
        }

        NumberField {
          width: parent.width
          label: "Long break minutes"
          value: root.settings.longBreakMinutes
          from: 1
          to: 90
          stepSize: 1
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          onModified: if (value !== root.settings.longBreakMinutes) root.updateSetting("longBreakMinutes", value)
        }

        NumberField {
          width: parent.width
          label: "Long break every N work sessions"
          value: root.settings.longBreakInterval
          from: 2
          to: 12
          stepSize: 1
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          onModified: if (value !== root.settings.longBreakInterval) root.updateSetting("longBreakInterval", value)
        }

        NumberField {
          width: parent.width
          label: "Daily goal (pomodoros)"
          value: root.settings.dailyGoal
          from: 1
          to: 30
          stepSize: 1
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          onModified: if (value !== root.settings.dailyGoal) root.updateSetting("dailyGoal", value)
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
            text: root.settings.preWarningSeconds.join(", ")
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

          ToggleSwitch {
            checked: root.settings.soundOnPhaseEnd
            foreground: root.bar.foreground
            onToggled: root.updateSetting("soundOnPhaseEnd", checked)
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

          ToggleSwitch {
            checked: root.settings.autostartNext
            foreground: root.bar.foreground
            onToggled: root.updateSetting("autostartNext", checked)
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
      }
    }
  }
}
