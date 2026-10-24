import QtQuick
import qs.Commons
import "Model.js" as Model

// A markdown card. Its content is a Jinja template, and only Home Assistant
// can render one — so a template is sent to HA as a render_template
// subscription, which also re-renders it whenever an entity it reads changes.
// Content with no template syntax is shown as it is, without a round trip.
Text {
  id: markdown

  property var host: null
  property string content: ""

  readonly property var service: host ? host.service : null
  readonly property bool templated: /\{\{|\{%/.test(content)
  readonly property string subscriptionKey: "template:" + Qt.md5(content)
  readonly property var rendered: templated && service ? service.subscriptionEvent(subscriptionKey, service.subscriptionRevision) : null

  property string subscribedKey: ""

  function resubscribe() {
    if (!service) return
    if (subscribedKey !== "") service.unsubscribe(subscribedKey)
    subscribedKey = ""
    if (!templated) return
    subscribedKey = subscriptionKey
    service.subscribe(subscribedKey, { type: "render_template", template: content, strict: false, report_errors: true })
  }

  onServiceChanged: resubscribe()
  onSubscriptionKeyChanged: resubscribe()
  Component.onDestruction: if (service && subscribedKey !== "") service.unsubscribe(subscribedKey)

  text: {
    if (!templated) return Model.cleanMarkdown(content)
    if (!rendered) return "…"
    if (rendered.error) return "Template error: " + rendered.error
    return Model.cleanMarkdown(rendered.result !== undefined ? String(rendered.result) : "")
  }
  textFormat: Text.MarkdownText
  wrapMode: Text.WordWrap
  font.family: host ? host.fontFamily : Style.font.family
  font.pixelSize: Style.font.bodySmall
  color: host ? host.foreground : Color.foreground
  linkColor: host ? host.foreground : Color.foreground
  onLinkActivated: function(link) { if (host) host.openUrl(link) }

  HoverHandler {
    cursorShape: markdown.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
  }
}
