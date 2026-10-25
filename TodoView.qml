import QtQuick
import qs.Commons
import qs.Ui
import qs.Ui as Kit
import "Model.js" as Model

// A to-do list: its items, a field to add one, a tick to complete one. The
// items are not in the entity's state — the state is only a count — so they
// are asked for, and asked again whenever that count moves. The detail page
// of a todo entity and the todo-list card are both this.
Column {
  id: todo

  property var host: null
  property string entity: ""

  readonly property var service: host ? host.service : null
  readonly property var st: service ? service.stateOf(entity, service.stateRevision) : null
  readonly property color foreground: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property string fontFamily: host ? host.fontFamily : Style.font.family

  spacing: Style.spacing.sm

  property var items: []
  property string revisionKey: todo.st ? todo.st.state + "|" + todo.st.last_updated : ""

  function reload() {
    if (!todo.service || todo.entity === "") return
    todo.service.request({ type: "todo/item/list", entity_id: todo.entity }, function(ok, result) {
      // The answer can arrive after the page moved on to another entity.
      if (!todo) return
      todo.items = ok && result && result.items ? result.items : []
    })
  }

  function call(name, data) {
    if (host) host.call("todo", name, data || {}, { entity_id: entity })
  }

  onRevisionKeyChanged: reload()
  Component.onCompleted: reload()

  Kit.TextField {
    width: parent.width
    placeholderText: "Add an item"
    foreground: todo.foreground
    font.family: todo.fontFamily
    onActiveFocusChanged: if (todo.host) todo.host.noteEditing(activeFocus)
    onAccepted: {
      if (text.trim() === "") return
      todo.call("add_item", { item: text.trim() })
      text = ""
    }
  }

  Repeater {
    model: todo.items
    Item {
      required property var modelData
      width: todo.width
      height: Style.spacing.popupRowHeight
      readonly property bool done: modelData.status === "completed"

      Text {
        id: check
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: Model.glyph(parent.done ? "mdi:checkbox-marked" : "mdi:checkbox-blank-outline")
        font.family: todo.fontFamily
        font.pixelSize: Style.font.iconLarge
        color: parent.done ? todo.dim : todo.foreground
      }
      Text {
        anchors.left: check.right
        anchors.leftMargin: Style.spacing.lg
        anchors.right: removeButton.left
        anchors.verticalCenter: parent.verticalCenter
        text: String(modelData.summary || "")
        elide: Text.ElideRight
        font.family: todo.fontFamily
        font.pixelSize: Style.font.body
        font.strikeout: parent.done
        color: parent.done ? todo.dim : todo.foreground
      }
      MouseArea {
        anchors.left: parent.left
        anchors.right: removeButton.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        cursorShape: Qt.PointingHandCursor
        onClicked: todo.call("update_item", { item: modelData.uid, status: parent.done ? "needs_action" : "completed" })
      }
      PanelActionButton {
        id: removeButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        iconText: Model.glyph("mdi:close")
        tooltipText: "Remove"
        foreground: todo.dim
        fontFamily: todo.fontFamily
        onClicked: todo.call("remove_item", { item: [modelData.uid] })
      }
    }
  }
}
