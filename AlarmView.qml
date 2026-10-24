import QtQuick
import qs.Commons
import qs.Ui
import qs.Ui as Kit
import "Model.js" as Model

// An alarm panel: what state it is in, the buttons that change it, and a
// keypad when the panel wants a code. The buttons are the card's `states`
// filtered by what the panel supports, plus Disarm while it is armed.
//
// The code is held here only until the call goes out and is cleared right
// after, whether it worked or not.
Column {
  id: alarm

  property var host: null
  property string entity: ""
  property string name: ""
  property var states: ["arm_home", "arm_away"]

  readonly property var service: host ? host.service : null
  readonly property var st: service ? service.stateOf(entity, service.stateRevision) : null
  readonly property var actions: Model.alarmActions(st, states)
  readonly property bool needsCode: actions.some(function(action) { return action.needsCode })
  readonly property bool numeric: st && st.attributes && st.attributes.code_format === "number"
  readonly property bool busy: service ? service.isPending(entity, service.pendingRevision) : false

  readonly property color foreground: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property color urgent: host ? host.urgent : Color.urgent
  readonly property string fontFamily: host ? host.fontFamily : Style.font.family

  property string code: ""

  spacing: Style.spacing.lg

  function run(action) {
    if (!host) return
    var data = ({})
    if (action.needsCode) {
      if (code === "") {
        host.flash("Type the code first")
        return
      }
      data.code = code
    }
    host.call("alarm_control_panel", action.service, data, { entity_id: entity })
    code = ""
    codeField.text = ""
  }

  Row {
    width: parent.width
    spacing: Style.spacing.lg

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: Model.entityGlyph(alarm.entity, alarm.st, "", null)
      font.family: alarm.fontFamily
      font.pixelSize: Style.font.displayLarge
      color: Model.isAlarming(alarm.st) ? alarm.urgent : Model.isActive(alarm.st) ? alarm.foreground : alarm.dim
    }

    Column {
      anchors.verticalCenter: parent.verticalCenter
      Text {
        text: Model.entityName(alarm.entity, alarm.st, alarm.name)
        font.family: alarm.fontFamily
        font.pixelSize: Style.font.body
        color: alarm.foreground
      }
      Text {
        text: Model.stateText(alarm.st, null)
        font.family: alarm.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        color: Model.isAlarming(alarm.st) ? alarm.urgent : alarm.foreground
      }
    }
  }

  Flow {
    width: parent.width
    spacing: Style.spacing.sm

    Repeater {
      model: alarm.actions

      Kit.Button {
        required property var modelData
        text: modelData.label
        bordered: true
        active: alarm.busy
        foreground: modelData.service === "alarm_disarm" ? alarm.urgent : alarm.foreground
        fontFamily: alarm.fontFamily
        onClicked: alarm.run(modelData)
      }
    }
  }

  Kit.TextField {
    id: codeField
    visible: alarm.needsCode
    width: Math.min(parent.width, Style.space(220))
    placeholderText: "Code"
    password: true
    echoMode: TextInput.Password
    inputMethodHints: alarm.numeric ? Qt.ImhDigitsOnly : Qt.ImhNone
    foreground: alarm.foreground
    accent: alarm.host ? alarm.host.accent : Color.accent
    font.family: alarm.fontFamily
    onTextChanged: alarm.code = text
    onActiveFocusChanged: if (alarm.host) alarm.host.noteEditing(activeFocus)
    onAccepted: if (alarm.actions.length === 1) alarm.run(alarm.actions[0])
  }

  Grid {
    visible: alarm.needsCode && alarm.numeric
    columns: 3
    spacing: Style.spacing.sm

    Repeater {
      model: ["1", "2", "3", "4", "5", "6", "7", "8", "9", "⌫", "0", "✓"]

      Kit.Button {
        required property string modelData
        width: Style.space(52)
        text: modelData
        bordered: true
        foreground: modelData === "✓" ? alarm.urgent : alarm.foreground
        fontFamily: alarm.fontFamily
        onClicked: {
          if (modelData === "⌫") codeField.text = codeField.text.slice(0, -1)
          else if (modelData === "✓") { if (alarm.actions.length > 0) alarm.run(alarm.actions[0]) }
          else codeField.text += modelData
        }
      }
    }
  }
}
