import QtQuick
import qs.Commons
import qs.Ui
import qs.Ui as Kit
import "Model.js" as Model

// Assist, as a page of the panel: type what you would say to Home Assistant
// and read its answer. It goes to the conversation agent of the preferred
// Assist pipeline, in that pipeline's language, and the conversation carries
// on between messages the way HA's own Assist dialog does.
Column {
  id: view

  property var host: null

  readonly property var service: host ? host.service : null
  readonly property color foreground: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property color urgent: host ? host.urgent : Color.urgent
  readonly property color accent: host ? host.accent : Color.accent
  readonly property string fontFamily: host ? host.fontFamily : Style.font.family
  readonly property var log: service ? service.assistLog : []

  spacing: Style.spacing.lg

  function focusField() {
    field.forceActiveFocus()
  }

  function send() {
    var text = field.text.trim()
    if (text === "" || !service) return
    field.text = ""
    service.assist(text, null)
  }

  Text {
    visible: view.log.length === 0
    width: parent.width
    wrapMode: Text.WordWrap
    text: "Ask or tell Home Assistant anything you would say to Assist — “turn off the living room lights”, "
      + "“what is the temperature outside?”, “is the front door locked?”. It acts on the house, as Assist does."
    font.family: view.fontFamily
    font.pixelSize: Style.font.bodySmall
    color: view.dim
  }

  Repeater {
    model: view.log
    Item {
      required property var modelData
      readonly property bool mine: modelData.from === "me"
      width: view.width
      height: bubble.height

      Rectangle {
        id: bubble
        anchors.right: parent.mine ? parent.right : undefined
        anchors.left: parent.mine ? undefined : parent.left
        width: Math.min(view.width * 0.85, said.implicitWidth + Style.spacing.lg * 2)
        height: said.implicitHeight + Style.spacing.md * 2
        radius: Style.cornerRadius * 1.5
        color: parent.mine ? Qt.rgba(view.accent.r, view.accent.g, view.accent.b, 0.22)
          : Qt.rgba(view.foreground.r, view.foreground.g, view.foreground.b, 0.07)
        border.width: modelData.error ? 1 : 0
        border.color: view.urgent

        Text {
          id: said
          x: Style.spacing.lg
          y: Style.spacing.md
          width: Math.min(implicitWidth, view.width * 0.85 - Style.spacing.lg * 2)
          text: modelData.text
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          font.family: view.fontFamily
          font.pixelSize: Style.font.body
          color: view.foreground
        }
      }
    }
  }

  Text {
    visible: !!view.service && view.service.assistBusy
    text: "…"
    font.family: view.fontFamily
    font.pixelSize: Style.font.title
    color: view.dim
  }

  Item {
    width: parent.width
    height: field.height

    Kit.TextField {
      id: field
      anchors.left: parent.left
      anchors.right: sendButton.left
      anchors.rightMargin: Style.spacing.sm
      placeholderText: "Ask Assist…"
      foreground: view.foreground
      accent: view.urgent
      font.family: view.fontFamily
      enabled: !!view.service && view.service.online
      onActiveFocusChanged: if (view.host) view.host.noteEditing(activeFocus)
      onAccepted: view.send()
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          if (view.host) view.host.back()
          event.accepted = true
        }
      }
    }

    PanelActionButton {
      id: sendButton
      anchors.right: clearButton.left
      anchors.verticalCenter: parent.verticalCenter
      iconText: Model.glyph("mdi:send")
      tooltipText: "Send (Enter)"
      foreground: view.foreground
      fontFamily: view.fontFamily
      onClicked: view.send()
    }

    PanelActionButton {
      id: clearButton
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      iconText: Model.glyph("mdi:broom")
      tooltipText: "Start a new conversation"
      foreground: view.dim
      fontFamily: view.fontFamily
      onClicked: if (view.service) view.service.clearAssist()
    }
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: !!view.service && !!view.service.assistTarget && view.service.assistTarget.name !== undefined
      && view.service.assistTarget.name !== ""
    text: view.service && view.service.assistTarget
      ? "Using the “" + view.service.assistTarget.name + "” pipeline" : ""
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    color: view.dim
  }
}
