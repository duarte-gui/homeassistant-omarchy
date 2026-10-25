import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A camera's picture, for picture-entity and picture-glance cards and the
// detail view of a camera.
//
// The picture is HA's camera_proxy snapshot, refreshed on the panel's camera
// tick rather than a decoded stream: a live decode per card inside the shell
// would cost far more than a glance is worth. The entity_picture URL carries
// its own short-lived token, so no header is needed. Two images cross-fade so
// the card never blanks between frames.
//
// The play button turns the card live, in place (LiveVideo); the detail page
// starts live. The pop-out button, or a middle click, sends the stream to mpv
// instead, for a window of its own.
Item {
  id: view

  property var host: null
  // The entity whose picture this is: a camera, an image, or anything with an
  // entity_picture.
  property string entity: ""
  // The entity whose name and state the caption shows; picture-glance and
  // picture-entity can point it elsewhere.
  property string stateEntity: entity
  property string staticImage: ""
  property string name: ""
  property bool showName: true
  property bool showState: true
  property var entities: []
  property var tapAction: null
  property string fit: "cover"
  property bool large: false
  // Playing the live stream in place of the snapshots.
  property bool live: false

  readonly property var service: host ? host.service : null
  readonly property var st: service ? service.stateOf(entity, service.stateRevision) : null
  readonly property var captionState: service ? service.stateOf(stateEntity, service.stateRevision) : null
  readonly property string picturePath: st && st.attributes && st.attributes.entity_picture
    ? String(st.attributes.entity_picture) : staticImage
  readonly property int tick: host ? host.cameraTick : 0
  readonly property bool isCamera: Model.domainOf(entity) === "camera"

  readonly property color foreground: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property string fontFamily: host ? host.fontFamily : Style.font.family

  property int failures: 0
  property bool loadedOnce: false
  property bool frontIsA: true

  implicitHeight: Math.round(width * 9 / 16)
  clip: true

  function requestFrame() {
    if (picturePath === "" || !service) return
    // The stream is the picture while it plays.
    if (liveVideo.playing) return
    // Only cameras move; a still image is fetched once.
    var next = service.pictureUrl(picturePath, isCamera ? tick : null)
    var back = frontIsA ? imageB : imageA
    if (String(back.source) === next || String((frontIsA ? imageA : imageB).source) === next) return
    back.source = next
  }

  onTickChanged: requestFrame()
  onPicturePathChanged: requestFrame()
  onWidthChanged: if (!loadedOnce) requestFrame()
  Component.onCompleted: requestFrame()

  function frameReady(which) {
    failures = 0
    loadedOnce = true
    frontIsA = (which === "a")
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(view.foreground.r, view.foreground.g, view.foreground.b, 0.06)
  }

  Image {
    id: imageA
    anchors.fill: parent
    fillMode: view.fit === "contain" ? Image.PreserveAspectFit : Image.PreserveAspectCrop
    cache: false
    asynchronous: true
    smooth: true
    sourceSize.width: view.large ? 1280 : 640
    opacity: view.frontIsA ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 180 } }
    onStatusChanged: {
      if (status === Image.Ready) view.frameReady("a")
      else if (status === Image.Error && view.failures < 99) view.failures++
    }
  }

  Image {
    id: imageB
    anchors.fill: parent
    fillMode: imageA.fillMode
    cache: false
    asynchronous: true
    smooth: true
    sourceSize.width: imageA.sourceSize.width
    opacity: view.frontIsA ? 0 : 1
    Behavior on opacity { NumberAnimation { duration: 180 } }
    onStatusChanged: {
      if (status === Image.Ready) view.frameReady("b")
      else if (status === Image.Error && view.failures < 99) view.failures++
    }
  }

  LiveVideo {
    id: liveVideo
    anchors.fill: parent
    host: view.host
    entity: view.entity
    active: view.live && view.isCamera && !!view.host && view.host.opened === true
    fit: view.fit
    picturePath: view.picturePath
  }

  Text {
    anchors.centerIn: parent
    visible: !view.loadedOnce && !liveVideo.playing
    text: Model.glyph(view.failures > 2 || Model.isUnavailable(view.st) && view.picturePath === "" ? "mdi:video-off" : "mdi:video")
    font.family: view.fontFamily
    font.pixelSize: Style.font.displayLarge
    color: view.dim
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    onClicked: function(event) {
      if (!view.host) return
      // Middle click is the stream in mpv; a click on the detail view
      // starts or stops it in place.
      if (event.button === Qt.MiddleButton) {
        if (view.isCamera) view.host.streamCamera(view.entity)
        return
      }
      if (view.large && event.button === Qt.LeftButton) {
        if (view.isCamera) view.live = !view.live
        return
      }
      if (event.button === Qt.RightButton) {
        view.host.moreInfo(view.stateEntity !== "" ? view.stateEntity : view.entity)
        return
      }
      view.host.act(view.tapAction, view.stateEntity !== "" ? view.stateEntity : view.entity, "more-info")
    }
  }

  // ---- caption: name, state, and picture-glance's entity buttons
  Rectangle {
    visible: view.showName || view.showState || view.entities.length > 0
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: Math.max(Style.spacing.controlHeight, captionRow.implicitHeight) + Style.spacing.sm * 2
    color: Qt.rgba(0, 0, 0, 0.5)

    Text {
      id: captionName
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      visible: view.showName
      text: Model.entityName(view.stateEntity, view.captionState, view.name)
      font.family: view.fontFamily
      font.pixelSize: Style.font.bodySmall
      color: "white"
      elide: Text.ElideRight
      width: Math.min(implicitWidth, parent.width * 0.5)
    }

    Row {
      id: captionRow
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.sm

      Repeater {
        model: view.entities

        PanelActionButton {
          required property var modelData
          readonly property var itemState: view.service ? view.service.stateOf(modelData.entity, view.service.stateRevision) : null
          iconText: Model.entityGlyph(modelData.entity, itemState, modelData.icon, null)
          tooltipText: Model.entityName(modelData.entity, itemState, modelData.name) + " · " + Model.stateText(itemState, null)
          foreground: Model.isActive(itemState) ? "white" : Qt.rgba(1, 1, 1, 0.55)
          fontFamily: view.fontFamily
          onClicked: if (view.host) view.host.act(modelData.tap_action, modelData.entity,
            Model.defaultTapIsToggle(modelData.entity) ? "toggle" : "more-info")
        }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: view.showState && view.stateEntity !== "" && view.entities.length === 0
        text: Model.stateText(view.captionState, null)
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
        color: Qt.rgba(1, 1, 1, 0.8)
      }

      PanelActionButton {
        visible: view.isCamera
        iconText: Model.glyph(view.live ? "mdi:stop-circle-outline" : "mdi:play-circle-outline")
        tooltipText: view.live ? "Back to snapshots" : "Watch live here"
        foreground: "white"
        fontFamily: view.fontFamily
        onClicked: view.live = !view.live
      }

      PanelActionButton {
        visible: view.isCamera
        iconText: Model.glyph("mdi:open-in-new")
        tooltipText: "Watch in a window (mpv)"
        foreground: "white"
        fontFamily: view.fontFamily
        onClicked: {
          view.live = false
          if (view.host) view.host.streamCamera(view.entity)
        }
      }
    }
  }
}
