import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A chart of what entities did: history-graph, statistics-graph, a sensor
// card's graph, and the history on an entity's detail page.
//
// Numbers draw as lines on a Canvas; anything else (on/off, home/away, a
// select's options) as a timeline of coloured segments, one row per entity,
// the way HA's history panel splits them. Statistics are long-term recorder
// means — the mean is the line and min/max a band around it.
//
// The data is asked for once when the chart appears and again every few
// minutes while the panel is open; nothing is fetched while it is closed.
Column {
  id: view

  property var host: null
  property var entities: []
  property real hours: 24
  // history | statistics
  property string source: "history"
  property string period: "hour"
  property var statTypes: ["mean", "min", "max"]
  property string chartType: "line"
  property var minY: null
  property var maxY: null
  // "" or "sensor": a big current value above a small graph.
  property string style: ""
  property string name: ""
  property string icon: ""
  property int chartHeight: style === "sensor" ? Style.space(70) : Style.space(150)

  readonly property var service: host ? host.service : null
  readonly property bool opened: host ? host.opened === true : false
  readonly property color foreground: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property color accent: host ? host.accent : Color.accent
  readonly property string fontFamily: host ? host.fontFamily : Style.font.family

  // Line colours. The first is the theme's accent so a single sensor matches
  // the rest of the panel; the rest skip any that would look like it.
  readonly property var palette: Model.seriesPalette(accent.r, accent.g, accent.b)

  property var series: []
  property real startSec: 0
  property real endSec: 0
  property string error: ""
  property bool loading: false
  property int hoverX: -1

  readonly property var numericSeries: series.filter(function(s) { return s.numeric })
  readonly property var timelineSeries: source === "history" ? series.filter(function(s) { return !s.numeric && s.segments.length > 0 }) : []
  readonly property var scale: Model.niceScale(numericSeries, minY, maxY)
  readonly property var firstState: service && entities.length > 0 ? service.stateOf(entities[0], service.stateRevision) : null
  readonly property string unit: firstState && firstState.attributes && firstState.attributes.unit_of_measurement
    ? String(firstState.attributes.unit_of_measurement) : ""

  spacing: Style.spacing.sm

  function colorFor(index) {
    return palette[index % palette.length]
  }

  function load() {
    if (!service || !service.online || entities.length === 0) return
    var now = Date.now()
    var start = new Date(now - hours * 3600 * 1000)
    var requestStart = start.getTime() / 1000
    var requestEnd = now / 1000
    loading = true
    var message
    if (source === "statistics") {
      var types = statTypes.slice()
      message = { type: "recorder/statistics_during_period", start_time: start.toISOString(),
        end_time: new Date(now).toISOString(), statistic_ids: entities, period: period, types: types }
    } else {
      message = { type: "history/history_during_period", start_time: start.toISOString(),
        end_time: new Date(now).toISOString(), entity_ids: entities, minimal_response: true,
        no_attributes: true, significant_changes_only: false }
    }
    service.request(message, function(ok, result, failure) {
      // The chart may be gone by the time HA answers.
      if (!view) return
      view.loading = false
      if (!ok) {
        view.error = failure || "Home Assistant would not send the history"
        view.series = []
        return
      }
      view.error = ""
      view.startSec = requestStart
      view.endSec = requestEnd
      if (view.source === "statistics") {
        var out = []
        // The mean is the line; min and max become its band, drawn by paint().
        var lineType = view.statTypes.indexOf("mean") >= 0 ? "mean"
          : view.statTypes.indexOf("state") >= 0 ? "state"
          : view.statTypes.indexOf("sum") >= 0 ? "sum" : String(view.statTypes[0] || "mean")
        var main = Model.statisticsSeries(result, view.entities, lineType)
        var lows = view.statTypes.indexOf("min") >= 0 ? Model.statisticsSeries(result, view.entities, "min") : []
        var highs = view.statTypes.indexOf("max") >= 0 ? Model.statisticsSeries(result, view.entities, "max") : []
        for (var i = 0; i < main.length; i++) {
          main[i].low = lows.length > i ? lows[i].points : []
          main[i].high = highs.length > i ? highs[i].points : []
          out.push(main[i])
        }
        view.series = out
      } else {
        view.series = Model.historySeries(result, view.entities, requestStart, requestEnd)
      }
    })
  }

  onOpenedChanged: if (opened) load()
  onEntitiesChanged: load()
  Component.onCompleted: load()

  Connections {
    target: view.service
    function onOnlineChanged() { if (view.service.online) view.load() }
  }

  Timer {
    interval: view.source === "statistics" ? 15 * 60 * 1000 : 2 * 60 * 1000
    running: view.opened && view.visible
    repeat: true
    onTriggered: view.load()
  }

  // ---- the sensor card's header: icon, name, the value now
  Item {
    visible: view.style === "sensor"
    width: parent.width
    height: visible ? Math.max(sensorIcon.implicitHeight, sensorText.implicitHeight) : 0

    Text {
      id: sensorIcon
      anchors.left: parent.left
      anchors.top: parent.top
      text: Model.entityGlyph(view.entities[0] || "", view.firstState, view.icon,
        view.service ? view.service.infoOf(view.entities[0] || "") : null)
      font.family: view.fontFamily
      font.pixelSize: Style.font.iconLarge
      color: view.dim
    }

    Column {
      id: sensorText
      anchors.left: sensorIcon.right
      anchors.leftMargin: Style.spacing.lg
      anchors.right: parent.right
      Text {
        width: parent.width
        text: Model.entityName(view.entities[0] || "", view.firstState, view.name)
        elide: Text.ElideRight
        font.family: view.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: view.dim
      }
      Text {
        width: parent.width
        text: Model.stateText(view.firstState, view.service ? view.service.infoOf(view.entities[0] || "") : null)
        elide: Text.ElideRight
        font.family: view.fontFamily
        font.pixelSize: Style.font.display
        font.bold: true
        color: view.foreground
      }
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: if (view.host && view.entities.length > 0) view.host.moreInfo(view.entities[0])
    }
  }

  // ---- numbers: a line per entity
  Item {
    id: chartBox
    visible: view.numericSeries.length > 0
    width: parent.width
    height: visible ? view.chartHeight : 0

    readonly property real axisWidth: view.style === "sensor" ? 0 : Style.space(38)
    readonly property real axisHeight: view.style === "sensor" ? 0 : Style.space(16)
    readonly property real plotWidth: Math.max(1, width - axisWidth)
    readonly property real plotHeight: Math.max(1, height - axisHeight)

    function xFor(t) {
      var span = Math.max(1, view.endSec - view.startSec)
      return axisWidth + (t - view.startSec) / span * plotWidth
    }
    function yFor(v) {
      var range = Math.max(1e-9, view.scale.max - view.scale.min)
      return plotHeight - (v - view.scale.min) / range * plotHeight
    }

    // y labels and grid lines
    Repeater {
      model: view.style === "sensor" ? [] : (function() {
        var out = []
        for (var v = view.scale.min; v <= view.scale.max + view.scale.step / 2; v += view.scale.step) out.push(v)
        return out
      })()
      Item {
        required property var modelData
        width: chartBox.width
        y: chartBox.yFor(modelData)
        Rectangle {
          x: chartBox.axisWidth
          width: chartBox.plotWidth
          height: 1
          color: Qt.rgba(view.foreground.r, view.foreground.g, view.foreground.b, 0.08)
        }
        Text {
          anchors.right: parent.left
          anchors.rightMargin: -chartBox.axisWidth + Style.spacing.sm
          anchors.verticalCenter: parent.top
          text: Model.formatNumber(modelData, view.scale.step < 1 ? 1 : 0)
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          color: view.dim
        }
      }
    }

    // time labels
    Repeater {
      model: view.style === "sensor" ? [] : Model.timeTicks(view.startSec, view.endSec, Math.max(2, Math.floor(chartBox.plotWidth / Style.space(70))))
      Text {
        required property var modelData
        x: chartBox.xFor(modelData) - implicitWidth / 2
        y: chartBox.plotHeight + Style.spacing.xs
        text: Model.tickLabel(modelData, view.endSec - view.startSec)
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
        color: view.dim
      }
    }

    Canvas {
      id: canvas
      anchors.fill: parent
      renderStrategy: Canvas.Cooperative

      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var list = view.numericSeries
        for (var i = 0; i < list.length; i++) {
          var color = view.colorFor(i)
          var s = list[i]

          // min/max band, behind the line
          if (s.low && s.high && s.low.length > 1 && s.high.length === s.low.length) {
            ctx.beginPath()
            for (var b = 0; b < s.high.length; b++) {
              var hx = chartBox.xFor(s.high[b][0]), hy = chartBox.yFor(s.high[b][1])
              if (b === 0) ctx.moveTo(hx, hy); else ctx.lineTo(hx, hy)
            }
            for (b = s.low.length - 1; b >= 0; b--) ctx.lineTo(chartBox.xFor(s.low[b][0]), chartBox.yFor(s.low[b][1]))
            ctx.closePath()
            ctx.fillStyle = Qt.rgba(Qt.color(color).r, Qt.color(color).g, Qt.color(color).b, 0.15)
            ctx.fill()
          }

          if (view.chartType === "bar" && view.source === "statistics") {
            var barWidth = Math.max(1, chartBox.plotWidth / Math.max(1, s.points.length) * 0.7)
            ctx.fillStyle = color
            for (var k = 0; k < s.points.length; k++) {
              var bx = chartBox.xFor(s.points[k][0])
              var by = chartBox.yFor(s.points[k][1])
              var base = chartBox.yFor(Math.max(view.scale.min, 0))
              ctx.fillRect(bx, Math.min(by, base), barWidth, Math.abs(base - by))
            }
            continue
          }

          ctx.strokeStyle = color
          ctx.lineWidth = Math.max(1.5, Style.space(2))
          ctx.lineJoin = "round"
          ctx.beginPath()
          var drawing = false
          for (var j = 0; j < s.points.length; j++) {
            var p = s.points[j]
            if (p[1] === null) { drawing = false; continue }
            var x = chartBox.xFor(p[0]), y = chartBox.yFor(p[1])
            if (!drawing) { ctx.moveTo(x, y); drawing = true }
            else ctx.lineTo(x, y)
          }
          ctx.stroke()

          // A sensor card's graph is filled underneath, as HA draws it.
          if (view.style === "sensor" && list.length === 1 && s.points.length > 1) {
            ctx.lineTo(chartBox.xFor(s.points[s.points.length - 1][0]), chartBox.plotHeight)
            ctx.lineTo(chartBox.xFor(s.points[0][0]), chartBox.plotHeight)
            ctx.closePath()
            ctx.fillStyle = Qt.rgba(Qt.color(color).r, Qt.color(color).g, Qt.color(color).b, 0.12)
            ctx.fill()
          }
        }
      }

      Connections {
        target: view
        function onSeriesChanged() { canvas.requestPaint() }
        function onScaleChanged() { canvas.requestPaint() }
        function onAccentChanged() { canvas.requestPaint() }
      }
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
    }

    // The value under the pointer, for every line.
    Rectangle {
      visible: view.hoverX >= chartBox.axisWidth
      x: view.hoverX
      width: 1
      height: chartBox.plotHeight
      color: Qt.rgba(view.foreground.r, view.foreground.g, view.foreground.b, 0.35)
    }

    Rectangle {
      id: hoverCard
      visible: view.hoverX >= chartBox.axisWidth && hoverText.text !== ""
      x: Math.min(chartBox.width - width, view.hoverX + Style.spacing.md)
      y: Style.spacing.xs
      width: hoverText.implicitWidth + Style.spacing.md * 2
      height: hoverText.implicitHeight + Style.spacing.sm * 2
      radius: Style.cornerRadius
      color: Qt.rgba(0, 0, 0, 0.75)
      Text {
        id: hoverText
        anchors.centerIn: parent
        text: {
          if (view.hoverX < chartBox.axisWidth) return ""
          var span = Math.max(1, view.endSec - view.startSec)
          var t = view.startSec + (view.hoverX - chartBox.axisWidth) / chartBox.plotWidth * span
          var lines = [Model.tickLabel(t, 1)]
          for (var i = 0; i < view.numericSeries.length; i++) {
            var points = view.numericSeries[i].points
            var value = null
            for (var j = 0; j < points.length; j++) {
              if (points[j][0] > t) break
              value = points[j][1]
            }
            if (value === null) continue
            var id = view.numericSeries[i].entity
            var st = view.service ? view.service.stateOf(id, view.service.stateRevision) : null
            var unit = st && st.attributes && st.attributes.unit_of_measurement ? " " + st.attributes.unit_of_measurement : ""
            lines.push((view.numericSeries.length > 1 ? Model.entityName(id, st, "") + ": " : "")
              + Model.formatNumber(Math.round(value * 100) / 100) + unit)
          }
          return lines.join("\n")
        }
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
        color: "white"
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      onPositionChanged: function(mouse) { view.hoverX = mouse.x }
      onExited: view.hoverX = -1
    }
  }

  // legend, when there is more than one line
  Flow {
    visible: view.numericSeries.length > 1
    width: parent.width
    spacing: Style.spacing.lg
    Repeater {
      model: view.numericSeries
      Row {
        required property var modelData
        required property int index
        spacing: Style.spacing.xs
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(10); height: width; radius: width / 2
          color: view.colorFor(index)
        }
        Text {
          readonly property var st: view.service ? view.service.stateOf(modelData.entity, view.service.stateRevision) : null
          text: Model.entityName(modelData.entity, st, "") + (st ? " · " + Model.stateText(st, view.service.infoOf(modelData.entity)) : "")
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          color: view.dim
        }
      }
    }
  }

  // ---- everything else: one timeline per entity
  Repeater {
    model: view.timelineSeries
    Column {
      id: timelineRow
      required property var modelData
      width: view.width
      spacing: Style.spacing.xs
      readonly property var st: view.service ? view.service.stateOf(modelData.entity, view.service.stateRevision) : null

      Text {
        visible: view.entities.length > 1 || view.style !== "detail"
        width: parent.width
        text: Model.entityName(modelData.entity, parent.st, "")
        elide: Text.ElideRight
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
        color: view.dim
      }

      Item {
        width: parent.width
        height: Style.space(22)
        clip: true

        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius
          color: Qt.rgba(view.foreground.r, view.foreground.g, view.foreground.b, 0.05)
        }

        Repeater {
          model: modelData.segments
          Rectangle {
            required property var modelData
            readonly property real span: Math.max(1, view.endSec - view.startSec)
            x: (modelData.from - view.startSec) / span * parent.width
            width: Math.max(1, (modelData.to - modelData.from) / span * parent.width)
            height: parent.height
            color: Model.timelineColor(modelData.state, view.accent)

            Text {
              anchors.centerIn: parent
              visible: implicitWidth + Style.spacing.sm < parent.width
              text: Model.stateText({ entity_id: timelineRow.modelData.entity, state: modelData.state,
                attributes: timelineRow.st && timelineRow.st.attributes ? timelineRow.st.attributes : {} }, null)
              font.family: view.fontFamily
              font.pixelSize: Style.font.caption
              color: "white"
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.NoButton
              PanelToolTip {
                visible: parent.containsMouse
                text: modelData.state + " · " + Model.tickLabel(modelData.from, 1) + "–" + Model.tickLabel(modelData.to, 1)
              }
            }
          }
        }
      }
    }
  }

  // Hours under the timelines, when there is no line chart to carry them.
  Item {
    visible: view.timelineSeries.length > 0 && view.numericSeries.length === 0
    width: parent.width
    height: visible ? Style.font.caption + Style.spacing.xs : 0
    Repeater {
      model: parent.visible ? Model.timeTicks(view.startSec, view.endSec, Math.max(2, Math.floor(view.width / Style.space(70)))) : []
      Text {
        required property var modelData
        x: Math.max(0, Math.min(view.width - implicitWidth,
          (modelData - view.startSec) / Math.max(1, view.endSec - view.startSec) * view.width - implicitWidth / 2))
        text: Model.tickLabel(modelData, view.endSec - view.startSec)
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
        color: view.dim
      }
    }
  }

  Text {
    visible: view.error !== "" || (!view.loading && view.series.length > 0
      && view.numericSeries.length === 0 && view.timelineSeries.length === 0)
    width: parent.width
    wrapMode: Text.WordWrap
    text: view.error !== "" ? view.error : "No history in this period."
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    color: view.dim
  }

  Text {
    visible: view.loading && view.series.length === 0
    text: "Loading history…"
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    color: view.dim
  }
}
