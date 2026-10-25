import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A map card: people and trackers where they are, zones as circles, on
// OpenStreetMap tiles.
//
// The tiles come through Home Assistant's own tile proxy (map_tiles, HA
// 2026.9+), which the frontend uses too: HA fetches and caches them, so this
// map talks to nobody but Home Assistant. Its token rotates every half hour
// and is asked for again well before it lapses. Tiles are plain Images on a
// Web Mercator grid — no QtLocation, which the shell does not ship.
//
// In a dark theme the tiles go dark too: a shader inverts their lightness and
// keeps their hue, as Home Assistant's frontend does, over the panel's colour.
//
// Drag to pan; the wheel, a double click or the buttons zoom.
Item {
  id: view

  property var host: null
  property var entities: []
  property real defaultZoom: 0
  property real aspect: 0.75

  readonly property var service: host ? host.service : null
  readonly property color foreground: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property color accent: host ? host.accent : Color.accent
  readonly property string fontFamily: host ? host.fontFamily : Style.font.family
  // "auto" follows the theme: a light foreground means a dark one.
  readonly property string mapTheme: service ? service.mapTheme : "auto"
  readonly property bool darkTiles: mapTheme === "dark"
    || (mapTheme !== "light" && (foreground.r * 0.3 + foreground.g * 0.59 + foreground.b * 0.11) > 0.5)
  readonly property color background: Color.popups.background
  readonly property bool opened: host ? host.opened === true : false

  property string tileToken: ""
  property string tileError: ""

  readonly property real tileSize: 256
  readonly property var markers: service ? Model.mapMarkers(entities, service.stateStore, service.stateRevision) : []

  property int zoom: 2
  // The centre, in tile units at `zoom`.
  property real centerX: 2
  property real centerY: 2
  property bool userMoved: false
  // Wheel travel not yet spent on a zoom step: a mouse notch is 120, a
  // touchpad sends many small deltas.
  property real wheelTravel: 0

  implicitHeight: Math.round(width * aspect)
  clip: true

  function fit() {
    if (width <= 0) return
    var target = Model.fitZoom(markers, width, height, tileSize, 17)
    zoom = defaultZoom > 0 && markers.filter(function(m) { return m.kind === "marker" }).length <= 1
      ? Math.min(target.zoom, defaultZoom) : target.zoom
    centerX = Model.tileX(target.lon, zoom)
    centerY = Model.tileY(target.lat, zoom)
    userMoved = false
  }

  // Zoom about a point on screen, so what is under the pointer stays there.
  function zoomBy(delta, px, py) {
    var next = Math.max(1, Math.min(19, zoom + delta))
    if (next === zoom) return
    var ax = centerX + (px - width / 2) / tileSize
    var ay = centerY + (py - height / 2) / tileSize
    var factor = Math.pow(2, next - zoom)
    centerX = ax * factor - (px - width / 2) / tileSize
    centerY = ay * factor - (py - height / 2) / tileSize
    zoom = next
    userMoved = true
  }

  function screenX(lon) { return (Model.tileX(lon, zoom) - centerX) * tileSize + width / 2 }
  function screenY(lat) { return (Model.tileY(lat, zoom) - centerY) * tileSize + height / 2 }

  // Metres per pixel at a latitude, for zone radii and GPS accuracy.
  function metresPerPixel(lat) {
    return 156543.03392 * Math.cos(lat * Math.PI / 180) / Math.pow(2, zoom) * (256 / tileSize)
  }

  readonly property var tiles: {
    var out = []
    if (width <= 0 || height <= 0 || tileToken === "" || !service) return out
    var n = Math.pow(2, zoom)
    var left = Math.floor(centerX - width / 2 / tileSize)
    var right = Math.floor(centerX + width / 2 / tileSize)
    var top = Math.max(0, Math.floor(centerY - height / 2 / tileSize))
    var bottom = Math.min(n - 1, Math.floor(centerY + height / 2 / tileSize))
    for (var ty = top; ty <= bottom; ty++) {
      for (var tx = left; tx <= right; tx++) {
        out.push({
          url: service.pictureUrl(Model.tilePath(zoom, tx, ty, tileToken)),
          x: (tx - centerX) * tileSize + width / 2,
          y: (ty - centerY) * tileSize + height / 2
        })
      }
    }
    return out
  }

  function loadToken() {
    if (!service || !service.online) return
    service.request({ type: "map_tiles/access_token" }, function(ok, result, error) {
      if (!view) return
      view.tileToken = ok && result && result.token ? String(result.token) : ""
      view.tileError = ok ? "" : "No map tiles from this Home Assistant (they need 2026.9 or later)."
    })
  }

  onOpenedChanged: if (opened) loadToken()

  // Two tokens are live at a time, each for 30 to 60 minutes.
  Timer {
    interval: 20 * 60 * 1000
    running: view.opened
    repeat: true
    onTriggered: view.loadToken()
  }

  onWidthChanged: if (!userMoved) fit()
  onHeightChanged: if (!userMoved) fit()
  onMarkersChanged: if (!userMoved) fit()
  Component.onCompleted: {
    fit()
    loadToken()
  }

  Rectangle {
    anchors.fill: parent
    color: view.darkTiles ? Qt.rgba(view.background.r, view.background.g, view.background.b, 1) : "#e8e4dc"
  }

  Item {
    anchors.fill: parent
    layer.enabled: view.darkTiles
    layer.effect: ShaderEffect {
      property color background: Qt.rgba(view.background.r, view.background.g, view.background.b, 1)
      fragmentShader: Qt.resolvedUrl("shaders/darkmap.frag.qsb")
    }

    Repeater {
      model: view.tiles
      Image {
        required property var modelData
        x: Math.round(modelData.x)
        y: Math.round(modelData.y)
        width: view.tileSize
        height: view.tileSize
        source: modelData.url
        asynchronous: true
        smooth: true
      }
    }
  }

  // ---- zones and accuracy circles
  Repeater {
    model: view.markers
    Rectangle {
      required property var modelData
      readonly property real r: modelData.radius / view.metresPerPixel(modelData.lat)
      visible: r >= 3 && (modelData.kind === "zone" || modelData.radius > 0)
      x: view.screenX(modelData.lon) - r
      y: view.screenY(modelData.lat) - r
      width: r * 2
      height: r * 2
      radius: r
      color: modelData.kind === "zone"
        ? (modelData.entity === "zone.home" ? Qt.rgba(view.accent.r, view.accent.g, view.accent.b, 0.22) : Qt.rgba(1, 0.6, 0.2, 0.18))
        : Qt.rgba(view.accent.r, view.accent.g, view.accent.b, 0.1)
      border.width: 1
      border.color: modelData.kind === "zone"
        ? (modelData.entity === "zone.home" ? view.accent : "#ff9933")
        : Qt.rgba(view.accent.r, view.accent.g, view.accent.b, 0.4)
    }
  }

  // zone icons, at their centres
  Repeater {
    model: view.markers.filter(function(m) { return m.kind === "zone" })
    Text {
      required property var modelData
      x: view.screenX(modelData.lon) - implicitWidth / 2
      y: view.screenY(modelData.lat) - implicitHeight / 2
      text: Model.glyph(modelData.icon !== "" ? modelData.icon : (modelData.entity === "zone.home" ? "mdi:home" : "mdi:map-marker-radius"))
      font.family: view.fontFamily
      font.pixelSize: Style.font.iconLarge
      color: modelData.entity === "zone.home" ? view.accent : "#ff9933"
      style: Text.Outline
      styleColor: Qt.rgba(0, 0, 0, 0.5)
    }
  }

  // ---- people and trackers
  Repeater {
    model: view.markers.filter(function(m) { return m.kind === "marker" })
    Item {
      id: pin
      required property var modelData
      required property int index
      readonly property real size: Style.space(36)
      // People in the same place fan out instead of stacking.
      readonly property int twins: view.markers.filter(function(m, i) {
        return m.kind === "marker" && Math.abs(m.lat - modelData.lat) < 1e-5 && Math.abs(m.lon - modelData.lon) < 1e-5
      }).length
      readonly property int rank: view.markers.filter(function(m) { return m.kind === "marker" }).slice(0, index).filter(function(m) {
        return Math.abs(m.lat - modelData.lat) < 1e-5 && Math.abs(m.lon - modelData.lon) < 1e-5
      }).length
      x: view.screenX(modelData.lon) - size / 2 + (twins > 1 ? (rank - (twins - 1) / 2) * size * 0.8 : 0)
      y: view.screenY(modelData.lat) - size / 2
      width: size
      height: size

      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: view.darkTiles ? "#2a2d33" : "white"
        border.width: Style.space(2)
        border.color: modelData.active ? view.accent : view.dim
      }

      Text {
        anchors.centerIn: parent
        visible: !photo.visible
        text: modelData.label
        font.family: view.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        color: view.darkTiles ? "white" : "#222"
      }

      Image {
        id: picture
        anchors.fill: parent
        anchors.margins: Style.space(3)
        visible: false
        source: modelData.picture !== "" && view.service ? view.service.pictureUrl(modelData.picture) : ""
        asynchronous: true
        fillMode: Image.PreserveAspectCrop
        sourceSize.width: 96
      }

      Rectangle {
        id: circleMask
        anchors.fill: picture
        radius: width / 2
        visible: false
        layer.enabled: true
      }

      MultiEffect {
        id: photo
        anchors.fill: picture
        source: picture
        visible: picture.status === Image.Ready
        maskEnabled: true
        maskSource: circleMask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
      }

      MouseArea {
        id: pinMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: if (view.host) view.host.moreInfo(modelData.entity)
        PanelToolTip {
          visible: pinMouse.containsMouse
          text: {
            var st = view.service ? view.service.stateOf(modelData.entity, view.service.stateRevision) : null
            return modelData.name + " · " + Model.stateText(st, null)
          }
        }
      }
    }
  }

  // ---- panning and zooming
  MouseArea {
    id: panArea
    anchors.fill: parent
    z: -1
    preventStealing: true
    cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
    property real lastX: 0
    property real lastY: 0
    onPressed: function(mouse) { lastX = mouse.x; lastY = mouse.y }
    onPositionChanged: function(mouse) {
      if (!pressed) return
      view.centerX -= (mouse.x - lastX) / view.tileSize
      view.centerY -= (mouse.y - lastY) / view.tileSize
      lastX = mouse.x
      lastY = mouse.y
      view.userMoved = true
    }
    onDoubleClicked: function(mouse) { view.zoomBy(1, mouse.x, mouse.y) }
    onWheel: function(wheel) {
      var delta = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.pixelDelta.y * 4
      // Turning the other way drops what was gathered the first way.
      if (delta * view.wheelTravel < 0) view.wheelTravel = 0
      view.wheelTravel += delta
      while (Math.abs(view.wheelTravel) >= 120) {
        var step = view.wheelTravel > 0 ? 1 : -1
        view.wheelTravel -= step * 120
        view.zoomBy(step, wheel.x, wheel.y)
      }
    }
  }

  // ---- controls
  Column {
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: Style.spacing.md
    spacing: Style.spacing.xs

    Repeater {
      model: [
        { glyph: "mdi:plus", tip: "Zoom in", act: function() { view.zoomBy(1, view.width / 2, view.height / 2) } },
        { glyph: "mdi:minus", tip: "Zoom out", act: function() { view.zoomBy(-1, view.width / 2, view.height / 2) } },
        { glyph: "mdi:crosshairs-gps", tip: "Fit everyone", act: function() { view.fit() } }
      ]
      Rectangle {
        required property var modelData
        width: Style.space(30)
        height: width
        radius: Style.cornerRadius
        color: Qt.rgba(0, 0, 0, 0.55)
        Text {
          anchors.centerIn: parent
          text: Model.glyph(modelData.glyph)
          font.family: view.fontFamily
          font.pixelSize: Style.font.body
          color: "white"
        }
        MouseArea {
          id: controlMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: modelData.act()
          PanelToolTip { visible: controlMouse.containsMouse; text: modelData.tip }
        }
      }
    }
  }

  // The tiles' licence asks for this, and HA shows it too.
  Rectangle {
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    width: credit.implicitWidth + Style.spacing.sm * 2
    height: credit.implicitHeight + Style.spacing.xs * 2
    color: Qt.rgba(0, 0, 0, 0.45)
    Text {
      id: credit
      anchors.centerIn: parent
      text: "© OpenStreetMap contributors"
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption * 0.85
      color: Qt.rgba(1, 1, 1, 0.85)
    }
  }

  Text {
    anchors.centerIn: parent
    visible: view.markers.length === 0 || view.tileError !== ""
    width: parent.width - Style.spacing.xl * 2
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.WordWrap
    text: view.tileError !== "" ? view.tileError : "Nobody here has a position."
    font.family: view.fontFamily
    font.pixelSize: Style.font.bodySmall
    color: view.dim
  }
}
