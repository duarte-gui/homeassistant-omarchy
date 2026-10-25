import QtQuick
import QtMultimedia
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A camera's live stream, inside the panel. Home Assistant hands out an HLS
// playlist for it (camera/stream), which Qt Multimedia's FFmpeg backend plays
// directly — the same player CamGuard's overlay uses. A camera without HLS
// (Frigate's, for one, which stream over WebRTC) still has HA's MJPEG proxy,
// camera_proxy_stream, which the same player takes. Either URL is the
// credential, and it never leaves this process: no argv, no file.
//
// Playing only while `active`; the panel turns it off when it closes, so a
// stream is never decoded for nobody.
Item {
  id: view

  property var host: null
  property string entity: ""
  property bool active: false
  property string fit: "contain"
  // The camera's entity_picture, whose token also opens its MJPEG stream.
  property string picturePath: ""

  readonly property var service: host ? host.service : null
  readonly property string fontFamily: host ? host.fontFamily : Style.font.family
  readonly property bool playing: player.playbackState === MediaPlayer.PlayingState && player.hasVideo

  property string statusText: ""
  property int attempt: 0

  function start() {
    if (!service || entity === "") return
    statusText = "Starting the stream…"
    service.request({ type: "camera/stream", entity_id: entity }, function(ok, result, error) {
      if (!view || !view.active) return
      var url = ok && result && result.url ? view.service.pictureUrl(result.url) : view.mjpegUrl()
      if (url === "") {
        view.statusText = "No live stream: " + (error || "this camera has none")
        return
      }
      player.source = url
      player.play()
    })
  }

  function mjpegUrl() {
    var path = String(picturePath || "")
    if (path.indexOf("/api/camera_proxy/") < 0 || !service) return ""
    return service.pictureUrl(path.replace("/api/camera_proxy/", "/api/camera_proxy_stream/"))
  }

  function stop() {
    retry.stop()
    player.stop()
    player.source = ""
    statusText = ""
    attempt = 0
  }

  onActiveChanged: active ? start() : stop()
  onEntityChanged: if (active) { stop(); start() }
  Component.onCompleted: if (active) start()
  Component.onDestruction: player.stop()

  VideoOutput {
    id: output
    anchors.fill: parent
    fillMode: view.fit === "cover" ? VideoOutput.PreserveAspectCrop : VideoOutput.PreserveAspectFit
  }

  MediaPlayer {
    id: player
    videoOutput: output
    // Cameras in a panel are watched, not listened to.
    audioOutput: AudioOutput { muted: true }

    onErrorOccurred: function(error, errorString) {
      view.statusText = (errorString !== "" ? errorString : "stream error") + " — retrying"
      // A stream HA has just started can take a few seconds to have segments.
      retry.interval = [1500, 3000, 6000, 10000][Math.min(view.attempt, 3)]
      view.attempt++
      if (view.active) retry.restart()
    }

    onPlaybackStateChanged: {
      if (playbackState === MediaPlayer.PlayingState) {
        view.statusText = ""
        view.attempt = 0
      }
    }
  }

  Timer {
    id: retry
    repeat: false
    onTriggered: if (view.active) view.start()
  }

  Rectangle {
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.margins: Style.spacing.md
    visible: view.playing
    width: liveText.implicitWidth + Style.spacing.md * 2
    height: liveText.implicitHeight + Style.spacing.xs * 2
    radius: Style.cornerRadius
    color: "#d03030"
    Text {
      id: liveText
      anchors.centerIn: parent
      text: "LIVE"
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      color: "white"
    }
  }

  Text {
    anchors.centerIn: parent
    width: parent.width - Style.spacing.xl * 2
    visible: view.active && !view.playing && view.statusText !== ""
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.WordWrap
    text: view.statusText
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    color: "white"
    style: Text.Outline
    styleColor: Qt.rgba(0, 0, 0, 0.6)
  }
}
