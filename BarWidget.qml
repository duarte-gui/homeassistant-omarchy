import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar button, and the owner of everything that must outlive the dropdown:
// the Home Assistant connection lives here, not in Panel.qml, so closing the
// panel does not drop it and opening it again shows the house as it is now.
//
// Left click drops the dashboard down, right click opens the settings, middle
// click opens Home Assistant itself in the browser. Beside the house, the
// entities pinned to the bar show their icon while they are on — an armed
// alarm, an open door — and a dot on the house means Home Assistant has
// notifications waiting.
BarWidget {
  id: root
  moduleName: "io.github.duarte-gui.ha-overview"

  // ---- Shape contract for shell.summon/hide/toggle routing: Bar.findPanelWidget
  //      requires open/close/opened on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  // The bar instantiates one of these per monitor. Only the instance on the
  // first screen keeps a connection open while its panel is closed, so a
  // second display does not mean a second idle websocket.
  readonly property var hostWindow: root.QsWindow ? root.QsWindow.window : null
  readonly property bool isLeader: !hostWindow || !hostWindow.screen
    || Quickshell.screens.length === 0
    || String(hostWindow.screen.name) === String(Quickshell.screens[0].name)

  // Ui/BarWidget has no barForeground of its own — that lives on the bar.
  readonly property color barForeground: bar ? bar.barForeground : Color.foreground
  // Bound to stateRevision through the extra argument, so it follows every change.
  readonly property var indicators: service.online
    ? Model.barIndicators(service.barEntities, service.stateStore, service.entityInfo, service.stateRevision) : []
  readonly property bool alarming: indicators.some(function(i) { return i.alarming })

  readonly property color iconColor: {
    if (!service.configured) return Qt.darker(barForeground, 1.55)
    if (root.alarming) return bar ? bar.urgent : Color.urgent
    if (service.connectionState === "auth_invalid" || service.connectionState === "error")
      return bar ? bar.urgent : Color.urgent
    if (!service.everConnected) return Qt.darker(barForeground, 1.55)
    if (!service.online) return bar ? bar.urgent : Color.urgent
    return barForeground
  }

  readonly property string statusText: service.statusLine
  readonly property string tooltipText: {
    var lines = ["HA Overview · " + statusText]
    var count = service.notificationList.length
    if (count > 0) lines.push(count + (count === 1 ? " notification" : " notifications") + " in Home Assistant")
    for (var i = 0; i < indicators.length; i++) lines.push(indicators[i].label)
    return lines.join("\n")
  }

  Service {
    id: service
    settings: root.settings
    panelOpen: root.opened
    leader: root.isLeader
  }

  // --------------------------------------------------------------- actions

  // Persist one inline setting back to shell.json, the same way omarchy.clock
  // stores a cycled format: apply locally first so the UI reacts on the click,
  // then let the bar write the entry.
  function setSetting(key, value) {
    var changes = ({})
    changes[key] = value
    setSettings(changes)
  }

  // Several keys in one write. A null removes the key, which hands it back to
  // its fallback in Service.qml.
  function setSettings(changes) {
    var entry = { id: root.moduleName }
    for (var name in root.settings) {
      if (name !== "id") entry[name] = root.settings[name]
    }
    for (var key in changes) {
      if (changes[key] === null) delete entry[key]
      else entry[key] = changes[key]
    }

    root.settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // The dashboard and view the panel is on, in Home Assistant's own URL
  // scheme, so "open in the browser" lands on the same page.
  function openHomeAssistant() {
    var url = service.haUrl
    if (url === "") return
    var item = panelLoader.item
    if (item && item.currentDashboard) {
      url += "/" + item.currentDashboard
      if (item.currentView) url += "/" + item.currentView.path
    }
    // In-process (the desktop portal, or xdg-open): no shell line naming the view.
    Qt.openUrlExternally(url)
  }

  function openSetup() {
    if (panelLoader.item) panelLoader.item.openSetup()
  }

  // Add an entity to a list setting, or take it out.
  function toggleListSetting(key, entityId) {
    var current = key === "barEntities" ? service.barEntities : service.notifyEntities
    var next = Model.toggledInList(current, entityId)
    setSetting(key, next.length > 0 ? next : null)
  }

  function refresh() {
    service.refresh()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = service
  }

  implicitWidth: strip.implicitWidth
  implicitHeight: strip.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // A short target so a Hyprland keybinding reads as `omarchy-shell hass toggle`.
  IpcHandler {
    target: "hass"
    // The bar builds one widget per monitor, and they would all register this
    // target. Only the leader answers.
    enabled: root.isLeader

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): string { root.refresh(); return "ok" }
    function setup(): string { root.openSetup(); return "ok" }
    function browser(): string { root.openHomeAssistant(); return "ok" }
    function status(): string { return "HA Overview · " + root.statusText }

    // Jump straight to a dashboard or a view, by url_path or by title.
    function dashboard(name: string): string {
      return panelLoader.item ? panelLoader.item.showDashboard(name, "") : "no panel"
    }
    function view(name: string): string {
      return panelLoader.item ? panelLoader.item.showView(name) : "no panel"
    }
    function dashboards(): string {
      var out = []
      for (var i = 0; i < service.dashboardOptions.length; i++) {
        var option = service.dashboardOptions[i]
        var shown = service.dashboards.some(function(d) { return d.value === option.value })
        out.push(option.value + " (" + option.label + ")" + (shown ? "" : " [hidden]"))
      }
      return out.length > 0 ? out.join(", ") : "none yet: " + root.statusText
    }

    // Drive the house from a keybinding: `omarchy-shell hass toggleEntity light.desk`.
    function toggleEntity(entity: string): string {
      var id = Model.resolveEntity(entity, service.stateStore)
      if (id === "") return "unknown entity: " + entity
      return service.toggle(id) >= 0 ? "ok" : "not connected"
    }
    // `omarchy-shell hass call scene.turn_on scene.movie`. The entity may be
    // empty for services that take none.
    function call(action: string, entity: string): string {
      var text = String(action || "")
      var dot = text.indexOf(".")
      if (dot <= 0) return "expected domain.service, got: " + text
      var target = null
      if (String(entity || "") !== "") {
        var id = Model.resolveEntity(entity, service.stateStore)
        if (id === "") return "unknown entity: " + entity
        target = { entity_id: id }
      }
      return service.callService(text.slice(0, dot), text.slice(dot + 1), {}, target) >= 0 ? "ok" : "not connected"
    }
    function state(entity: string): string {
      var id = Model.resolveEntity(entity, service.stateStore)
      if (id === "") return "unknown entity: " + entity
      var state = service.stateOf(id, service.stateRevision)
      return id + " = " + Model.stateText(state, service.infoOf(id))
    }
    // Show one entity's full controls, the way tapping it in the panel does.
    function moreInfo(entity: string): string {
      var id = Model.resolveEntity(entity, service.stateStore)
      if (id === "") return "unknown entity: " + entity
      if (!panelLoader.item) return "no panel"
      panelLoader.item.moreInfo(id)
      if (!root.opened) root.open()
      return "ok"
    }

    // The entity the last change notification was about. Notifications click
    // through to this rather than naming the entity in their own argv.
    function last(): string {
      if (service.lastToastEntity === "") return "nothing yet"
      return moreInfo(service.lastToastEntity)
    }

    // Home Assistant's notifications: shows them, and says how many.
    function notifications(): string {
      if (panelLoader.item) panelLoader.item.showNotifications()
      return String(service.notificationList.length)
    }

    // Pin an entity beside the bar icon, or unpin it.
    function pin(entity: string): string {
      var id = Model.resolveEntity(entity, service.stateStore)
      if (id === "") return "unknown entity: " + entity
      root.toggleListSetting("barEntities", id)
      return service.barEntities.indexOf(id) >= 0 ? "pinned " + id : "unpinned " + id
    }

    // Be notified whenever an entity changes, or stop.
    function watch(entity: string): string {
      var id = Model.resolveEntity(entity, service.stateStore)
      if (id === "") return "unknown entity: " + entity
      root.toggleListSetting("notifyEntities", id)
      return service.notifyEntities.indexOf(id) >= 0 ? "watching " + id : "stopped watching " + id
    }

    // Talk to Assist: `omarchy-shell hass assist "turn off the lights"`. The
    // answer comes as a notification, since this call cannot wait for it.
    // With no text it opens the Assist page.
    function assist(text: string): string {
      if (String(text || "").trim() === "") return chat()
      service.assist(text, function(reply) {
        if (!root.opened) service.toast({ summary: "Assist", body: reply.speech, glyph: "󰍩",
          exec: ["omarchy-shell", "-q", "hass", "chat"] })
      })
      return "sent"
    }

    // The Assist page, to keep talking.
    function chat(): string {
      if (panelLoader.item) panelLoader.item.showAssist()
      return "ok"
    }
  }

  Grid {
    id: strip
    columns: root.vertical ? 1 : 1 + root.indicators.length
    spacing: 0

    BarIconButton {
      id: button
      bar: root.bar
      text: "󰟐"
      foreground: root.iconColor
      active: root.opened
      tooltipText: root.tooltipText

      onPressed: function(buttonCode) {
        if (buttonCode === Qt.RightButton) root.openSetup()
        else if (buttonCode === Qt.MiddleButton) root.openHomeAssistant()
        else root.togglePanel()
      }

      // Home Assistant has notifications waiting.
      Rectangle {
        visible: service.notificationList.length > 0
        width: Style.space(6)
        height: width
        radius: width / 2
        x: parent.width / 2 + Style.space(5)
        y: parent.height / 2 - Style.space(9)
        color: Color.accent
      }
    }

    Repeater {
      model: root.indicators
      BarIconButton {
        required property var modelData
        bar: root.bar
        text: modelData.glyph
        foreground: modelData.alarming ? (root.bar ? root.bar.urgent : Color.urgent) : root.barForeground
        tooltipText: modelData.label
        onPressed: function(buttonCode) {
          if (buttonCode === Qt.MiddleButton) service.toggle(modelData.entity)
          else if (panelLoader.item) {
            panelLoader.item.moreInfo(modelData.entity)
            if (!root.opened) root.open()
          }
        }
      }
    }
  }
}
