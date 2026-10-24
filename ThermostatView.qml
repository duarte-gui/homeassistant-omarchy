import QtQuick
import qs.Commons
import qs.Ui
import qs.Ui as Kit
import "Model.js" as Model

// Thermostat, humidifier and water heater: the reading now, the target with
// steppers, and the modes the device offers. A climate entity with a target
// range gets two steppers, low and high.
Column {
  id: thermo

  property var host: null
  property string entity: ""
  property string name: ""

  readonly property var service: host ? host.service : null
  readonly property var st: service ? service.stateOf(entity, service.stateRevision) : null
  readonly property var attrs: st && st.attributes ? st.attributes : ({})
  readonly property string domain: Model.domainOf(entity)
  readonly property bool isHumidifier: domain === "humidifier"
  readonly property bool ranged: domain === "climate" && Model.hasFeature(st, Model.CLIMATE.TARGET_TEMPERATURE_RANGE)
    && attrs.target_temp_low !== undefined && attrs.target_temp_low !== null
  readonly property real target: {
    var value = isHumidifier ? attrs.humidity : attrs.temperature
    return value === undefined || value === null ? NaN : Number(value)
  }
  readonly property string unit: isHumidifier ? "%" : "°"

  readonly property color foreground: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property string fontFamily: host ? host.fontFamily : Style.font.family

  spacing: Style.spacing.lg

  function call(name, data) {
    if (host) host.call(domain, name, data || {}, { entity_id: entity })
  }

  function step(delta) {
    if (isHumidifier) {
      var low = attrs.min_humidity !== undefined ? Number(attrs.min_humidity) : 0
      var high = attrs.max_humidity !== undefined ? Number(attrs.max_humidity) : 100
      call("set_humidity", { humidity: Math.max(low, Math.min(high, Math.round(target + delta))) })
      return
    }
    call("set_temperature", { temperature: Model.clampTemp(target + delta * Model.climateStep(st), st) })
  }

  function stepRange(which, delta) {
    var low = Number(attrs.target_temp_low)
    var high = Number(attrs.target_temp_high)
    if (which === "low") low = Model.clampTemp(low + delta * Model.climateStep(st), st)
    else high = Model.clampTemp(high + delta * Model.climateStep(st), st)
    call("set_temperature", { target_temp_low: low, target_temp_high: high })
  }

  Item {
    width: parent.width
    height: Math.max(nameColumn.implicitHeight, stepper.implicitHeight)

    Column {
      id: nameColumn
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      Text {
        text: Model.entityName(thermo.entity, thermo.st, thermo.name)
        font.family: thermo.fontFamily
        font.pixelSize: Style.font.body
        color: thermo.foreground
      }
      Text {
        text: {
          var current = thermo.isHumidifier ? thermo.attrs.current_humidity : thermo.attrs.current_temperature
          var action = thermo.attrs.hvac_action ? Model.titleCase(thermo.attrs.hvac_action) : Model.titleCase(thermo.st ? thermo.st.state : "")
          return (current !== undefined && current !== null ? "Now " + current + thermo.unit + " · " : "") + action
        }
        font.family: thermo.fontFamily
        font.pixelSize: Style.font.caption
        color: thermo.dim
      }
    }

    Row {
      id: stepper
      visible: !thermo.ranged && !isNaN(thermo.target)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.md

      PanelActionButton {
        anchors.verticalCenter: parent.verticalCenter
        iconText: Model.glyph("mdi:minus"); tooltipText: "Lower"
        foreground: thermo.foreground; fontFamily: thermo.fontFamily
        onClicked: thermo.step(-1)
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: thermo.target + thermo.unit
        font.family: thermo.fontFamily
        font.pixelSize: Style.font.display
        color: thermo.foreground
      }
      PanelActionButton {
        anchors.verticalCenter: parent.verticalCenter
        iconText: Model.glyph("mdi:plus"); tooltipText: "Raise"
        foreground: thermo.foreground; fontFamily: thermo.fontFamily
        onClicked: thermo.step(1)
      }
    }
  }

  Row {
    visible: thermo.ranged
    spacing: Style.spacing.xxl

    Repeater {
      model: ["low", "high"]
      Row {
        required property string modelData
        spacing: Style.spacing.sm
        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: Model.glyph("mdi:minus"); foreground: thermo.foreground; fontFamily: thermo.fontFamily
          onClicked: thermo.stepRange(modelData, -1)
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: (modelData === "low" ? thermo.attrs.target_temp_low : thermo.attrs.target_temp_high) + "°"
          font.family: thermo.fontFamily; font.pixelSize: Style.font.heading; color: thermo.foreground
        }
        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: Model.glyph("mdi:plus"); foreground: thermo.foreground; fontFamily: thermo.fontFamily
          onClicked: thermo.stepRange(modelData, 1)
        }
      }
    }
  }

  // HVAC modes are few and the whole point, so they are buttons; the rest are
  // dropdowns.
  ButtonGroup {
    visible: thermo.domain === "climate" && (thermo.attrs.hvac_modes || []).length > 0
    options: (thermo.attrs.hvac_modes || []).map(function(mode) { return { value: String(mode), label: Model.titleCase(mode) } })
    value: thermo.st ? String(thermo.st.state) : ""
    foreground: thermo.foreground
    fontFamily: thermo.fontFamily
    fontSize: Style.font.bodySmall
    focusable: false
    onChanged: function(value) { thermo.call("set_hvac_mode", { hvac_mode: value }) }
  }

  Kit.Toggle {
    visible: thermo.domain === "humidifier" || thermo.domain === "water_heater" && Model.hasFeature(thermo.st, 8)
    width: parent.width
    label: thermo.st && thermo.st.state === "on" ? "On" : "Off"
    checked: thermo.st && thermo.st.state === "on"
    foreground: thermo.foreground
    fontFamily: thermo.fontFamily
    onClicked: thermo.call(thermo.st && thermo.st.state === "on" ? "turn_off" : "turn_on")
  }

  Repeater {
    model: [
      { attribute: "preset_modes", current: "preset_mode", service: "set_preset_mode", field: "preset_mode", label: "Preset" },
      { attribute: "fan_modes", current: "fan_mode", service: "set_fan_mode", field: "fan_mode", label: "Fan" },
      { attribute: "swing_modes", current: "swing_mode", service: "set_swing_mode", field: "swing_mode", label: "Swing" },
      { attribute: "available_modes", current: "mode", service: "set_mode", field: "mode", label: "Mode" },
      { attribute: "operation_list", current: "operation_mode", service: "set_operation_mode", field: "operation_mode", label: "Operation" }
    ]

    Dropdown {
      required property var modelData
      visible: (thermo.attrs[modelData.attribute] || []).length > 0
      width: thermo.width
      label: modelData.label
      showLabel: true
      value: thermo.attrs[modelData.current] !== undefined && thermo.attrs[modelData.current] !== null ? String(thermo.attrs[modelData.current]) : ""
      options: Model.optionsOf(thermo.st, modelData.attribute)
      foreground: thermo.foreground
      fontFamily: thermo.fontFamily
      onChanged: function(value) {
        var data = ({})
        data[modelData.field] = value
        thermo.call(modelData.service, data)
      }
    }
  }
}
