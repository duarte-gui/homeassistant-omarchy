import QtQuick
import qs.Commons
import qs.Ui
import qs.Ui as Kit
import "Model.js" as Model

// One cell of a tile grid: HA's tile, button, glance, entity, sensor, gauge and
// light cards all come out as one of these, because in a panel this size they
// differ in emphasis rather than in what they do.
//
// The body does the card's tap action. On a tile the icon is its own target
// and toggles, as it does in HA. Features a tile asks for — a brightness
// slider, cover arrows, a target temperature — are drawn underneath.
Item {
  id: tile

  property var spec: null
  property var host: null

  readonly property var service: host ? host.service : null
  readonly property string entityId: spec && spec.entity ? String(spec.entity) : ""
  readonly property string type: spec ? String(spec.type || "tile") : "tile"
  readonly property var st: service ? service.stateOf(entityId, service.stateRevision) : null
  readonly property var info: service && entityId !== "" ? service.infoOf(entityId) : null
  readonly property string domain: Model.domainOf(entityId)
  readonly property bool unavailable: entityId !== "" && Model.isUnavailable(st)
  readonly property bool active: Model.isActive(st)
  readonly property bool alarming: Model.isAlarming(st)
  readonly property bool busy: service ? service.isPending(entityId, service.pendingRevision) : false

  readonly property color foreground: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property color urgent: host ? host.urgent : Color.urgent
  readonly property string fontFamily: host ? host.fontFamily : Style.font.family

  readonly property bool compact: type === "glance" || type === "button"
  readonly property bool conditionsOk: !spec || !spec.conditions || spec.conditions.length === 0
    || (service && Model.conditionsMet(spec.conditions, service.stateStore, service.user, service.stateRevision))

  // A button card with no entity is a pure action.
  readonly property string defaultTap: type === "button"
    ? (entityId !== "" && Model.defaultTapIsToggle(entityId) ? "toggle" : (entityId !== "" ? "more-info" : "none"))
    : (type === "light" ? "toggle" : "more-info")

  readonly property real gaugeValue: {
    if (type !== "gauge" || !st) return 0
    var value = parseFloat(st.state)
    if (isNaN(value)) return 0
    var span = Math.max(0.0001, spec.max - spec.min)
    return Math.max(0, Math.min(1, (value - spec.min) / span))
  }

  readonly property var featureList: {
    var out = []
    var list = spec && spec.features ? spec.features : []
    for (var i = 0; i < list.length; i++) {
      var kind = list[i] && list[i].type ? String(list[i].type) : ""
      if (["light-brightness", "cover-open-close", "cover-position", "target-temperature",
           "fan-speed", "select-options", "numeric-input", "toggle"].indexOf(kind) >= 0) out.push(kind)
    }
    // HA's light card is a brightness slider in a frame.
    if (type === "light" && out.indexOf("light-brightness") < 0 && Model.supportsBrightness(st)) out.push("light-brightness")
    return out
  }

  visible: conditionsOk
  implicitHeight: visible ? frame.height : 0

  Rectangle {
    id: frame
    width: parent.width
    height: content.implicitHeight + Style.spacing.xl * 2
    radius: Style.cornerRadius
    color: Qt.rgba(tile.foreground.r, tile.foreground.g, tile.foreground.b,
      tile.active && !tile.unavailable ? 0.12 : (mouse.containsMouse ? 0.08 : 0.05))
    border.width: tile.alarming ? 1 : 0
    border.color: tile.urgent

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: function(event) {
        if (!tile.host) return
        if (event.button === Qt.RightButton) {
          if (tile.entityId !== "") tile.host.moreInfo(tile.entityId)
          return
        }
        tile.host.act(tile.spec.tapAction, tile.entityId, tile.defaultTap)
      }
    }

    Column {
      id: content
      x: Style.spacing.xl
      y: Style.spacing.xl
      width: parent.width - Style.spacing.xl * 2
      spacing: Style.spacing.md

      // ---- compact: icon above the name, centered (glance, button)
      Column {
        visible: tile.compact
        width: parent.width
        spacing: Style.spacing.xs

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: Model.entityGlyph(tile.entityId, tile.st, tile.spec ? tile.spec.icon : "", tile.info)
          font.family: tile.fontFamily
          font.pixelSize: tile.type === "button" ? Style.font.displayLarge : Style.font.display
          color: tile.unavailable ? tile.dim : tile.alarming ? tile.urgent : tile.active ? tile.foreground : tile.dim
        }
        Text {
          width: parent.width
          visible: tile.spec && tile.spec.showName
          horizontalAlignment: Text.AlignHCenter
          text: Model.entityName(tile.entityId, tile.st, tile.spec ? tile.spec.name : "")
          elide: Text.ElideRight
          font.family: tile.fontFamily
          font.pixelSize: Style.font.bodySmall
          color: tile.foreground
        }
        Text {
          width: parent.width
          visible: tile.spec && tile.spec.showState && tile.entityId !== ""
          horizontalAlignment: Text.AlignHCenter
          text: Model.stateText(tile.st, tile.info)
          elide: Text.ElideRight
          font.family: tile.fontFamily
          font.pixelSize: Style.font.caption
          color: tile.alarming ? tile.urgent : tile.dim
        }
      }

      // ---- wide: icon at the left, name and state beside it (tile, entity, sensor, gauge, light)
      Item {
        visible: !tile.compact
        width: parent.width
        height: Math.max(iconBox.height, wideLabels.implicitHeight)

        Rectangle {
          id: iconBox
          width: Style.space(34)
          height: width
          radius: Style.cornerRadius > 0 ? width / 2 : 0
          anchors.verticalCenter: parent.verticalCenter
          color: Qt.rgba(tile.foreground.r, tile.foreground.g, tile.foreground.b, iconMouse.containsMouse ? 0.16 : 0.08)

          Text {
            anchors.centerIn: parent
            text: Model.entityGlyph(tile.entityId, tile.st, tile.spec ? tile.spec.icon : "", tile.info)
            font.family: tile.fontFamily
            font.pixelSize: Style.font.iconLarge
            color: tile.unavailable ? tile.dim : tile.alarming ? tile.urgent : tile.active ? tile.foreground : tile.dim
          }

          // The tile's icon toggles, the body shows details — HA's split.
          MouseArea {
            id: iconMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: tile.type === "tile" && tile.entityId !== ""
            cursorShape: Qt.PointingHandCursor
            onClicked: if (tile.host) tile.host.act(tile.spec.iconTapAction, tile.entityId,
              Model.defaultTapIsToggle(tile.entityId) ? "toggle" : "more-info")
          }
        }

        Column {
          id: wideLabels
          anchors.left: iconBox.right
          anchors.leftMargin: Style.spacing.lg
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: 0

          Text {
            width: parent.width
            visible: !tile.spec || tile.spec.showName
            text: Model.entityName(tile.entityId, tile.st, tile.spec ? tile.spec.name : "")
            elide: Text.ElideRight
            font.family: tile.fontFamily
            font.pixelSize: Style.font.body
            color: tile.unavailable ? tile.dim : tile.foreground
          }
          Text {
            width: parent.width
            visible: tile.spec && tile.spec.showState && tile.entityId !== ""
            // An entity or sensor card is about the number, so it gets the big type.
            text: Model.stateText(tile.st, tile.info) + (tile.spec && tile.spec.unit ? " " + tile.spec.unit : "")
            elide: Text.ElideRight
            font.family: tile.fontFamily
            font.pixelSize: tile.type === "entity" || tile.type === "sensor" ? Style.font.heading : Style.font.caption
            color: tile.alarming ? tile.urgent : tile.dim
          }
        }
      }

      // ---- gauge
      Rectangle {
        visible: tile.type === "gauge"
        width: parent.width
        height: Style.space(6)
        radius: height / 2
        color: Qt.rgba(tile.foreground.r, tile.foreground.g, tile.foreground.b, 0.12)
        Rectangle {
          width: parent.width * tile.gaugeValue
          height: parent.height
          radius: parent.radius
          color: tile.gaugeValue > 0.85 ? tile.urgent : tile.foreground
        }
      }

      // ---- features
      Repeater {
        model: tile.featureList

        Loader {
          required property var modelData
          width: content.width
          sourceComponent: {
            switch (modelData) {
            case "light-brightness": return brightnessFeature
            case "cover-open-close": return coverFeature
            case "cover-position": return positionFeature
            case "target-temperature": return temperatureFeature
            case "fan-speed": return fanFeature
            case "select-options": return selectFeature
            case "numeric-input": return numericFeature
            case "toggle": return toggleFeature
            }
            return null
          }
        }
      }
    }
  }

  function call(name, data) {
    if (host) host.call(domain, name, data || {}, { entity_id: entityId })
  }

  Component {
    id: brightnessFeature
    PanelSlider {
      width: parent ? parent.width : 0
      bar: tile.host ? tile.host.bar : null
      minimum: 0
      maximum: 100
      step: 1
      integer: true
      value: Model.brightnessPercent(tile.st)
      enabled: !tile.unavailable
      onReleased: function(value) {
        if (value <= 0) tile.call("turn_off")
        else tile.call("turn_on", { brightness_pct: Math.round(value) })
      }
    }
  }

  Component {
    id: coverFeature
    Row {
      spacing: Style.spacing.sm
      Kit.Button {
        text: "Open"; iconText: Model.glyph("mdi:arrow-up"); bordered: true
        foreground: tile.foreground; fontFamily: tile.fontFamily; fontSize: Style.font.bodySmall
        onClicked: tile.call("open_cover")
      }
      Kit.Button {
        visible: Model.hasFeature(tile.st, Model.COVER.STOP)
        text: "Stop"; iconText: Model.glyph("mdi:stop"); bordered: true
        foreground: tile.foreground; fontFamily: tile.fontFamily; fontSize: Style.font.bodySmall
        onClicked: tile.call("stop_cover")
      }
      Kit.Button {
        text: "Close"; iconText: Model.glyph("mdi:arrow-down"); bordered: true
        foreground: tile.foreground; fontFamily: tile.fontFamily; fontSize: Style.font.bodySmall
        onClicked: tile.call("close_cover")
      }
    }
  }

  Component {
    id: positionFeature
    PanelSlider {
      width: parent ? parent.width : 0
      bar: tile.host ? tile.host.bar : null
      minimum: 0; maximum: 100; step: 1; integer: true
      value: tile.st && tile.st.attributes.current_position !== undefined ? Number(tile.st.attributes.current_position) : 0
      onReleased: function(value) { tile.call("set_cover_position", { position: Math.round(value) }) }
    }
  }

  Component {
    id: temperatureFeature
    Row {
      spacing: Style.spacing.md
      readonly property real target: tile.st && tile.st.attributes.temperature !== undefined && tile.st.attributes.temperature !== null
        ? Number(tile.st.attributes.temperature) : NaN
      PanelActionButton {
        iconText: Model.glyph("mdi:minus"); foreground: tile.foreground; fontFamily: tile.fontFamily
        enabled: !isNaN(parent.target)
        onClicked: tile.call("set_temperature", { temperature: Model.clampTemp(parent.target - Model.climateStep(tile.st), tile.st) })
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: isNaN(parent.target) ? "—" : parent.target + "°"
        font.family: tile.fontFamily; font.pixelSize: Style.font.title; color: tile.foreground
      }
      PanelActionButton {
        iconText: Model.glyph("mdi:plus"); foreground: tile.foreground; fontFamily: tile.fontFamily
        enabled: !isNaN(parent.target)
        onClicked: tile.call("set_temperature", { temperature: Model.clampTemp(parent.target + Model.climateStep(tile.st), tile.st) })
      }
    }
  }

  Component {
    id: fanFeature
    PanelSlider {
      width: parent ? parent.width : 0
      bar: tile.host ? tile.host.bar : null
      minimum: 0; maximum: 100; step: tile.st && tile.st.attributes.percentage_step ? Number(tile.st.attributes.percentage_step) : 1
      value: tile.st && tile.st.attributes.percentage ? Number(tile.st.attributes.percentage) : 0
      onReleased: function(value) { tile.call("set_percentage", { percentage: Math.round(value) }) }
    }
  }

  Component {
    id: selectFeature
    Dropdown {
      width: parent ? parent.width : 0
      showLabel: false
      value: tile.st ? String(tile.domain === "climate" ? tile.st.attributes.preset_mode : tile.st.state) : ""
      options: Model.optionsOf(tile.st, tile.domain === "climate" ? "preset_modes" : "options")
      foreground: tile.foreground
      fontFamily: tile.fontFamily
      onChanged: function(value) {
        if (tile.domain === "climate") tile.call("set_preset_mode", { preset_mode: value })
        else tile.call("select_option", { option: value })
      }
    }
  }

  Component {
    id: numericFeature
    PanelSlider {
      width: parent ? parent.width : 0
      bar: tile.host ? tile.host.bar : null
      readonly property var range: Model.numberRange(tile.st)
      minimum: range.min; maximum: range.max; step: range.step
      value: tile.st ? Number(tile.st.state) || 0 : 0
      onReleased: function(value) { tile.call("set_value", { value: Math.round(value / range.step) * range.step }) }
    }
  }

  Component {
    id: toggleFeature
    ToggleSwitch {
      checked: Model.isOn(tile.st)
      busy: tile.busy
      cursorRing: false
      foreground: tile.foreground
      onToggled: if (tile.service) tile.service.toggle(tile.entityId)
    }
  }
}
