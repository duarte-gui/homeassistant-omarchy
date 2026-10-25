import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A logbook card: what changed, newest first. Asked for when it appears and
// again whenever one of its entities changes, so it stays current without
// polling; with no entities picked it is the whole house, refreshed on a timer.
Column {
  id: view

  property var host: null
  property var entities: []
  property real hours: 24
  property int limit: 12

  readonly property var service: host ? host.service : null
  readonly property bool opened: host ? host.opened === true : false
  readonly property color foreground: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property string fontFamily: host ? host.fontFamily : Style.font.family

  property var rows: []
  property string error: ""
  property bool loaded: false

  // What the watched entities look like now; a change in it means new lines.
  readonly property string watchKey: {
    if (!service || entities.length === 0) return ""
    var revision = service.stateRevision
    var parts = []
    for (var i = 0; i < entities.length; i++) {
      var st = service.stateOf(entities[i], revision)
      parts.push(st ? st.state + "@" + st.last_changed : "-")
    }
    return parts.join("|")
  }

  spacing: Style.spacing.xs

  // `tick` is the binding dependency that keeps "5m ago" moving.
  function now(tick) {
    return Date.now() / 1000
  }

  function load() {
    if (!service || !service.online) return
    var now = Date.now()
    var message = { type: "logbook/get_events", start_time: new Date(now - hours * 3600 * 1000).toISOString(),
      end_time: new Date(now).toISOString() }
    if (entities.length > 0) message.entity_ids = entities
    service.request(message, function(ok, result, failure) {
      if (!view) return
      view.loaded = true
      view.error = ok ? "" : (failure || "Home Assistant would not send the logbook")
      view.rows = ok ? Model.logbookRows(result, view.service.stateStore, view.limit) : []
    })
  }

  onWatchKeyChanged: reloadSoon.restart()
  onOpenedChanged: if (opened) load()
  Component.onCompleted: load()

  // Several entities changing in one burst make one request.
  Timer { id: reloadSoon; interval: 800; onTriggered: view.load() }
  Timer {
    interval: 60 * 1000
    running: view.opened && view.entities.length === 0
    repeat: true
    onTriggered: view.load()
  }

  Repeater {
    model: view.rows
    Item {
      required property var modelData
      width: view.width
      height: Math.max(Style.spacing.popupRowHeight * 0.8, line.implicitHeight + Style.spacing.xs * 2)

      Text {
        id: glyph
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(26)
        text: modelData.entity !== ""
          ? Model.entityGlyph(modelData.entity, { entity_id: modelData.entity, state: modelData.state, attributes:
              (view.service && view.service.stateOf(modelData.entity, 0) ? view.service.stateOf(modelData.entity, 0).attributes : {}) }, "", null)
          : Model.glyph("mdi:information-outline")
        font.family: view.fontFamily
        font.pixelSize: Style.font.body
        color: view.dim
      }

      Text {
        id: line
        anchors.left: glyph.right
        anchors.right: when.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        text: "<b>" + modelData.name.replace(/&/g, "&amp;").replace(/</g, "&lt;") + "</b> "
          + modelData.text.replace(/&/g, "&amp;").replace(/</g, "&lt;")
        textFormat: Text.StyledText
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
        font.family: view.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: view.foreground
      }

      Text {
        id: when
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: Model.relativeTime(modelData.when, view.now(view.service ? view.service.tick : 0))
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
        color: view.dim
      }

      MouseArea {
        anchors.fill: parent
        enabled: modelData.entity !== ""
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: if (view.host) view.host.moreInfo(modelData.entity)
      }
    }
  }

  Text {
    visible: view.loaded && view.rows.length === 0
    width: parent.width
    wrapMode: Text.WordWrap
    text: view.error !== "" ? view.error : "Nothing happened in the last " + view.hours + " hours."
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    color: view.dim
  }
}
