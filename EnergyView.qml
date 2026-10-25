import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The energy cards, as one summary of today: each source in the Energy
// dashboard's preferences — grid in and out, solar, battery, gas, water — or,
// when none is set up, each tracked device, with what it used since midnight.
// HA's energy cards are charts on top of these same statistics; the totals are
// what most people look at them for.
Column {
  id: view

  property var host: null
  property bool devices: false

  readonly property var service: host ? host.service : null
  readonly property bool opened: host ? host.opened === true : false
  readonly property color foreground: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property color accent: host ? host.accent : Color.accent
  readonly property string fontFamily: host ? host.fontFamily : Style.font.family

  property var items: []
  property var totals: ({})
  property string error: ""
  property bool loaded: false

  readonly property real largest: {
    var top = 0
    for (var i = 0; i < items.length; i++) top = Math.max(top, Math.abs(totals[items[i].stat] || 0))
    return top
  }

  spacing: Style.spacing.sm

  function load() {
    if (!service || !service.online) return
    service.request({ type: "energy/get_prefs" }, function(ok, prefs, failure) {
      if (!view) return
      if (!ok) {
        view.loaded = true
        view.error = failure && failure.indexOf("not found") >= 0 ? "The Energy dashboard is not set up in Home Assistant."
          : (failure || "Home Assistant would not send the energy settings")
        return
      }
      var list = Model.energyItems(prefs, view.devices)
      view.items = list
      if (list.length === 0) {
        view.loaded = true
        view.error = "The Energy dashboard has nothing to track yet."
        return
      }
      view.service.request({
        type: "recorder/statistics_during_period",
        start_time: Model.startOfToday(Date.now()),
        statistic_ids: list.map(function(i) { return i.stat }),
        period: "hour",
        types: ["change"]
      }, function(ok2, result, failure2) {
        if (!view) return
        view.loaded = true
        view.error = ok2 ? "" : (failure2 || "Home Assistant would not send the statistics")
        var next = ({})
        for (var i = 0; i < list.length; i++) next[list[i].stat] = Model.statisticTotal(result ? result[list[i].stat] : [])
        view.totals = next
      })
    })
  }

  onOpenedChanged: if (opened) load()
  Component.onCompleted: load()

  // Statistics are compiled every five minutes; asking more often gains nothing.
  Timer {
    interval: 5 * 60 * 1000
    running: view.opened
    repeat: true
    onTriggered: view.load()
  }

  Repeater {
    model: view.items
    Column {
      required property var modelData
      width: view.width
      spacing: Style.spacing.xs
      readonly property var st: view.service ? view.service.stateOf(modelData.stat, view.service.stateRevision) : null
      readonly property var total: view.totals[modelData.stat]
      readonly property string unit: st && st.attributes && st.attributes.unit_of_measurement
        ? String(st.attributes.unit_of_measurement) : (modelData.kind === "water" || modelData.kind === "gas" ? "" : "kWh")

      Item {
        width: parent.width
        height: Math.max(label.implicitHeight, amount.implicitHeight)
        Text {
          id: label
          anchors.left: parent.left
          anchors.right: amount.left
          anchors.rightMargin: Style.spacing.md
          text: Model.glyph(Model.ENERGY_ICONS[modelData.kind] || "mdi:flash") + "  "
            + (modelData.label !== "" ? modelData.label : Model.entityName(modelData.stat, parent.parent.st, ""))
          elide: Text.ElideRight
          font.family: view.fontFamily
          font.pixelSize: Style.font.bodySmall
          color: view.foreground
        }
        Text {
          id: amount
          anchors.right: parent.right
          text: parent.parent.total === null || parent.parent.total === undefined ? "—"
            : Model.formatNumber(Math.round(parent.parent.total * 100) / 100) + " " + parent.parent.unit
          font.family: view.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          color: view.foreground
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: if (view.host) view.host.moreInfo(modelData.stat)
        }
      }

      Rectangle {
        width: parent.width
        height: Style.space(6)
        radius: height / 2
        color: Qt.rgba(view.foreground.r, view.foreground.g, view.foreground.b, 0.08)
        Rectangle {
          height: parent.height
          radius: parent.radius
          width: view.largest > 0 ? parent.width * Math.abs(parent.parent.total || 0) / view.largest : 0
          color: modelData.kind === "solar" ? "#e6a23c" : modelData.kind === "grid_out" ? "#6cc28b"
            : modelData.kind.indexOf("battery") === 0 ? "#c46be6" : view.accent
        }
      }
    }
  }

  Text {
    visible: view.loaded && view.error !== ""
    width: parent.width
    wrapMode: Text.WordWrap
    text: view.error
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    color: view.dim
  }

  Text {
    visible: !view.loaded
    text: "Loading today's energy…"
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    color: view.dim
  }
}
