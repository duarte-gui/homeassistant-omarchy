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
// click opens Home Assistant itself in the browser.
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
  readonly property color iconColor: {
    if (!service.configured) return Qt.darker(barForeground, 1.55)
    if (service.connectionState === "auth_invalid" || service.connectionState === "error")
      return bar ? bar.urgent : Color.urgent
    if (!service.everConnected) return Qt.darker(barForeground, 1.55)
    if (!service.online) return bar ? bar.urgent : Color.urgent
    return barForeground
  }

  readonly property string statusText: service.statusLine

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
    if (bar) bar.run("xdg-open " + Model.shellQuote(url))
  }

  function openSetup() {
    if (panelLoader.item) panelLoader.item.openSetup()
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

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

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
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰟐"
    foreground: root.iconColor
    active: root.opened
    tooltipText: "HA Overview · " + root.statusText

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.openSetup()
      else if (buttonCode === Qt.MiddleButton) root.openHomeAssistant()
      else root.togglePanel()
    }
  }
}
