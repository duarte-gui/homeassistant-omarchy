import QtQuick
import qs.Commons
import qs.Ui
import qs.Ui as Kit
import "Model.js" as Model

// Home Assistant's notifications — what the bell in its sidebar holds: a
// failed login, a new device found, a repair to make. Each can be dismissed
// here, which dismisses it in Home Assistant too.
Column {
  id: view

  property var host: null

  readonly property var service: host ? host.service : null
  readonly property var list: service ? service.notificationList : []
  readonly property color foreground: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property color urgent: host ? host.urgent : Color.urgent
  readonly property string fontFamily: host ? host.fontFamily : Style.font.family

  spacing: Style.spacing.lg

  // `tick` keeps "5m ago" moving.
  function now(tick) {
    return Date.now() / 1000
  }

  Text {
    visible: view.list.length === 0
    width: parent.width
    text: "No notifications."
    font.family: view.fontFamily
    font.pixelSize: Style.font.bodySmall
    color: view.dim
  }

  Repeater {
    model: view.list
    Rectangle {
      required property var modelData
      width: view.width
      height: body.implicitHeight + Style.spacing.xl * 2
      radius: Style.cornerRadius
      color: Qt.rgba(view.foreground.r, view.foreground.g, view.foreground.b, 0.05)

      Column {
        id: body
        x: Style.spacing.xl
        y: Style.spacing.xl
        width: parent.width - Style.spacing.xl * 2 - dismiss.width
        spacing: Style.spacing.sm

        Text {
          width: parent.width
          text: String(modelData.title || "Notification")
          wrapMode: Text.WordWrap
          font.family: view.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          color: view.foreground
        }
        Text {
          width: parent.width
          text: Model.cleanMarkdown(String(modelData.message || ""))
          textFormat: Text.MarkdownText
          wrapMode: Text.WordWrap
          font.family: view.fontFamily
          font.pixelSize: Style.font.bodySmall
          color: view.foreground
          onLinkActivated: function(link) { if (view.host) view.host.openUrl(link) }
        }
        Text {
          readonly property real created: Date.parse(String(modelData.created_at || "")) / 1000
          visible: !isNaN(created)
          text: Model.relativeTime(created, view.now(view.service ? view.service.tick : 0))
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          color: view.dim
        }
      }

      PanelActionButton {
        id: dismiss
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.spacing.md
        iconText: Model.glyph("mdi:close")
        tooltipText: "Dismiss in Home Assistant"
        foreground: view.dim
        fontFamily: view.fontFamily
        onClicked: if (view.service) view.service.dismissNotification(modelData.notification_id)
      }
    }
  }

  Kit.Button {
    visible: view.list.length > 1
    text: "Dismiss all"
    iconText: Model.glyph("mdi:notification-clear-all")
    bordered: true
    foreground: view.foreground
    fontFamily: view.fontFamily
    fontSize: Style.font.bodySmall
    onClicked: if (view.host) view.host.confirmThen("Dismiss every notification in Home Assistant?", function() {
      view.service.dismissAllNotifications()
    })
  }
}
