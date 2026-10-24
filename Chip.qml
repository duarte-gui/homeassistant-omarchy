import QtQuick
import qs.Commons
import "Model.js" as Model

// A badge: a pill with an icon and a short state, for view badges and heading
// cards. Tapping it shows the entity.
Rectangle {
  id: chip

  property var spec: null
  property var host: null

  readonly property var service: host ? host.service : null
  readonly property string entityId: spec && spec.entity ? String(spec.entity) : ""
  readonly property var st: service ? service.stateOf(entityId, service.stateRevision) : null
  readonly property bool conditionsOk: !spec || !spec.conditions || spec.conditions.length === 0
    || (service && Model.conditionsMet(spec.conditions, service.stateStore, service.user, service.stateRevision))
  readonly property color foreground: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property string fontFamily: host ? host.fontFamily : Style.font.family
  // A person's badge is about who; everything else is about the value.
  readonly property bool showName: ["person", "device_tracker"].indexOf(Model.domainOf(entityId)) >= 0 || (spec && spec.name)

  visible: conditionsOk && entityId !== ""
  width: visible ? label.implicitWidth + Style.spacing.lg * 2 : 0
  height: Style.spacing.controlHeight
  radius: Style.cornerRadius > 0 ? height / 2 : 0
  color: Qt.rgba(foreground.r, foreground.g, foreground.b, mouse.containsMouse ? 0.12 : 0.06)

  Text {
    id: label
    anchors.centerIn: parent
    text: Model.entityGlyph(chip.entityId, chip.st, chip.spec ? chip.spec.icon : "", null) + "  "
      + (chip.showName ? Model.entityName(chip.entityId, chip.st, chip.spec ? chip.spec.name : "") + " · " : "")
      + Model.stateText(chip.st, chip.service ? chip.service.infoOf(chip.entityId) : null)
    font.family: chip.fontFamily
    font.pixelSize: Style.font.caption
    color: Model.isAlarming(chip.st) ? (chip.host ? chip.host.urgent : Color.urgent)
      : Model.isActive(chip.st) ? chip.foreground : chip.dim
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: if (chip.host) chip.host.act(chip.spec ? chip.spec.tap_action : null, chip.entityId, "more-info")
  }
}
