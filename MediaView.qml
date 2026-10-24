import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A media player: artwork, what is playing, transport, volume and source —
// each control only when the player says it supports it.
Column {
  id: media

  property var host: null
  property string entity: ""
  property string name: ""

  readonly property var service: host ? host.service : null
  readonly property var st: service ? service.stateOf(entity, service.stateRevision) : null
  readonly property var attrs: st && st.attributes ? st.attributes : ({})
  readonly property bool off: !st || st.state === "off" || st.state === "standby" || st.state === "unavailable"
  readonly property bool playing: st && st.state === "playing"
  readonly property string artwork: attrs.entity_picture ? String(attrs.entity_picture) : ""

  readonly property color foreground: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property string fontFamily: host ? host.fontFamily : Style.font.family

  spacing: Style.spacing.lg

  function call(name, data) {
    if (host) host.call("media_player", name, data || {}, { entity_id: entity })
  }

  function supports(bit) {
    return Model.hasFeature(st, bit)
  }

  Item {
    width: parent.width
    height: Math.max(art.height, titles.implicitHeight)

    Rectangle {
      id: art
      width: Style.space(56)
      height: width
      radius: Style.cornerRadius
      color: Qt.rgba(media.foreground.r, media.foreground.g, media.foreground.b, 0.08)
      clip: true

      Image {
        id: artImage
        anchors.fill: parent
        visible: status === Image.Ready && !media.off
        source: media.artwork !== "" && media.service ? media.service.pictureUrl(media.artwork) : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        sourceSize.width: 160
      }
      Text {
        anchors.centerIn: parent
        visible: artImage.status !== Image.Ready || media.off
        text: Model.entityGlyph(media.entity, media.st, "", null)
        font.family: media.fontFamily
        font.pixelSize: Style.font.display
        color: media.off ? media.dim : media.foreground
      }
    }

    Column {
      id: titles
      anchors.left: art.right
      anchors.leftMargin: Style.spacing.xl
      anchors.right: powerButton.left
      anchors.rightMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter

      Text {
        width: parent.width
        text: Model.entityName(media.entity, media.st, media.name)
        elide: Text.ElideRight
        font.family: media.fontFamily
        font.pixelSize: Style.font.body
        color: media.foreground
      }
      Text {
        width: parent.width
        text: media.attrs.media_title && !media.off ? String(media.attrs.media_title) : Model.stateText(media.st, null)
        elide: Text.ElideRight
        font.family: media.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: media.dim
      }
      Text {
        width: parent.width
        visible: text !== "" && !media.off
        text: String(media.attrs.media_artist || media.attrs.media_album_name || media.attrs.app_name || "")
        elide: Text.ElideRight
        font.family: media.fontFamily
        font.pixelSize: Style.font.caption
        color: media.dim
      }
    }

    PanelActionButton {
      id: powerButton
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: media.supports(Model.MEDIA.TURN_ON) || media.supports(Model.MEDIA.TURN_OFF)
      iconText: Model.glyph("mdi:power")
      tooltipText: media.off ? "Turn on" : "Turn off"
      foreground: media.off ? media.dim : media.foreground
      fontFamily: media.fontFamily
      onClicked: media.call(media.off ? "turn_on" : "turn_off")
    }
  }

  Row {
    visible: !media.off
    anchors.horizontalCenter: parent.horizontalCenter
    spacing: Style.spacing.lg

    PanelActionButton {
      visible: media.supports(Model.MEDIA.PREVIOUS)
      iconText: Model.glyph("mdi:skip-previous"); tooltipText: "Previous"
      foreground: media.foreground; fontFamily: media.fontFamily
      onClicked: media.call("media_previous_track")
    }
    PanelActionButton {
      visible: media.supports(Model.MEDIA.STOP) && media.playing
      iconText: Model.glyph("mdi:stop"); tooltipText: "Stop"
      foreground: media.foreground; fontFamily: media.fontFamily
      onClicked: media.call("media_stop")
    }
    PanelActionButton {
      visible: media.supports(Model.MEDIA.PAUSE) || media.supports(Model.MEDIA.PLAY)
      iconText: Model.glyph(media.playing ? "mdi:pause" : "mdi:play"); tooltipText: media.playing ? "Pause" : "Play"
      fontSize: Style.font.iconLarge
      foreground: media.foreground; fontFamily: media.fontFamily
      onClicked: media.call("media_play_pause")
    }
    PanelActionButton {
      visible: media.supports(Model.MEDIA.NEXT)
      iconText: Model.glyph("mdi:skip-next"); tooltipText: "Next"
      foreground: media.foreground; fontFamily: media.fontFamily
      onClicked: media.call("media_next_track")
    }
    PanelActionButton {
      visible: media.supports(Model.MEDIA.SHUFFLE)
      iconText: Model.glyph(media.attrs.shuffle ? "mdi:shuffle" : "mdi:shuffle-disabled"); tooltipText: "Shuffle"
      foreground: media.attrs.shuffle ? media.foreground : media.dim; fontFamily: media.fontFamily
      onClicked: media.call("shuffle_set", { shuffle: !media.attrs.shuffle })
    }
  }

  Row {
    visible: !media.off && (media.supports(Model.MEDIA.VOLUME_SET) || media.supports(Model.MEDIA.VOLUME_STEP))
    width: parent.width
    spacing: Style.spacing.md

    PanelActionButton {
      anchors.verticalCenter: parent.verticalCenter
      visible: media.supports(Model.MEDIA.VOLUME_MUTE)
      iconText: Model.glyph(media.attrs.is_volume_muted ? "mdi:volume-off" : "mdi:volume-high")
      tooltipText: media.attrs.is_volume_muted ? "Unmute" : "Mute"
      foreground: media.foreground; fontFamily: media.fontFamily
      onClicked: media.call("volume_mute", { is_volume_muted: !media.attrs.is_volume_muted })
    }
    PanelActionButton {
      anchors.verticalCenter: parent.verticalCenter
      visible: !media.supports(Model.MEDIA.VOLUME_SET) && media.supports(Model.MEDIA.VOLUME_STEP)
      iconText: Model.glyph("mdi:volume-minus"); tooltipText: "Volume down"
      foreground: media.foreground; fontFamily: media.fontFamily
      onClicked: media.call("volume_down")
    }
    PanelSlider {
      anchors.verticalCenter: parent.verticalCenter
      visible: media.supports(Model.MEDIA.VOLUME_SET)
      width: parent.width - Style.space(90)
      bar: media.host ? media.host.bar : null
      minimum: 0; maximum: 100; step: 1; integer: true
      value: media.attrs.volume_level !== undefined ? Math.round(Number(media.attrs.volume_level) * 100) : 0
      onReleased: function(value) { media.call("volume_set", { volume_level: Math.round(value) / 100 }) }
    }
    PanelActionButton {
      anchors.verticalCenter: parent.verticalCenter
      visible: !media.supports(Model.MEDIA.VOLUME_SET) && media.supports(Model.MEDIA.VOLUME_STEP)
      iconText: Model.glyph("mdi:volume-plus"); tooltipText: "Volume up"
      foreground: media.foreground; fontFamily: media.fontFamily
      onClicked: media.call("volume_up")
    }
  }

  Dropdown {
    visible: media.supports(Model.MEDIA.SELECT_SOURCE) && (media.attrs.source_list || []).length > 0
    width: parent.width
    showLabel: false
    value: media.attrs.source ? String(media.attrs.source) : ""
    options: Model.optionsOf(media.st, "source_list")
    foreground: media.foreground
    fontFamily: media.fontFamily
    onChanged: function(value) { media.call("select_source", { source: value }) }
  }
}
