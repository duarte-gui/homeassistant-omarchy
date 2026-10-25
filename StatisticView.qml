import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A statistic card: one number over a period — today's energy, this week's
// lowest temperature — from recorder/statistic_during_period, which takes the
// card's own period config as it is.
Item {
  id: view

  property var host: null
  property string entity: ""
  property string name: ""
  property string icon: ""
  property string statType: "change"
  property var period: ({ calendar: { period: "day" } })
  property string unit: ""

  readonly property var service: host ? host.service : null
  readonly property bool opened: host ? host.opened === true : false
  readonly property var st: service ? service.stateOf(entity, service.stateRevision) : null
  readonly property color foreground: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property string fontFamily: host ? host.fontFamily : Style.font.family

  property var value: null
  property string error: ""

  readonly property string periodText: {
    var cal = period && period.calendar ? period.calendar : null
    if (!cal) return ""
    var names = { day: "Today", week: "This week", month: "This month", year: "This year" }
    return (cal.offset ? "" : names[cal.period]) || ""
  }

  implicitHeight: column.implicitHeight

  function load() {
    if (!service || !service.online || entity === "") return
    var message = { type: "recorder/statistic_during_period", statistic_id: entity, types: [statType] }
    for (var key in period) message[key] = period[key]
    service.request(message, function(ok, result, failure) {
      if (!view) return
      view.error = ok ? "" : (failure || "no statistic")
      view.value = ok && result && result[view.statType] !== undefined ? result[view.statType] : null
    })
  }

  onOpenedChanged: if (opened) load()
  Component.onCompleted: load()
  Timer { interval: 5 * 60 * 1000; running: view.opened; repeat: true; onTriggered: view.load() }

  Column {
    id: column
    width: parent.width
    spacing: Style.spacing.xs

    Text {
      width: parent.width
      text: Model.entityGlyph(view.entity, view.st, view.icon, null) + "  " + Model.entityName(view.entity, view.st, view.name)
      elide: Text.ElideRight
      font.family: view.fontFamily
      font.pixelSize: Style.font.bodySmall
      color: view.dim
    }
    Text {
      width: parent.width
      text: view.value === null ? (view.error !== "" ? "—" : "…")
        : Model.formatNumber(Math.round(Number(view.value) * 100) / 100) + " "
          + (view.unit !== "" ? view.unit : (view.st && view.st.attributes && view.st.attributes.unit_of_measurement ? view.st.attributes.unit_of_measurement : ""))
      elide: Text.ElideRight
      font.family: view.fontFamily
      font.pixelSize: Style.font.display
      font.bold: true
      color: view.foreground
    }
    Text {
      visible: text !== ""
      text: view.periodText
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      color: view.dim
    }
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: if (view.host) view.host.moreInfo(view.entity)
  }
}
