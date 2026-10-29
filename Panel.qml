import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import qs.Ui as Kit
import "Model.js" as Model

// The dropdown behind the bar icon: a Home Assistant dashboard, drawn natively
// card by card, with every control working. A dropdown at the top picks the
// dashboard, tabs pick the view, and tapping an entity opens its full controls
// in place of the cards. State lives on the Service the bar widget owns, so
// closing this panel drops nothing but the camera refresh.
//
// Every card, row and tile reaches the house through the functions here —
// act, call, moreInfo — so this file is the `host` they are all handed.
Panel {
  id: root
  moduleName: "io.github.duarte-gui.ha-overview"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null

  property bool setupMode: false
  property bool notificationsMode: false
  property bool assistMode: false
  property string detailEntity: ""
  property string selectedDashboard: ""
  property string selectedView: ""
  property string addressError: ""
  property string tokenError: ""
  property string flashText: ""
  property int cameraTick: 0
  property int editing: 0

  readonly property var barIdentity: hostWidget || root
  // The cards are showing — not settings, an entity, notifications or Assist.
  readonly property bool onDashboard: !setupMode && detailEntity === "" && !notificationsMode && !assistMode
  readonly property int notificationCount: service ? service.notificationList.length : 0

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------ dashboard

  readonly property var dashboards: service ? service.dashboards : []

  // The one being shown: what was picked, then what was last saved, then the
  // first in the dropdown. A navigate action may land on one the dropdown
  // hides, which is allowed — hiding is about the list, not about access.
  readonly property string currentDashboard: {
    if (!service) return ""
    var known = service.dashboardOptions
    var wanted = selectedDashboard !== "" ? selectedDashboard : service.dashboardSetting
    for (var i = 0; i < known.length; i++) if (known[i].value === wanted) return wanted
    if (dashboards.length > 0) return dashboards[0].value
    return known.length > 0 ? known[0].value : (service.online ? "lovelace" : "")
  }

  readonly property var lovelaceEntry: service && currentDashboard !== "" ? service.lovelaceFor(currentDashboard) : null

  // Views depend on the config, the registries and who is looking — and, for
  // a generated Overview, on which entities exist, never on their states.
  readonly property var views: {
    if (!service || !lovelaceEntry || !lovelaceEntry.loaded) return []
    var revision = service.entitySetRevision
    return Model.viewsFor(lovelaceEntry.config, service.viewContext())
  }
  readonly property var tabs: Model.tabViews(views)
  readonly property int currentViewIndex: {
    var wanted = selectedView !== "" ? selectedView : (service ? service.viewSetting : "")
    var index = Model.findView(views, wanted)
    if (index < 0) index = Model.findView(views, "")
    // A subview reached by navigate is shown; a stale saved one is not.
    return index
  }
  readonly property var currentView: currentViewIndex >= 0 && currentViewIndex < views.length ? views[currentViewIndex] : null
  readonly property var blocks: currentView && service ? Model.blocksForView(currentView, service.viewContext()) : []
  readonly property int columnCount: !currentView ? 1
    : currentView.type === "panel" ? 1
    : Math.max(1, Math.min(service ? service.columns : 2, currentView.maxColumns > 0 ? currentView.maxColumns : 3))
  // Wide blocks (a view's badges, a panel view's one card) span the whole
  // width above the columns; everything else is masonry.
  readonly property var wideBlocks: blocks.filter(function(block) { return block.wide === true })
  readonly property var columnsOfBlocks: Model.distribute(blocks.filter(function(block) { return block.wide !== true }), columnCount)

  onCurrentDashboardChanged: if (service && currentDashboard !== "") service.loadDashboard(currentDashboard)

  Connections {
    target: root.service
    function onOnlineChanged() {
      if (root.service.online && root.currentDashboard !== "") root.service.loadDashboard(root.currentDashboard)
    }
    function onHaUrlChanged() {
      if (!haField.activeFocus) root.resetAddressField()
    }
  }

  function showDashboard(name, view) {
    if (!service) return "no service"
    var resolved = service.resolveDashboard(name)
    if (resolved === "") {
      var known = service.dashboardOptions.map(function(o) { return o.value })
      return "unknown dashboard: " + name + (known.length > 0 ? " (known: " + known.join(", ") + ")" : "")
    }
    leavePages()
    selectedDashboard = resolved
    selectedView = String(view || "")
    service.loadDashboard(resolved)
    persistSelection()
    if (!root.opened) root.open()
    return "ok"
  }

  function showView(name) {
    var index = Model.findView(views, name)
    if (index < 0) return "unknown view: " + name + " (views: " + views.map(function(v) { return v.path }).join(", ") + ")"
    selectView(views[index].path)
    if (!root.opened) root.open()
    return "ok"
  }

  function selectView(path) {
    leavePages()
    selectedView = String(path)
    persistSelection()
    panelFlick.contentY = 0
  }

  function cycleView(delta) {
    if (tabs.length === 0) return
    var at = 0
    for (var i = 0; i < tabs.length; i++) if (currentView && tabs[i].index === currentView.index) at = i
    var next = (at + delta + tabs.length) % tabs.length
    selectView(tabs[next].path)
  }

  function cycleDashboard(delta) {
    if (dashboards.length < 2) return
    var at = 0
    for (var i = 0; i < dashboards.length; i++) if (dashboards[i].value === currentDashboard) at = i
    showDashboard(dashboards[(at + delta + dashboards.length) % dashboards.length].value, "")
  }

  // The selection is saved so the panel reopens where it was left, the way
  // omarchy.clock remembers its cycled format.
  function persistSelection() {
    if (!hostWidget) return
    var changes = { dashboard: currentDashboard, view: currentView ? currentView.path : null }
    if (service && changes.dashboard === service.dashboardSetting && changes.view === service.viewSetting) return
    hostWidget.setSettings(changes)
  }

  // ---------------------------------------------------------- host api

  function act(config, entityId, fallback) {
    var action = Model.resolveAction(config, entityId, fallback)
    if (action.kind === "none") return
    if (action.confirm) {
      confirmThen(action.confirm, function() { root.runAction(action) })
      return
    }
    runAction(action)
  }

  function runAction(action) {
    switch (action.kind) {
    case "toggle":
      if (service) service.toggle(action.entity)
      break
    case "more-info":
      moreInfo(action.entity)
      break
    case "call":
      call(action.domain, action.service, action.data, action.target)
      break
    case "navigate":
      navigate(action.path)
      break
    case "url":
      openUrl(action.url)
      break
    }
  }

  function call(domain, name, data, target) {
    if (service) service.callService(domain, name, data, target)
  }

  function moreInfo(entityId) {
    if (!entityId) return
    leavePages()
    detailEntity = String(entityId)
    panelFlick.contentY = 0
  }

  // Back to the cards from whatever page is up.
  function leavePages() {
    detailEntity = ""
    setupMode = false
    notificationsMode = false
    assistMode = false
  }

  function showNotifications() {
    leavePages()
    notificationsMode = true
    panelFlick.contentY = 0
    if (!root.opened) root.open()
  }

  function showAssist() {
    leavePages()
    assistMode = true
    if (!root.opened) root.open()
    Qt.callLater(function() { if (assistLoader.item) assistLoader.item.focusField() })
  }

  function toggleBarEntity(entityId) {
    if (hostWidget) hostWidget.toggleListSetting("barEntities", entityId)
  }

  function toggleNotifyEntity(entityId) {
    if (hostWidget) hostWidget.toggleListSetting("notifyEntities", entityId)
  }

  function navigate(path) {
    var target = Model.parseNavigation(path, currentDashboard, service ? service.dashboardOptions : [])
    if (target.dashboard !== currentDashboard) showDashboard(target.dashboard, target.view)
    else showView(target.view)
  }

  function openUrl(url) {
    var text = String(url || "")
    if (text === "") return
    // A path inside Home Assistant, as HA's own url actions allow.
    if (text.charAt(0) === "/" && service) text = service.haUrl + text
    Qt.openUrlExternally(text)
  }

  function flash(text) {
    flashText = String(text || "")
    flashTimer.restart()
  }

  function noteEditing(on) {
    editing = Math.max(0, editing + (on ? 1 : -1))
  }

  property var pendingConfirm: null

  function confirmThen(message, fn) {
    pendingConfirm = fn
    confirm.message = String(message || "Are you sure?")
    confirm.selectedIndex = 1
    confirm.opened = true
  }

  // The live stream, in mpv. HA hands out an HLS playlist whose URL is itself
  // the credential, so it goes to mpv on stdin as a one-line playlist rather
  // than in argv, where any local account could read it from /proc.
  function streamCamera(entityId) {
    if (!service) return
    service.request({ type: "camera/stream", entity_id: entityId }, function(ok, result, error) {
      if (!ok || !result || !result.url) {
        root.flash("No stream: " + (error || "this camera has none"))
        return
      }
      streamProcess.running = false
      streamProcess.url = service.pictureUrl(result.url)
      streamProcess.stdinEnabled = true
      streamProcess.running = true
    })
  }

  Process {
    id: streamProcess
    property string url: ""
    // A fixed title: the camera's name would sit in argv, readable by anyone.
    command: ["mpv", "--playlist=-", "--title=HA Overview camera", "--wayland-app-id=ha-overview-camera",
      "--force-window=immediate", "--keepaspect", "--profile=low-latency", "--no-audio"]
    stdinEnabled: true
    onStarted: {
      write(url + "\n")
      url = ""
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      if (exitCode === 127) root.flash("mpv is not installed")
    }
  }

  // --------------------------------------------------------------- setup

  function applyAddress(text) {
    if (!hostWidget || !service) return false
    var url = Model.normalizeHaUrl(text)
    if (url === "") {
      root.addressError = "Not an address. Try an IP such as 192.168.1.10"
      return false
    }
    root.addressError = ""
    if (url === service.haUrl) return true
    // A view saved on the old Home Assistant means nothing on a new one.
    hostWidget.setSettings({ haUrl: url, dashboard: null, view: null, dashboards: null })
    selectedDashboard = ""
    selectedView = ""
    return true
  }

  function applyToken(text) {
    if (!hostWidget) return false
    var token = String(text || "").trim()
    if (token === "") return true
    if (!Model.tokenLooksValid(token)) {
      root.tokenError = "That is not an access token — they look like three dot-separated parts."
      return false
    }
    root.tokenError = ""
    // Straight to the bridge, which saves it privately; never into shell.json.
    service.setToken(token)
    tokenField.text = ""
    return true
  }

  function resetAddressField() {
    root.addressError = ""
    haField.text = service ? Model.haAddressText(service.haUrl) : ""
  }

  // Everything picked means "every dashboard", and is saved as nothing at all,
  // so a dashboard created later shows up without a trip here.
  function applyDashboards(values) {
    if (!hostWidget || !service) return
    if (values.length === 0) return
    var all = service.dashboardOptions.length
    var picked = []
    for (var i = 0; i < service.dashboardOptions.length; i++) {
      var value = service.dashboardOptions[i].value
      if (values.indexOf(value) >= 0) picked.push(value)
    }
    hostWidget.setSetting("dashboards", picked.length === all ? null : picked)
  }

  readonly property var selectedDashboardValues: {
    var out = []
    for (var i = 0; i < dashboards.length; i++) out.push(dashboards[i].value)
    return out
  }

  readonly property string connectionText: {
    if (root.addressError !== "") return root.addressError
    if (!service) return ""
    if (service.online) return "Connected · Home Assistant " + service.haVersion
      + (service.user ? " · signed in as " + service.user.name : "")
    if (!service.configured) return service.haUrl === "" ? "No address yet." : "Paste an access token below to connect."
    return "Not connected: " + service.statusLine
  }

  // ------------------------------------------------------------- lifecycle

  function open() {
    root.resetAddressField()
    if (service && currentDashboard !== "") service.loadDashboard(currentDashboard)
    root.controller.show()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    if (dashboardPicker.popupOpen) dashboardPicker.close()
    if (dashboardDropdown.popupOpen) dashboardDropdown.close()
    if (pipelineDropdown.popupOpen) pipelineDropdown.close()
    confirm.opened = false
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) {
      root.close()
      return
    }
    // Nothing to show until there is somewhere to connect to.
    root.setupMode = !!service && (!service.configured || service.connectionState === "auth_invalid")
    root.open()
  }

  function openSetup() {
    root.leavePages()
    root.setupMode = true
    if (!root.opened) root.open()
  }

  onSetupModeChanged: {
    if (setupMode && service && service.online && !service.assistPipelines) service.loadPipelines(null)
    if (!setupMode && dashboardPicker.popupOpen) dashboardPicker.close()
    if (!setupMode && (haField.activeFocus || tokenField.activeFocus)) keyCatcher.forceActiveFocus()
    root.resetAddressField()
    root.tokenError = ""
    tokenField.text = ""
  }

  function back() {
    if (detailEntity !== "") { detailEntity = ""; return true }
    if (setupMode) { setupMode = false; return true }
    if (notificationsMode) { notificationsMode = false; return true }
    if (assistMode) {
      assistMode = false
      keyCatcher.forceActiveFocus()
      return true
    }
    return false
  }

  function refresh() {
    if (hostWidget) hostWidget.refresh()
    root.cameraTick++
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function openHomeAssistant() {
    if (hostWidget) hostWidget.openHomeAssistant()
  }

  // Camera pictures only refresh while somebody is looking at them.
  Timer {
    interval: Math.max(2, root.service ? root.service.cameraRefreshSec : 10) * 1000
    running: root.opened
    repeat: true
    onTriggered: root.cameraTick++
  }

  Timer {
    id: flashTimer
    interval: 4000
    onTriggered: root.flashText = ""
  }

  // ------------------------------------------------------------------- ui

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(root.service ? root.service.panelWidth : 760))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(root.service ? root.service.panelHeight : 860))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Typing in a field must not switch views on every digit.
      blocked: root.editing > 0 || haField.activeFocus || tokenField.activeFocus

      onMoveRequested: function(dx, dy) {
        if (confirm.opened) return
        if (dx !== 0 && root.onDashboard) root.cycleView(dx)
        if (dy !== 0) panelFlick.contentY = Math.max(0, Math.min(panelFlick.contentHeight - panelFlick.height,
          panelFlick.contentY + dy * Style.space(80)))
      }
      onActivateRequested: {
        if (confirm.opened) confirm.confirmed()
      }
      onCloseRequested: {
        if (confirm.opened) { confirm.canceled(); return }
        if (!root.back()) root.close()
      }
      onReturnRequested: root.back()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (confirm.opened) return
        if (text === "s" || text === "S") {
          if (root.setupMode) root.setupMode = false
          else root.openSetup()
        }
        else if (text === "a" || text === "A") root.showAssist()
        else if (text === "n" || text === "N") {
          if (root.notificationsMode) root.notificationsMode = false
          else root.showNotifications()
        }
        else if (text === "r" || text === "R") root.refresh()
        else if (text === "o" || text === "O") root.openHomeAssistant()
        else if (text === "d") root.cycleDashboard(1)
        else if (text === "D") root.cycleDashboard(-1)
        else if (text >= "1" && text <= "9") {
          var index = parseInt(text, 10) - 1
          if (index < root.tabs.length) root.selectView(root.tabs[index].path)
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.spacing.xxl

          PanelHero {
            width: parent.width
            title: root.setupMode ? "Settings"
              : root.detailEntity !== "" ? "Details"
              : root.notificationsMode ? "Notifications"
              : root.assistMode ? "Assist"
              : (root.service && root.currentDashboard !== "" ? root.service.dashboardTitle(root.currentDashboard) : "HA Overview")
            meta: root.service ? root.service.statusLine : ""
            detail: root.flashText !== "" ? root.flashText
              : root.service && root.service.lastCallError !== "" ? root.service.lastCallError
              : ""
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                text: root.setupMode ? "󰒓" : root.notificationsMode ? "󰂚" : root.assistMode ? "󰍩" : "󰟐"
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                color: !root.setupMode && root.service && !root.service.online ? root.urgent : root.foreground
              }
            }

            trailingControl: Component {
              Row {
                spacing: Style.spacing.xs

                PanelActionButton {
                  visible: !root.onDashboard
                  iconText: "󰁍"
                  tooltipText: "Back (Esc)"
                  foreground: root.urgent
                  onClicked: root.back()
                }

                PanelActionButton {
                  visible: !root.assistMode
                  iconText: "󰍩"
                  tooltipText: "Assist (a)"
                  foreground: root.foreground
                  onClicked: root.showAssist()
                }

                PanelActionButton {
                  visible: !root.notificationsMode
                  iconText: root.notificationCount > 0 ? "󰂞" : "󰂚"
                  tooltipText: root.notificationCount > 0
                    ? root.notificationCount + (root.notificationCount === 1 ? " notification (n)" : " notifications (n)")
                    : "Notifications (n)"
                  foreground: root.notificationCount > 0 ? root.accent : root.foreground
                  onClicked: root.showNotifications()
                }

                PanelActionButton {
                  visible: !root.setupMode
                  iconText: "󰒓"
                  tooltipText: "Settings (s)"
                  foreground: root.foreground
                  onClicked: root.openSetup()
                }

                PanelActionButton {
                  iconText: "󰑐"
                  tooltipText: "Refresh (r)"
                  foreground: root.foreground
                  onClicked: root.refresh()
                }

                PanelActionButton {
                  iconText: "󰏌"
                  tooltipText: "Open in Home Assistant (o)"
                  foreground: root.foreground
                  onClicked: root.openHomeAssistant()
                }
              }
            }
          }

          // ---- dashboard picker and view tabs
          Column {
            width: parent.width
            spacing: Style.spacing.lg
            visible: root.onDashboard && root.service && root.service.online

            Dropdown {
              id: dashboardDropdown
              width: parent.width
              visible: root.dashboards.length > 1
              showLabel: false
              value: root.currentDashboard
              options: root.dashboards
              foreground: root.foreground
              accent: root.urgent
              fontFamily: root.fontFamily
              onChanged: function(value) { root.showDashboard(value, "") }
            }

            Flow {
              width: parent.width
              spacing: Style.spacing.sm
              visible: root.tabs.length > 1

              Repeater {
                model: root.tabs

                Kit.Button {
                  required property var modelData
                  required property int index
                  text: (modelData.icon !== "" ? Model.glyph(modelData.icon) + "  " : "") + modelData.title
                  tooltipText: index < 9 ? "View " + (index + 1) : ""
                  selected: root.currentView && root.currentView.index === modelData.index
                  bordered: true
                  foreground: root.foreground
                  accent: root.urgent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: root.selectView(modelData.path)
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: root.onDashboard && !!root.service && !root.service.online
            text: !root.service ? ""
              : !root.service.configured ? "Set the Home Assistant address and an access token under the gear (s)."
              : root.service.connectionState === "connecting" ? "Connecting to " + root.service.haUrl + "…"
              : "Cannot reach " + root.service.haUrl + ": " + root.service.statusLine + ". Check it under the gear (s)."
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            color: root.service && root.service.connectionState === "connecting" ? root.dim : root.urgent
          }

          Text {
            width: parent.width
            visible: root.onDashboard && !!root.service && root.service.online
              && (!root.lovelaceEntry || !root.lovelaceEntry.loaded)
            text: "Loading the dashboard…"
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            color: root.dim
          }

          Text {
            width: parent.width
            visible: root.onDashboard && !!root.lovelaceEntry && root.lovelaceEntry.loaded
              && root.lovelaceEntry.error !== "" && root.lovelaceEntry.error !== "config_not_found"
            text: root.lovelaceEntry ? "Home Assistant would not send this dashboard: " + root.lovelaceEntry.message : ""
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            color: root.urgent
          }

          Column {
            width: parent.width
            spacing: Style.spacing.xl
            visible: root.onDashboard && !!root.service && root.service.online
              && root.wideBlocks.length > 0

            Repeater {
              model: root.wideBlocks
              Card {
                required property var modelData
                width: parent.width
                block: modelData
                host: root
              }
            }
          }

          // ---- the cards, as masonry columns
          Row {
            id: masonry
            width: parent.width
            spacing: Style.spacing.xl
            visible: root.onDashboard && !!root.service && root.service.online

            readonly property real columnWidth: (width - spacing * (root.columnCount - 1)) / root.columnCount

            Repeater {
              model: root.columnsOfBlocks

              Column {
                required property var modelData
                width: masonry.columnWidth
                spacing: Style.spacing.xl

                Repeater {
                  model: modelData

                  Card {
                    required property var modelData
                    width: masonry.columnWidth
                    block: modelData
                    host: root
                  }
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: root.onDashboard && !!root.currentView && root.blocks.length === 0
            text: "This view has no cards."
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            color: root.dim
          }

          // ---- Home Assistant's notifications
          Loader {
            width: parent.width
            active: root.notificationsMode
            visible: active
            sourceComponent: Component {
              NotificationsView { host: root }
            }
          }

          // ---- Assist
          Loader {
            id: assistLoader
            width: parent.width
            active: root.assistMode
            visible: active
            sourceComponent: Component {
              AssistView { host: root }
            }
          }

          // ---- more-info
          Loader {
            width: parent.width
            active: root.detailEntity !== "" && !root.setupMode && !root.notificationsMode && !root.assistMode
            visible: active
            sourceComponent: Component {
              EntityDetail {
                host: root
                entityId: root.detailEntity
              }
            }
          }

          // ---- settings: where Home Assistant is, how to sign in, and which
          //      dashboards the dropdown lists
          Column {
            width: parent.width
            spacing: Style.spacing.xxl
            visible: root.setupMode

            Column {
              width: parent.width
              spacing: Style.spacing.sm

              PanelSectionHeader {
                width: parent.width
                text: "Home Assistant address"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Kit.TextField {
                id: haField
                width: parent.width
                placeholderText: "192.168.1.10, homeassistant.local, or a full URL"
                foreground: root.foreground
                accent: root.urgent
                font.family: root.fontFamily
                inputMethodHints: Qt.ImhUrlCharactersOnly | Qt.ImhNoAutoUppercase

                onEditingFinished: {
                  if (root.applyAddress(text) && activeFocus) keyCatcher.forceActiveFocus()
                }

                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) {
                    root.resetAddressField()
                    keyCatcher.forceActiveFocus()
                    event.accepted = true
                  }
                }
              }

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.connectionText
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.addressError !== "" || (root.service && root.service.configured && !root.service.online
                  && root.service.connectionState !== "connecting") ? root.urgent : root.dim
              }

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "A bare IP or hostname gets Home Assistant's port 8123."
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.dim
              }
            }

            PanelSeparator {
              width: parent.width
              foreground: root.foreground
            }

            Column {
              width: parent.width
              spacing: Style.spacing.sm

              PanelSectionHeader {
                width: parent.width
                text: "Access token"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Kit.TextField {
                id: tokenField
                width: parent.width
                password: true
                echoMode: TextInput.Password
                placeholderText: root.service && root.service.tokenStatus === 1
                  ? "Saved. Paste a new one to replace it."
                  : "Paste a long-lived access token"
                foreground: root.foreground
                accent: root.urgent
                font.family: root.fontFamily
                inputMethodHints: Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText | Qt.ImhSensitiveData

                onEditingFinished: {
                  if (root.applyToken(text) && activeFocus) keyCatcher.forceActiveFocus()
                }

                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) {
                    text = ""
                    root.tokenError = ""
                    keyCatcher.forceActiveFocus()
                    event.accepted = true
                  }
                }
              }

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.tokenError !== "" ? root.tokenError
                  : root.service && root.service.connectionState === "auth_invalid"
                  ? "Home Assistant refused the saved token. Paste a new one."
                  : "Create one in Home Assistant under your profile → Security → Long-lived access tokens. "
                    + "It is stored in ~/.config/omarchy/shell.json and only ever sent to Home Assistant."
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.tokenError !== "" || (root.service && root.service.connectionState === "auth_invalid")
                  ? root.urgent : root.dim
              }
            }

            PanelSeparator {
              width: parent.width
              foreground: root.foreground
            }

            Column {
              width: parent.width
              spacing: Style.spacing.sm

              PanelSectionHeader {
                width: parent.width
                text: "Dashboards in the dropdown"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              MultiSelect {
                id: dashboardPicker
                width: parent.width
                label: "Dashboards"
                showLabel: false
                values: root.selectedDashboardValues
                options: root.service ? root.service.dashboardOptions.map(function(option) {
                  return { value: option.value, label: option.label, description: "/" + option.value }
                }) : []
                emptyText: root.service && root.service.online ? "Home Assistant has no dashboards" : "Waiting for Home Assistant…"
                noSelectionText: "Keep at least one dashboard"
                foreground: root.foreground
                accent: root.urgent
                fontFamily: root.fontFamily
                onChanged: function(values) { root.applyDashboards(values) }
              }

              Text {
                width: parent.width
                visible: !!root.service && root.service.staleDashboardPicks.length > 0
                wrapMode: Text.WordWrap
                text: root.service ? "Not on this Home Assistant: " + root.service.staleDashboardPicks.join(", ") : ""
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.urgent
              }

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Every dashboard is listed until you untick one. Navigate actions can still reach the hidden ones."
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.dim
              }
            }

            PanelSeparator {
              width: parent.width
              foreground: root.foreground
            }

            Column {
              width: parent.width
              spacing: Style.spacing.sm

              PanelSectionHeader {
                width: parent.width
                text: "Columns"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              ButtonGroup {
                options: ["1", "2", "3"]
                value: String(root.service ? root.service.columns : 2)
                foreground: root.foreground
                accent: root.urgent
                fontFamily: root.fontFamily
                focusable: false
                onChanged: function(value) { if (root.hostWidget) root.hostWidget.setSetting("columns", parseInt(value, 10)) }
              }

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Panel size, camera refresh and the rest live on this widget's entry in shell.json."
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.dim
              }
            }

            PanelSeparator {
              width: parent.width
              foreground: root.foreground
            }

            // ---- the bar icon and notifications
            Column {
              width: parent.width
              spacing: Style.spacing.sm

              PanelSectionHeader {
                width: parent.width
                text: "Bar and notifications"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Kit.Toggle {
                width: parent.width
                label: "Home Assistant's notifications"
                description: "Toast each new one, as the bell in Home Assistant's sidebar gets it."
                checked: root.service ? root.service.notifyHa : true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: if (root.hostWidget) root.hostWidget.setSetting("notifyHa", !checked)
              }

              Kit.Toggle {
                width: parent.width
                label: "Alarms going off"
                description: "An urgent notification when an alarm panel is triggered."
                checked: root.service ? root.service.notifyAlarms : true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: if (root.hostWidget) root.hostWidget.setSetting("notifyAlarms", !checked)
              }

              Kit.Toggle {
                width: parent.width
                label: "Map tiles"
                description: "Draw map cards on OpenStreetMap, through Home Assistant's own tile proxy (2026.9+). Off, a map is a list of who is where."
                checked: root.service ? root.service.mapTiles : true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: if (root.hostWidget) root.hostWidget.setSetting("mapTiles", !checked)
              }

              Dropdown {
                width: parent.width
                visible: root.service ? root.service.mapTiles : true
                label: "Map colours"
                value: root.service ? root.service.mapTheme : "auto"
                options: [
                  { value: "auto", label: "Follow the theme" },
                  { value: "dark", label: "Dark" },
                  { value: "light", label: "Light" }
                ]
                foreground: root.foreground
                accent: root.urgent
                fontFamily: root.fontFamily
                onChanged: function(value) { if (root.hostWidget) root.hostWidget.setSetting("mapTheme", value === "auto" ? null : value) }
              }

              Item { width: 1; height: Style.spacing.lg }

              PanelSectionHeader {
                width: parent.width
                text: "Assist pipeline"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Dropdown {
                id: pipelineDropdown
                width: parent.width
                showLabel: false
                value: root.service ? root.service.assistPipeline : ""
                options: root.service && root.service.assistPipelines
                  ? Model.pipelineOptions(root.service.assistPipelines)
                  : [{ value: root.service ? root.service.assistPipeline : "", label: "Loading pipelines…" }]
                foreground: root.foreground
                accent: root.urgent
                fontFamily: root.fontFamily
                onChanged: function(value) { if (root.hostWidget) root.hostWidget.setSetting("assistPipeline", value === "" ? null : value) }
              }

              Item { width: 1; height: Style.spacing.lg }

              Repeater {
                model: [
                  { key: "barEntities", title: "Shown in the bar", empty: "Nothing pinned: the bar shows the alarm panels while they are armed." },
                  { key: "notifyEntities", title: "Notifying on changes", empty: "No entity notifies on its changes." }
                ]
                Column {
                  required property var modelData
                  readonly property var ids: root.service ? root.service[modelData.key] : []
                  width: parent.width
                  spacing: Style.spacing.xs

                  Text {
                    width: parent.width
                    text: modelData.title
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    color: root.foreground
                  }

                  Flow {
                    width: parent.width
                    spacing: Style.spacing.sm
                    visible: parent.ids.length > 0
                    Repeater {
                      model: parent.parent.ids
                      Kit.Button {
                        required property var modelData
                        readonly property string listKey: parent.parent.modelData.key
                        text: Model.entityName(modelData, root.service ? root.service.stateOf(modelData, root.service.stateRevision) : null, "")
                        iconText: Model.glyph("mdi:close")
                        tooltipText: "Remove " + modelData
                        bordered: true
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        fontSize: Style.font.caption
                        onClicked: if (root.hostWidget) root.hostWidget.toggleListSetting(listKey, modelData)
                      }
                    }
                  }

                  Text {
                    width: parent.width
                    visible: parent.ids.length === 0
                    wrapMode: Text.WordWrap
                    text: modelData.empty
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.dim
                  }
                }
              }

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Open any entity to pin it to the bar or to be notified when it changes."
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.dim
              }
            }
          }
        }
      }

      ConfirmDialog {
        id: confirm
        anchors.fill: parent
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: {
          opened = false
          root.pendingConfirm = null
        }
        onConfirmed: {
          opened = false
          var fn = root.pendingConfirm
          root.pendingConfirm = null
          if (fn) fn()
        }
      }
    }
  }
}
