import QtQuick
import qs.Commons
import qs.Ui
import qs.Ui as Kit
import "Model.js" as Model

// One row of an entities card: an icon, a name, and whatever control the
// entity's domain calls for — a switch for a light, arrows for a cover, a
// dropdown for a select. Tapping the name does the row's tap action, which is
// HA's default "show me everything about it" unless the dashboard says
// otherwise.
//
// The special rows HA allows in an entities card (section, divider, attribute,
// weblink, text, button, buttons) are drawn here too, so the card can hand
// every row to the same delegate.
Item {
  id: rowItem

  property var row: null
  property var host: null
  property bool stateColor: false

  readonly property var service: host ? host.service : null
  readonly property string entityId: row && row.entity ? String(row.entity) : ""
  readonly property string rowType: row ? String(row.type || "entity") : "entity"
  readonly property var st: service ? service.stateOf(entityId, service.stateRevision) : null
  readonly property var info: service && entityId !== "" ? service.infoOf(entityId) : null
  readonly property string domain: Model.domainOf(entityId)
  readonly property bool unavailable: entityId !== "" && Model.isUnavailable(st)
  readonly property bool busy: service ? service.isPending(entityId, service.pendingRevision) : false
  readonly property bool active: Model.isActive(st)
  readonly property bool alarming: Model.isAlarming(st)

  readonly property color foreground: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property color urgent: host ? host.urgent : Color.urgent
  readonly property string fontFamily: host ? host.fontFamily : Style.font.family

  readonly property bool conditionsOk: !row || !row.conditions || row.conditions.length === 0
    || (service && Model.conditionsMet(row.conditions, service.stateStore, service.user, service.stateRevision))

  readonly property string displayName: rowType === "section" ? String(row.label || "")
    : Model.entityName(entityId, st, row ? row.name : "")

  readonly property color iconColor: unavailable ? Qt.darker(dim, 1.3)
    : alarming ? urgent
    : active ? foreground
    : dim

  visible: conditionsOk
  height: visible ? body.height : 0
  width: parent ? parent.width : 0

  function callDomain(name, data) {
    if (host) host.call(domain, name, data || {}, { entity_id: entityId })
  }

  // The control on the right, by domain. "state" is just the text.
  function controlKind() {
    if (rowType === "simple" || !st) return "state"
    if (Model.hasToggle(st)) return "toggle"
    switch (domain) {
    case "lock": return "lock"
    case "cover": return "cover"
    case "valve": return "valve"
    case "scene":
    case "script":
    case "button":
    case "input_button": return "press"
    case "input_select":
    case "select": return "select"
    case "input_number":
    case "number": return "number"
    case "input_text":
    case "text": return "text"
    case "media_player": return "media"
    case "climate":
    case "water_heater": return "climate"
    case "vacuum": return "vacuum"
    case "update": return st.state === "on" && Model.hasFeature(st, Model.UPDATE.INSTALL) ? "update" : "state"
    }
    return "state"
  }

  // `tick` is the binding dependency that keeps "5m ago" moving.
  function secondary(tick) {
    if (!row || !row.secondary || !st) return ""
    return Model.secondaryText(row.secondary, st, Date.now() / 1000)
  }

  Item {
    id: body
    width: parent.width
    height: {
      if (rowItem.rowType === "divider") return Style.spacing.lg * 2 + 1
      if (rowItem.rowType === "section") return sectionText.implicitHeight + Style.spacing.lg * 2
      if (rowItem.rowType === "buttons") return buttonsRow.implicitHeight + Style.spacing.sm * 2
      return Math.max(Style.spacing.controlHeight + Style.spacing.md, labels.implicitHeight + Style.spacing.md)
    }

    // ---- divider
    Rectangle {
      visible: rowItem.rowType === "divider"
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width
      height: 1
      color: Qt.rgba(rowItem.foreground.r, rowItem.foreground.g, rowItem.foreground.b, 0.12)
    }

    // ---- section
    Text {
      id: sectionText
      visible: rowItem.rowType === "section"
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.spacing.sm
      text: rowItem.displayName
      font.family: rowItem.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      color: rowItem.dim
    }

    // ---- buttons: a row of entity icons that each do their tap action
    Row {
      id: buttonsRow
      visible: rowItem.rowType === "buttons"
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.lg

      Repeater {
        model: rowItem.rowType === "buttons" ? (rowItem.row.items || []) : []

        PanelActionButton {
          required property var modelData
          readonly property var itemState: rowItem.service ? rowItem.service.stateOf(modelData.entity, rowItem.service.stateRevision) : null
          iconText: Model.entityGlyph(modelData.entity, itemState, modelData.icon, null)
          tooltipText: Model.entityName(modelData.entity, itemState, modelData.name) + " · " + Model.stateText(itemState, null)
          foreground: Model.isActive(itemState) ? rowItem.foreground : rowItem.dim
          fontFamily: rowItem.fontFamily
          onClicked: if (rowItem.host) rowItem.host.act(modelData.tap_action, modelData.entity, "toggle")
        }
      }
    }

    // ---- everything else: icon, name, control
    Item {
      id: standard
      visible: ["divider", "section", "buttons"].indexOf(rowItem.rowType) < 0
      anchors.fill: parent

      Text {
        id: icon
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(24)
        horizontalAlignment: Text.AlignHCenter
        text: rowItem.rowType === "weblink" ? Model.glyph(rowItem.row.icon || "mdi:link")
          : rowItem.rowType === "text" || rowItem.rowType === "button" && rowItem.entityId === ""
          ? Model.glyph(rowItem.row.icon || (rowItem.rowType === "button" ? "mdi:gesture-tap-button" : "mdi:text"))
          : Model.entityGlyph(rowItem.entityId, rowItem.st, rowItem.row ? rowItem.row.icon : "", rowItem.info)
        font.family: rowItem.fontFamily
        font.pixelSize: Style.font.iconLarge
        color: rowItem.iconColor
      }

      Column {
        id: labels
        anchors.left: icon.right
        anchors.leftMargin: Style.spacing.lg
        anchors.right: control.left
        anchors.rightMargin: Style.spacing.lg
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0

        Text {
          width: parent.width
          text: rowItem.rowType === "weblink" || rowItem.rowType === "text" || rowItem.rowType === "button" && rowItem.entityId === ""
            ? String(rowItem.row.name || "")
            : rowItem.displayName
          elide: Text.ElideRight
          font.family: rowItem.fontFamily
          font.pixelSize: Style.font.body
          color: rowItem.unavailable ? rowItem.dim : rowItem.foreground
        }

        Text {
          width: parent.width
          visible: text !== ""
          text: rowItem.secondary(rowItem.service ? rowItem.service.tick : 0)
          elide: Text.ElideRight
          font.family: rowItem.fontFamily
          font.pixelSize: Style.font.caption
          color: rowItem.dim
        }
      }

      MouseArea {
        anchors.left: parent.left
        anchors.right: control.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: function(event) {
          if (!rowItem.host) return
          if (rowItem.rowType === "weblink") { rowItem.host.openUrl(rowItem.row.url); return }
          if (rowItem.rowType === "text") return
          if (event.button === Qt.RightButton) {
            if (rowItem.entityId !== "") rowItem.host.moreInfo(rowItem.entityId)
            return
          }
          if (rowItem.rowType === "button") {
            rowItem.host.act(rowItem.row.tapAction, rowItem.entityId, rowItem.entityId !== "" ? "toggle" : "none")
            return
          }
          if (rowItem.entityId !== "") rowItem.host.act(rowItem.row.tapAction, rowItem.entityId, "more-info")
        }
      }

      Loader {
        id: control
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        sourceComponent: {
          switch (rowItem.rowType) {
          case "attribute": return attributeText
          case "text": return plainText
          case "weblink": return null
          case "button": return pressButton
          }
          switch (rowItem.controlKind()) {
          case "toggle": return toggleControl
          case "lock": return lockControl
          case "cover": return coverControl
          case "valve": return valveControl
          case "press": return pressButton
          case "select": return selectControl
          case "number": return numberControl
          case "text": return textControl
          case "media": return mediaControl
          case "climate": return climateControl
          case "vacuum": return vacuumControl
          case "update": return updateControl
          }
          return stateText
        }
      }
    }
  }

  // ---------------------------------------------------------------- controls

  Component {
    id: stateText
    Text {
      text: Model.stateText(rowItem.st, rowItem.info)
      font.family: rowItem.fontFamily
      font.pixelSize: Style.font.bodySmall
      color: rowItem.alarming ? rowItem.urgent : (rowItem.stateColor && rowItem.active ? rowItem.foreground : rowItem.dim)
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideLeft
      width: Math.min(implicitWidth, rowItem.width * 0.45)
    }
  }

  Component {
    id: plainText
    Text {
      text: String(rowItem.row.text || "")
      font.family: rowItem.fontFamily
      font.pixelSize: Style.font.bodySmall
      color: rowItem.dim
    }
  }

  Component {
    id: attributeText
    Text {
      text: Model.attributeText(rowItem.st, rowItem.row.attribute, rowItem.row.prefix, rowItem.row.suffix)
      font.family: rowItem.fontFamily
      font.pixelSize: Style.font.bodySmall
      color: rowItem.dim
    }
  }

  Component {
    id: toggleControl
    ToggleSwitch {
      checked: Model.isOn(rowItem.st)
      busy: rowItem.busy
      interactive: !rowItem.unavailable
      cursorRing: false
      foreground: rowItem.foreground
      accent: rowItem.host ? rowItem.host.accent : Color.accent
      onToggled: if (rowItem.service) rowItem.service.toggle(rowItem.entityId)
    }
  }

  Component {
    id: pressButton
    Kit.Button {
      text: rowItem.rowType === "button" ? String(rowItem.row.actionName || "Run")
        : rowItem.domain === "scene" ? "Activate"
        : rowItem.domain === "script" ? (rowItem.st && rowItem.st.state === "on" ? "Stop" : "Run")
        : "Press"
      enabled: !rowItem.unavailable
      bordered: true
      active: rowItem.busy
      foreground: rowItem.foreground
      fontFamily: rowItem.fontFamily
      fontSize: Style.font.bodySmall
      verticalPadding: Style.spacing.xs
      onClicked: {
        if (!rowItem.host) return
        if (rowItem.rowType === "button") rowItem.host.act(rowItem.row.tapAction, rowItem.entityId, rowItem.entityId !== "" ? "toggle" : "none")
        else rowItem.service.toggle(rowItem.entityId)
      }
    }
  }

  Component {
    id: lockControl
    Kit.Button {
      text: rowItem.st && rowItem.st.state === "locked" ? "Unlock" : "Lock"
      enabled: !rowItem.unavailable
      bordered: true
      active: rowItem.busy
      foreground: rowItem.foreground
      fontFamily: rowItem.fontFamily
      fontSize: Style.font.bodySmall
      verticalPadding: Style.spacing.xs
      onClicked: rowItem.service.toggle(rowItem.entityId)
    }
  }

  Component {
    id: coverControl
    Row {
      spacing: Style.spacing.xs
      PanelActionButton {
        visible: Model.hasFeature(rowItem.st, Model.COVER.OPEN)
        enabled: !rowItem.unavailable && rowItem.st.state !== "open"
        iconText: Model.glyph("mdi:arrow-up")
        tooltipText: "Open"
        foreground: rowItem.foreground
        fontFamily: rowItem.fontFamily
        onClicked: rowItem.callDomain("open_cover")
      }
      PanelActionButton {
        visible: Model.hasFeature(rowItem.st, Model.COVER.STOP)
        enabled: !rowItem.unavailable
        iconText: Model.glyph("mdi:stop")
        tooltipText: "Stop"
        foreground: rowItem.foreground
        fontFamily: rowItem.fontFamily
        onClicked: rowItem.callDomain("stop_cover")
      }
      PanelActionButton {
        visible: Model.hasFeature(rowItem.st, Model.COVER.CLOSE)
        enabled: !rowItem.unavailable && rowItem.st.state !== "closed"
        iconText: Model.glyph("mdi:arrow-down")
        tooltipText: "Close"
        foreground: rowItem.foreground
        fontFamily: rowItem.fontFamily
        onClicked: rowItem.callDomain("close_cover")
      }
    }
  }

  Component {
    id: valveControl
    Row {
      spacing: Style.spacing.xs
      PanelActionButton {
        iconText: Model.glyph("mdi:valve-open")
        tooltipText: "Open"
        enabled: !rowItem.unavailable && rowItem.st.state !== "open"
        foreground: rowItem.foreground
        fontFamily: rowItem.fontFamily
        onClicked: rowItem.callDomain("open_valve")
      }
      PanelActionButton {
        iconText: Model.glyph("mdi:valve-closed")
        tooltipText: "Close"
        enabled: !rowItem.unavailable && rowItem.st.state !== "closed"
        foreground: rowItem.foreground
        fontFamily: rowItem.fontFamily
        onClicked: rowItem.callDomain("close_valve")
      }
    }
  }

  Component {
    id: selectControl
    Dropdown {
      width: Math.min(Style.space(170), rowItem.width * 0.45)
      showLabel: false
      value: rowItem.st ? String(rowItem.st.state) : ""
      options: Model.optionsOf(rowItem.st, "options")
      enabled: !rowItem.unavailable
      foreground: rowItem.foreground
      accent: rowItem.host ? rowItem.host.accent : Color.accent
      fontFamily: rowItem.fontFamily
      onChanged: function(value) { rowItem.callDomain("select_option", { option: value }) }
    }
  }

  Component {
    id: numberControl
    Row {
      spacing: Style.spacing.md
      readonly property var range: Model.numberRange(rowItem.st)
      PanelSlider {
        id: numberSlider
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(Style.space(130), rowItem.width * 0.32)
        bar: rowItem.host ? rowItem.host.bar : null
        minimum: parent.range.min
        maximum: parent.range.max
        step: parent.range.step
        value: rowItem.st ? Number(rowItem.st.state) || 0 : 0
        enabled: !rowItem.unavailable
        onReleased: function(value) {
          var step = parent.range.step || 1
          var snapped = Math.round(value / step) * step
          rowItem.callDomain("set_value", { value: Math.round(snapped * 1000) / 1000 })
        }
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: Model.unitJoin(Model.formatNumber(numberSlider.dragging ? numberSlider.liveValue : numberSlider.value,
          parent.range.step < 1 ? 1 : 0), parent.range.unit)
        font.family: rowItem.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: rowItem.dim
      }
    }
  }

  Component {
    id: textControl
    Kit.TextField {
      width: Math.min(Style.space(170), rowItem.width * 0.45)
      text: rowItem.st ? String(rowItem.st.state) : ""
      foreground: rowItem.foreground
      accent: rowItem.host ? rowItem.host.accent : Color.accent
      font.family: rowItem.fontFamily
      font.pixelSize: Style.font.bodySmall
      verticalPadding: Style.spacing.xs
      password: rowItem.st && rowItem.st.attributes && rowItem.st.attributes.mode === "password"
      onActiveFocusChanged: if (rowItem.host) rowItem.host.noteEditing(activeFocus)
      onEditingFinished: {
        if (rowItem.st && text !== String(rowItem.st.state)) rowItem.callDomain("set_value", { value: text })
      }
    }
  }

  Component {
    id: mediaControl
    Row {
      spacing: Style.spacing.xs
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: Model.stateText(rowItem.st, null)
        width: Math.min(implicitWidth, rowItem.width * 0.3)
        elide: Text.ElideRight
        font.family: rowItem.fontFamily
        font.pixelSize: Style.font.caption
        color: rowItem.dim
      }
      PanelActionButton {
        visible: rowItem.st && rowItem.st.state !== "off" && rowItem.st.state !== "standby"
          && (Model.hasFeature(rowItem.st, Model.MEDIA.PAUSE) || Model.hasFeature(rowItem.st, Model.MEDIA.PLAY))
        iconText: Model.glyph(rowItem.st && rowItem.st.state === "playing" ? "mdi:pause" : "mdi:play")
        tooltipText: rowItem.st && rowItem.st.state === "playing" ? "Pause" : "Play"
        foreground: rowItem.foreground
        fontFamily: rowItem.fontFamily
        onClicked: rowItem.callDomain("media_play_pause")
      }
      PanelActionButton {
        visible: Model.hasFeature(rowItem.st, Model.MEDIA.TURN_ON) || Model.hasFeature(rowItem.st, Model.MEDIA.TURN_OFF)
        iconText: Model.glyph("mdi:power")
        tooltipText: rowItem.st && rowItem.st.state === "off" ? "Turn on" : "Turn off"
        foreground: rowItem.st && rowItem.st.state !== "off" ? rowItem.foreground : rowItem.dim
        fontFamily: rowItem.fontFamily
        onClicked: rowItem.service.toggle(rowItem.entityId)
      }
    }
  }

  Component {
    id: climateControl
    Row {
      spacing: Style.spacing.xs
      readonly property real target: rowItem.st && rowItem.st.attributes.temperature !== undefined && rowItem.st.attributes.temperature !== null
        ? Number(rowItem.st.attributes.temperature) : NaN
      PanelActionButton {
        visible: !isNaN(parent.target)
        iconText: Model.glyph("mdi:minus")
        tooltipText: "Lower"
        foreground: rowItem.foreground
        fontFamily: rowItem.fontFamily
        onClicked: rowItem.callDomain("set_temperature",
          { temperature: Model.clampTemp(parent.target - Model.climateStep(rowItem.st), rowItem.st) })
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: isNaN(parent.target) ? Model.stateText(rowItem.st, null) : parent.target + "°"
        font.family: rowItem.fontFamily
        font.pixelSize: Style.font.body
        color: rowItem.active ? rowItem.foreground : rowItem.dim
      }
      PanelActionButton {
        visible: !isNaN(parent.target)
        iconText: Model.glyph("mdi:plus")
        tooltipText: "Raise"
        foreground: rowItem.foreground
        fontFamily: rowItem.fontFamily
        onClicked: rowItem.callDomain("set_temperature",
          { temperature: Model.clampTemp(parent.target + Model.climateStep(rowItem.st), rowItem.st) })
      }
    }
  }

  Component {
    id: vacuumControl
    Row {
      spacing: Style.spacing.xs
      PanelActionButton {
        iconText: Model.glyph(rowItem.st && rowItem.st.state === "cleaning" ? "mdi:pause" : "mdi:play")
        tooltipText: rowItem.st && rowItem.st.state === "cleaning" ? "Pause" : "Start"
        foreground: rowItem.foreground
        fontFamily: rowItem.fontFamily
        onClicked: rowItem.callDomain(rowItem.st && rowItem.st.state === "cleaning" ? "pause" : "start")
      }
      PanelActionButton {
        iconText: Model.glyph("mdi:home-map-marker")
        tooltipText: "Return to dock"
        foreground: rowItem.foreground
        fontFamily: rowItem.fontFamily
        onClicked: rowItem.callDomain("return_to_base")
      }
    }
  }

  Component {
    id: updateControl
    Kit.Button {
      text: "Install"
      bordered: true
      active: rowItem.busy || (rowItem.st && rowItem.st.attributes.in_progress)
      foreground: rowItem.foreground
      fontFamily: rowItem.fontFamily
      fontSize: Style.font.bodySmall
      verticalPadding: Style.spacing.xs
      onClicked: if (rowItem.host) rowItem.host.confirmThen("Install " + rowItem.displayName + "?",
        function() { rowItem.callDomain("install") })
    }
  }
}
