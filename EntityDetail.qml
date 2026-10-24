import QtQuick
import qs.Commons
import qs.Ui
import qs.Ui as Kit
import "Model.js" as Model

// HA's more-info dialog, as a page of the panel: every control the entity's
// domain has, then its attributes. This is where a row's tap lands, so it is
// the one place that has to cover everything — a light's colour temperature,
// a cover's tilt, a vacuum's fan speed, a to-do list's items.
Column {
  id: detail

  property var host: null
  property string entityId: ""

  readonly property var service: host ? host.service : null
  readonly property var st: service ? service.stateOf(entityId, service.stateRevision) : null
  readonly property var info: service && entityId !== "" ? service.infoOf(entityId) : null
  readonly property var attrs: st && st.attributes ? st.attributes : ({})
  readonly property string domain: Model.domainOf(entityId)
  readonly property bool unavailable: Model.isUnavailable(st)
  readonly property bool busy: service ? service.isPending(entityId, service.pendingRevision) : false

  readonly property color foreground: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property color urgent: host ? host.urgent : Color.urgent
  readonly property string fontFamily: host ? host.fontFamily : Style.font.family

  spacing: Style.spacing.xxl

  function call(name, data) {
    if (host) host.call(domain, name, data || {}, { entity_id: entityId })
  }

  // `tick` is the binding dependency that keeps "5m ago" moving.
  function now(tick) {
    return Date.now() / 1000
  }

  // ---- header
  Item {
    width: parent.width
    height: Math.max(bigIcon.implicitHeight, headerText.implicitHeight)

    Text {
      id: bigIcon
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: Model.entityGlyph(detail.entityId, detail.st, "", detail.info)
      font.family: detail.fontFamily
      font.pixelSize: Style.font.displayLarge
      color: Model.isAlarming(detail.st) ? detail.urgent : Model.isActive(detail.st) ? detail.foreground : detail.dim
    }

    Column {
      id: headerText
      anchors.left: bigIcon.right
      anchors.leftMargin: Style.spacing.xl
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter

      Text {
        width: parent.width
        text: Model.entityName(detail.entityId, detail.st, "")
        elide: Text.ElideRight
        font.family: detail.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        color: detail.foreground
      }
      Text {
        width: parent.width
        text: Model.stateText(detail.st, detail.info)
          + (detail.st ? " · " + Model.lastChangedText(detail.st, detail.now(detail.service ? detail.service.tick : 0)) : "")
        elide: Text.ElideRight
        font.family: detail.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: detail.dim
      }
      Text {
        width: parent.width
        text: detail.entityId
        elide: Text.ElideRight
        font.family: detail.fontFamily
        font.pixelSize: Style.font.caption
        color: Qt.darker(detail.dim, 1.2)
      }
    }
  }

  Loader {
    width: parent.width
    sourceComponent: {
      switch (detail.domain) {
      case "light": return lightBody
      case "switch":
      case "input_boolean":
      case "siren":
      case "remote":
      case "group":
      case "automation": return switchBody
      case "fan": return fanBody
      case "cover": return coverBody
      case "climate":
      case "humidifier":
      case "water_heater": return thermostatBody
      case "media_player": return mediaBody
      case "alarm_control_panel": return alarmBody
      case "camera":
      case "image": return cameraBody
      case "weather": return weatherBody
      case "lock": return lockBody
      case "vacuum": return vacuumBody
      case "lawn_mower": return mowerBody
      case "valve": return valveBody
      case "input_number":
      case "number": return numberBody
      case "input_select":
      case "select": return selectBody
      case "input_text":
      case "text": return textBody
      case "scene":
      case "script":
      case "button":
      case "input_button": return pressBody
      case "update": return updateBody
      case "timer": return timerBody
      case "counter": return counterBody
      case "todo": return todoBody
      }
      return null
    }
  }

  // ---- attributes
  Column {
    width: parent.width
    spacing: Style.spacing.xs
    readonly property var rows: Model.attributeRows(detail.st)
    visible: rows.length > 0

    PanelSectionHeader {
      width: parent.width
      text: "Attributes"
      foreground: detail.foreground
      fontFamily: detail.fontFamily
    }

    Repeater {
      model: parent.rows
      Item {
        required property var modelData
        width: parent.width
        height: Math.max(keyText.implicitHeight, valueText.implicitHeight)
        Text {
          id: keyText
          text: modelData.key
          font.family: detail.fontFamily
          font.pixelSize: Style.font.caption
          color: detail.dim
        }
        Text {
          id: valueText
          anchors.right: parent.right
          width: Math.min(implicitWidth, parent.width * 0.6)
          horizontalAlignment: Text.AlignRight
          text: modelData.value
          wrapMode: Text.WrapAnywhere
          font.family: detail.fontFamily
          font.pixelSize: Style.font.caption
          color: detail.foreground
        }
      }
    }
  }

  Row {
    spacing: Style.spacing.sm
    Kit.Button {
      text: "History in Home Assistant"
      iconText: Model.glyph("mdi:chart-box-outline")
      bordered: true
      foreground: detail.foreground
      fontFamily: detail.fontFamily
      fontSize: Style.font.bodySmall
      onClicked: if (detail.host) detail.host.openUrl(detail.service.haUrl + "/history?entity_id=" + encodeURIComponent(detail.entityId))
    }
  }

  // ================================================================ bodies

  component OnOff: Kit.Toggle {
    width: parent ? parent.width : 0
    label: detail.st && detail.st.state === "on" ? "On" : "Off"
    description: detail.unavailable ? "Unavailable" : ""
    checked: Model.isOn(detail.st)
    enabled: !detail.unavailable
    foreground: detail.foreground
    fontFamily: detail.fontFamily
    onClicked: if (detail.service) detail.service.toggle(detail.entityId)
  }

  component Labeled: Column {
    property string label: ""
    property string valueText: ""
    width: parent ? parent.width : 0
    spacing: Style.spacing.xs
    Item {
      width: parent.width
      height: labelText.implicitHeight
      Text {
        id: labelText
        text: parent.parent.label
        font.family: detail.fontFamily
        font.pixelSize: Style.font.caption
        color: detail.dim
      }
      Text {
        anchors.right: parent.right
        text: parent.parent.valueText
        font.family: detail.fontFamily
        font.pixelSize: Style.font.caption
        color: detail.foreground
      }
    }
  }

  component ActionButton: Kit.Button {
    property string service: ""
    property var data: ({})
    bordered: true
    enabled: !detail.unavailable
    active: detail.busy
    foreground: detail.foreground
    fontFamily: detail.fontFamily
    fontSize: Style.font.bodySmall
    // A button that does something else sets service to "" and its own onClicked.
    onClicked: if (service !== "") detail.call(service, data)
  }

  Component {
    id: lightBody
    Column {
      spacing: Style.spacing.xl

      OnOff {}

      Labeled {
        visible: Model.supportsBrightness(detail.st)
        label: "Brightness"
        valueText: brightness.dragging ? Math.round(brightness.liveValue) + "%" : Model.brightnessPercent(detail.st) + "%"
        PanelSlider {
          id: brightness
          width: parent.width
          bar: detail.host ? detail.host.bar : null
          minimum: 0; maximum: 100; step: 1; integer: true
          value: Model.brightnessPercent(detail.st)
          onReleased: function(value) {
            if (value <= 0) detail.call("turn_off")
            else detail.call("turn_on", { brightness_pct: Math.round(value) })
          }
        }
      }

      Labeled {
        visible: Model.supportsColorTemp(detail.st)
        label: "Colour temperature"
        valueText: (kelvin.dragging ? Math.round(kelvin.liveValue) : (detail.attrs.color_temp_kelvin || "—")) + " K"
        PanelSlider {
          id: kelvin
          width: parent.width
          bar: detail.host ? detail.host.bar : null
          minimum: detail.attrs.min_color_temp_kelvin || 2000
          maximum: detail.attrs.max_color_temp_kelvin || 6500
          step: 50
          value: detail.attrs.color_temp_kelvin || minimum
          onReleased: function(value) { detail.call("turn_on", { color_temp_kelvin: Math.round(value) }) }
        }
      }

      Labeled {
        visible: Model.supportsColor(detail.st)
        label: "Colour"
        Flow {
          width: parent.width
          spacing: Style.spacing.sm
          Repeater {
            model: [[0, 100], [30, 100], [60, 100], [120, 100], [180, 100], [220, 100], [270, 100], [320, 100], [0, 0]]
            Rectangle {
              required property var modelData
              width: Style.space(26); height: width
              radius: Style.cornerRadius > 0 ? width / 2 : 0
              color: Qt.hsva(modelData[0] / 360, modelData[1] / 100, 1, 1)
              border.width: 1
              border.color: Qt.rgba(detail.foreground.r, detail.foreground.g, detail.foreground.b, 0.3)
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: detail.call("turn_on", { hs_color: [modelData[0], modelData[1]] })
              }
            }
          }
        }
      }

      Dropdown {
        visible: (detail.attrs.effect_list || []).length > 0
        width: parent.width
        label: "Effect"
        value: detail.attrs.effect ? String(detail.attrs.effect) : ""
        options: Model.optionsOf(detail.st, "effect_list")
        foreground: detail.foreground
        fontFamily: detail.fontFamily
        onChanged: function(value) { detail.call("turn_on", { effect: value }) }
      }
    }
  }

  Component {
    id: switchBody
    Column {
      spacing: Style.spacing.xl
      OnOff {}
      ActionButton {
        visible: detail.domain === "automation"
        text: "Run actions"
        iconText: Model.glyph("mdi:play")
        service: "trigger"
      }
    }
  }

  Component {
    id: fanBody
    Column {
      spacing: Style.spacing.xl
      OnOff {}
      Labeled {
        visible: Model.hasFeature(detail.st, Model.FAN.SET_SPEED)
        label: "Speed"
        valueText: (detail.attrs.percentage || 0) + "%"
        PanelSlider {
          width: parent.width
          bar: detail.host ? detail.host.bar : null
          minimum: 0; maximum: 100
          step: detail.attrs.percentage_step ? Number(detail.attrs.percentage_step) : 1
          value: detail.attrs.percentage || 0
          onReleased: function(value) { detail.call("set_percentage", { percentage: Math.round(value) }) }
        }
      }
      Kit.Toggle {
        visible: Model.hasFeature(detail.st, Model.FAN.OSCILLATE)
        width: parent.width
        label: "Oscillate"
        checked: detail.attrs.oscillating === true
        foreground: detail.foreground
        fontFamily: detail.fontFamily
        onClicked: detail.call("oscillate", { oscillating: !(detail.attrs.oscillating === true) })
      }
      ActionButton {
        visible: Model.hasFeature(detail.st, Model.FAN.DIRECTION)
        text: "Direction: " + Model.titleCase(detail.attrs.direction || "forward")
        service: "set_direction"
        data: ({ direction: detail.attrs.direction === "reverse" ? "forward" : "reverse" })
      }
      Dropdown {
        visible: (detail.attrs.preset_modes || []).length > 0
        width: parent.width
        label: "Preset"
        value: detail.attrs.preset_mode ? String(detail.attrs.preset_mode) : ""
        options: Model.optionsOf(detail.st, "preset_modes")
        foreground: detail.foreground
        fontFamily: detail.fontFamily
        onChanged: function(value) { detail.call("set_preset_mode", { preset_mode: value }) }
      }
    }
  }

  Component {
    id: coverBody
    Column {
      spacing: Style.spacing.xl
      Row {
        spacing: Style.spacing.sm
        ActionButton { visible: Model.hasFeature(detail.st, Model.COVER.OPEN); text: "Open"; iconText: Model.glyph("mdi:arrow-up"); service: "open_cover" }
        ActionButton { visible: Model.hasFeature(detail.st, Model.COVER.STOP); text: "Stop"; iconText: Model.glyph("mdi:stop"); service: "stop_cover" }
        ActionButton { visible: Model.hasFeature(detail.st, Model.COVER.CLOSE); text: "Close"; iconText: Model.glyph("mdi:arrow-down"); service: "close_cover" }
      }
      Labeled {
        visible: Model.hasFeature(detail.st, Model.COVER.SET_POSITION)
        label: "Position"
        valueText: (detail.attrs.current_position !== undefined ? detail.attrs.current_position : "—") + "%"
        PanelSlider {
          width: parent.width
          bar: detail.host ? detail.host.bar : null
          minimum: 0; maximum: 100; step: 1; integer: true
          value: detail.attrs.current_position || 0
          onReleased: function(value) { detail.call("set_cover_position", { position: Math.round(value) }) }
        }
      }
      Row {
        visible: Model.hasFeature(detail.st, Model.COVER.OPEN_TILT)
        spacing: Style.spacing.sm
        ActionButton { text: "Tilt open"; service: "open_cover_tilt" }
        ActionButton { visible: Model.hasFeature(detail.st, Model.COVER.STOP_TILT); text: "Stop tilt"; service: "stop_cover_tilt" }
        ActionButton { text: "Tilt close"; service: "close_cover_tilt" }
      }
      Labeled {
        visible: Model.hasFeature(detail.st, Model.COVER.SET_TILT)
        label: "Tilt"
        valueText: (detail.attrs.current_tilt_position !== undefined ? detail.attrs.current_tilt_position : "—") + "%"
        PanelSlider {
          width: parent.width
          bar: detail.host ? detail.host.bar : null
          minimum: 0; maximum: 100; step: 1; integer: true
          value: detail.attrs.current_tilt_position || 0
          onReleased: function(value) { detail.call("set_cover_tilt_position", { tilt_position: Math.round(value) }) }
        }
      }
    }
  }

  Component {
    id: thermostatBody
    ThermostatView { host: detail.host; entity: detail.entityId }
  }

  Component {
    id: mediaBody
    MediaView { host: detail.host; entity: detail.entityId }
  }

  Component {
    id: alarmBody
    AlarmView {
      host: detail.host
      entity: detail.entityId
      states: ["arm_home", "arm_away", "arm_night", "arm_vacation", "arm_custom_bypass"]
    }
  }

  Component {
    id: cameraBody
    Column {
      spacing: Style.spacing.lg
      CameraView {
        width: parent.width
        host: detail.host
        entity: detail.entityId
        large: true
        showName: false
        showState: false
        fit: "contain"
      }
      Text {
        width: parent.width
        visible: detail.domain === "camera"
        text: "Click the picture, or the play button, to watch the live stream in mpv."
        wrapMode: Text.WordWrap
        font.family: detail.fontFamily
        font.pixelSize: Style.font.caption
        color: detail.dim
      }
    }
  }

  Component {
    id: weatherBody
    WeatherView { host: detail.host; entity: detail.entityId; showForecast: true }
  }

  Component {
    id: lockBody
    Row {
      spacing: Style.spacing.sm
      ActionButton { text: "Lock"; iconText: Model.glyph("mdi:lock"); service: "lock"; enabled: detail.st && detail.st.state !== "locked" }
      ActionButton { text: "Unlock"; iconText: Model.glyph("mdi:lock-open-variant"); service: "unlock"; enabled: detail.st && detail.st.state !== "unlocked" }
      ActionButton { visible: Model.hasFeature(detail.st, Model.LOCK.OPEN); text: "Open"; iconText: Model.glyph("mdi:door-open"); service: "open" }
    }
  }

  Component {
    id: vacuumBody
    Column {
      spacing: Style.spacing.xl
      Flow {
        width: parent.width
        spacing: Style.spacing.sm
        ActionButton { text: "Start"; iconText: Model.glyph("mdi:play"); service: "start" }
        ActionButton { visible: Model.hasFeature(detail.st, Model.VACUUM.PAUSE); text: "Pause"; iconText: Model.glyph("mdi:pause"); service: "pause" }
        ActionButton { visible: Model.hasFeature(detail.st, Model.VACUUM.STOP); text: "Stop"; iconText: Model.glyph("mdi:stop"); service: "stop" }
        ActionButton { visible: Model.hasFeature(detail.st, Model.VACUUM.RETURN_HOME); text: "Dock"; iconText: Model.glyph("mdi:home-map-marker"); service: "return_to_base" }
        ActionButton { visible: Model.hasFeature(detail.st, Model.VACUUM.CLEAN_SPOT); text: "Spot"; iconText: Model.glyph("mdi:broom"); service: "clean_spot" }
        ActionButton { visible: Model.hasFeature(detail.st, Model.VACUUM.LOCATE); text: "Locate"; iconText: Model.glyph("mdi:map-marker"); service: "locate" }
      }
      Dropdown {
        visible: Model.hasFeature(detail.st, Model.VACUUM.FAN_SPEED) && (detail.attrs.fan_speed_list || []).length > 0
        width: parent.width
        label: "Fan speed"
        value: detail.attrs.fan_speed ? String(detail.attrs.fan_speed) : ""
        options: Model.optionsOf(detail.st, "fan_speed_list")
        foreground: detail.foreground
        fontFamily: detail.fontFamily
        onChanged: function(value) { detail.call("set_fan_speed", { fan_speed: value }) }
      }
    }
  }

  Component {
    id: mowerBody
    Row {
      spacing: Style.spacing.sm
      ActionButton { text: "Start"; iconText: Model.glyph("mdi:play"); service: "start_mowing" }
      ActionButton { text: "Pause"; iconText: Model.glyph("mdi:pause"); service: "pause" }
      ActionButton { text: "Dock"; iconText: Model.glyph("mdi:home-import-outline"); service: "dock" }
    }
  }

  Component {
    id: valveBody
    Column {
      spacing: Style.spacing.xl
      Row {
        spacing: Style.spacing.sm
        ActionButton { text: "Open"; service: "open_valve" }
        ActionButton { visible: Model.hasFeature(detail.st, 8); text: "Stop"; service: "stop_valve" }
        ActionButton { text: "Close"; service: "close_valve" }
      }
      Labeled {
        visible: Model.hasFeature(detail.st, 4)
        label: "Position"
        valueText: (detail.attrs.current_position !== undefined ? detail.attrs.current_position : "—") + "%"
        PanelSlider {
          width: parent.width
          bar: detail.host ? detail.host.bar : null
          minimum: 0; maximum: 100; step: 1; integer: true
          value: detail.attrs.current_position || 0
          onReleased: function(value) { detail.call("set_valve_position", { position: Math.round(value) }) }
        }
      }
    }
  }

  Component {
    id: numberBody
    Labeled {
      readonly property var range: Model.numberRange(detail.st)
      label: "Value"
      valueText: Model.unitJoin(Model.formatNumber(numberSlider.dragging ? numberSlider.liveValue : numberSlider.value,
        range.step < 1 ? 2 : 0), range.unit)
      PanelSlider {
        id: numberSlider
        width: parent.width
        bar: detail.host ? detail.host.bar : null
        minimum: parent.range.min; maximum: parent.range.max; step: parent.range.step
        value: detail.st ? Number(detail.st.state) || 0 : 0
        onReleased: function(value) {
          var step = parent.range.step || 1
          detail.call("set_value", { value: Math.round(Math.round(value / step) * step * 1000) / 1000 })
        }
      }
    }
  }

  Component {
    id: selectBody
    Dropdown {
      label: "Option"
      value: detail.st ? String(detail.st.state) : ""
      options: Model.optionsOf(detail.st, "options")
      foreground: detail.foreground
      fontFamily: detail.fontFamily
      onChanged: function(value) { detail.call("select_option", { option: value }) }
    }
  }

  Component {
    id: textBody
    Kit.TextField {
      text: detail.st ? String(detail.st.state) : ""
      password: detail.attrs.mode === "password"
      maximumLength: detail.attrs.max !== undefined ? Number(detail.attrs.max) : 255
      foreground: detail.foreground
      font.family: detail.fontFamily
      onActiveFocusChanged: if (detail.host) detail.host.noteEditing(activeFocus)
      onAccepted: detail.call("set_value", { value: text })
    }
  }

  Component {
    id: pressBody
    ActionButton {
      text: detail.domain === "scene" ? "Activate" : detail.domain === "script" ? (detail.st && detail.st.state === "on" ? "Stop" : "Run") : "Press"
      iconText: Model.glyph(detail.domain === "scene" ? "mdi:palette" : "mdi:play")
      onClicked: detail.service.toggle(detail.entityId)
      service: ""
    }
  }

  Component {
    id: updateBody
    Column {
      spacing: Style.spacing.lg
      Labeled { label: "Installed"; valueText: String(detail.attrs.installed_version || "—") }
      Labeled { label: "Latest"; valueText: String(detail.attrs.latest_version || "—") }
      Text {
        width: parent.width
        visible: text !== ""
        text: String(detail.attrs.release_summary || "")
        wrapMode: Text.WordWrap
        textFormat: Text.MarkdownText
        font.family: detail.fontFamily
        font.pixelSize: Style.font.caption
        color: detail.dim
      }
      Row {
        spacing: Style.spacing.sm
        ActionButton {
          visible: detail.st && detail.st.state === "on" && Model.hasFeature(detail.st, Model.UPDATE.INSTALL)
          text: detail.attrs.in_progress ? "Installing…" : "Install"
          service: ""
          onClicked: detail.host.confirmThen("Install " + Model.entityName(detail.entityId, detail.st, "") + "?",
            function() { detail.call("install") })
        }
        ActionButton {
          visible: detail.st && detail.st.state === "on"
          text: "Skip"
          service: "skip"
        }
        ActionButton {
          visible: !!detail.attrs.release_url
          text: "Release notes"
          service: ""
          onClicked: detail.host.openUrl(String(detail.attrs.release_url))
        }
      }
    }
  }

  Component {
    id: timerBody
    Row {
      spacing: Style.spacing.sm
      ActionButton { text: detail.st && detail.st.state === "active" ? "Pause" : "Start"; service: detail.st && detail.st.state === "active" ? "pause" : "start" }
      ActionButton { text: "Cancel"; service: "cancel" }
      ActionButton { text: "Finish"; service: "finish" }
    }
  }

  Component {
    id: counterBody
    Row {
      spacing: Style.spacing.sm
      ActionButton { text: "−"; service: "decrement" }
      ActionButton { text: "+"; service: "increment" }
      ActionButton { text: "Reset"; service: "reset" }
    }
  }

  // A to-do list's items are not in its state — the state is only a count —
  // so they are asked for, and asked again whenever that count moves.
  Component {
    id: todoBody
    Column {
      id: todo
      spacing: Style.spacing.sm
      property var items: []
      property string revisionKey: detail.st ? detail.st.state + "|" + detail.st.last_updated : ""

      function reload() {
        if (!detail.service) return
        detail.service.request({ type: "todo/item/list", entity_id: detail.entityId }, function(ok, result) {
          // The answer can arrive after the page moved on to another entity.
          if (!todo) return
          todo.items = ok && result && result.items ? result.items : []
        })
      }

      onRevisionKeyChanged: reload()
      Component.onCompleted: reload()

      Kit.TextField {
        width: parent.width
        placeholderText: "Add an item"
        foreground: detail.foreground
        font.family: detail.fontFamily
        onActiveFocusChanged: if (detail.host) detail.host.noteEditing(activeFocus)
        onAccepted: {
          if (text.trim() === "") return
          detail.call("add_item", { item: text.trim() })
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
            font.family: detail.fontFamily
            font.pixelSize: Style.font.iconLarge
            color: parent.done ? detail.dim : detail.foreground
          }
          Text {
            anchors.left: check.right
            anchors.leftMargin: Style.spacing.lg
            anchors.right: removeButton.left
            anchors.verticalCenter: parent.verticalCenter
            text: String(modelData.summary || "")
            elide: Text.ElideRight
            font.family: detail.fontFamily
            font.pixelSize: Style.font.body
            font.strikeout: parent.done
            color: parent.done ? detail.dim : detail.foreground
          }
          MouseArea {
            anchors.left: parent.left
            anchors.right: removeButton.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            cursorShape: Qt.PointingHandCursor
            onClicked: detail.call("update_item", { item: modelData.uid, status: parent.done ? "needs_action" : "completed" })
          }
          PanelActionButton {
            id: removeButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: Model.glyph("mdi:close")
            tooltipText: "Remove"
            foreground: detail.dim
            fontFamily: detail.fontFamily
            onClicked: detail.call("remove_item", { item: [modelData.uid] })
          }
        }
      }
    }
  }
}
