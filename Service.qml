import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Everything HA Overview knows: the settings as parsed values, the dashboards
// Home Assistant has, the live state of every entity, and the service calls on
// their way out.
//
// Home Assistant is reached through bridge.py, one long-lived process speaking
// its websocket API, rather than QML networking: the dashboards themselves are
// only served over the websocket, qt6-websockets is not part of the shell, and
// the stream of state changes is what keeps every switch in the panel honest
// without polling.
//
// One instance lives on the bar widget, not in the panel, so the connection
// outlives the dropdown being closed and opening it is instant.
Item {
  id: service

  // ---- injected by the bar widget
  property var settings: ({})
  property bool panelOpen: false
  // The bar builds one widget per monitor. Only the leader keeps a connection
  // open all the time; another monitor's widget connects while its panel is up.
  property bool leader: true

  // Settings are read through fallbacks rather than the manifest's `defaults`,
  // because a shell.json entry is stored inline and is never deep-merged with
  // them. The manifest block is documentation; these values are the behaviour,
  // and the two must be edited together.
  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // A bare IP is accepted here too, so a hand-edited "192.168.1.10" in
  // shell.json works the same as one typed into the panel.
  readonly property string haUrl: Model.normalizeHaUrl(setting("haUrl", "http://homeassistant.local:8123"))
  readonly property string token: String(setting("token", "")).trim()
  // Absent or empty means every dashboard goes in the dropdown.
  readonly property var dashboardPicks: Model.splitList(setting("dashboards", ""))
  readonly property string dashboardSetting: String(setting("dashboard", ""))
  readonly property string viewSetting: String(setting("view", ""))
  readonly property int columns: Math.max(1, Math.min(3, setting("columns", 2)))
  readonly property int panelWidth: setting("panelWidth", 760)
  readonly property int panelHeight: setting("panelHeight", 860)
  readonly property int cameraRefreshSec: setting("cameraRefreshSec", 10)
  readonly property bool notifyErrors: setting("notifyErrors", true)

  // ---- live state
  // connecting | connected | auth_invalid | error | no_token | stopped
  property string connectionState: "stopped"
  property string connectionMessage: ""
  property bool everConnected: false
  property string haVersion: ""
  // Where pictures load from — the resolved IP for a plain-http .local name;
  // see peer_url in bridge.py.
  property string imageBase: ""
  property var haConfig: ({})
  property var user: null
  property var panels: []
  property var areas: []
  property var devices: []
  property var entities: []
  property var entityInfo: ({})
  // dashboard -> { config, error, loaded }
  property var lovelace: ({})
  property string lastCallError: ""

  // States are held in a plain object that is updated in place, plus a
  // revision that bindings depend on. A changed entity gets a new object and
  // an unchanged one keeps its reference, so a row bound through stateOf()
  // only re-renders when its own entity moved.
  property var stateStore: ({})
  property int stateRevision: 0
  // Bumped only when the set of entities changes, which is all a generated
  // Overview depends on.
  property int entitySetRevision: 0
  // entity_id -> true while a call that touches it has not been answered by a
  // state change. What the busy spinner on a switch reads.
  property var pending: ({})
  property int pendingRevision: 0

  // key -> the last event a subscription delivered.
  property var subscriptionData: ({})
  property int subscriptionRevision: 0
  property var subscriptionRefs: ({})
  property var subscriptionMessages: ({})

  property var callbacks: ({})
  property int nextId: 1

  readonly property bool online: connectionState === "connected"
  readonly property bool configured: haUrl !== "" && token !== ""
  readonly property bool shouldRun: configured && (leader || panelOpen)

  readonly property var dashboardOptions: Model.dashboardOptions(panels)
  readonly property var dashboards: Model.visibleDashboards(dashboardOptions, dashboardPicks)
  readonly property var staleDashboardPicks: panels.length > 0 ? Model.staleDashboards(dashboardOptions, dashboardPicks) : []

  readonly property string statusLine: {
    if (!configured) return haUrl === "" ? "no address" : Model.describeStatus("no_token", "")
    if (connectionState === "connected") {
      var name = haConfig && haConfig.location_name ? haConfig.location_name : "Home Assistant"
      return name + " · " + Object.keys(stateStore).length + " entities"
    }
    if (connectionState === "stopped") return "idle"
    return Model.describeStatus(connectionState, connectionMessage)
  }

  readonly property string bridgeScript:
    decodeURIComponent(String(Qt.resolvedUrl("bridge.py")).replace(/^file:\/\//, ""))

  onHaUrlChanged: reconnect()
  onTokenChanged: reconnect()
  onShouldRunChanged: {
    if (shouldRun) startBridge()
    else stopBridge()
  }

  Component.onCompleted: if (shouldRun) startBridge()

  // ------------------------------------------------------------- lookups

  function stateOf(entityId, revision) {
    if (!entityId) return null
    var state = stateStore[entityId]
    return state === undefined ? null : state
  }

  function infoOf(entityId) {
    var info = entityInfo[entityId]
    return info === undefined ? null : info
  }

  function isPending(entityId, revision) {
    return pending[entityId] === true
  }

  function dashboardTitle(name) {
    for (var i = 0; i < dashboardOptions.length; i++) {
      if (dashboardOptions[i].value === name) return dashboardOptions[i].label
    }
    return Model.titleCase(name)
  }

  // A dashboard name as a person might type it: the url_path or the title,
  // in any case.
  function resolveDashboard(text) {
    var wanted = String(text || "").trim().toLowerCase()
    if (wanted === "") return ""
    for (var i = 0; i < dashboardOptions.length; i++) {
      if (dashboardOptions[i].value.toLowerCase() === wanted) return dashboardOptions[i].value
    }
    for (i = 0; i < dashboardOptions.length; i++) {
      if (dashboardOptions[i].label.toLowerCase() === wanted) return dashboardOptions[i].value
    }
    return ""
  }

  function lovelaceFor(name) {
    var entry = lovelace[name]
    return entry === undefined ? null : entry
  }

  function pictureUrl(path, tick) {
    return Model.pictureUrl(imageBase !== "" ? imageBase : haUrl, path, tick)
  }

  function viewContext() {
    return { states: stateStore, entities: entities, devices: devices, areas: areas, user: user }
  }

  // ------------------------------------------------------------ outbound

  function send(message) {
    if (!bridge.running) return false
    bridge.write(JSON.stringify(message) + "\n")
    return true
  }

  function connectLine() {
    var wanted = []
    for (var i = 0; i < dashboards.length; i++) wanted.push(dashboards[i].value)
    if (dashboardSetting !== "" && wanted.indexOf(dashboardSetting) < 0) wanted.push(dashboardSetting)
    if (wanted.length === 0) wanted.push("lovelace")
    return JSON.stringify({ type: "connect", url: haUrl, token: token, dashboards: wanted }) + "\n"
  }

  function loadDashboard(name) {
    if (!name) return
    var entry = lovelaceFor(name)
    if (entry && entry.loaded) return
    send({ type: "lovelace", dashboard: name })
  }

  function refresh() {
    lovelace = ({})
    send({ type: "refresh" })
  }

  // The one way anything in the panel changes the house. `entities` is what
  // gets a busy mark until its new state arrives.
  function callService(domain, name, data, target, onDone) {
    if (!online) {
      reportError("Not connected to Home Assistant")
      return -1
    }
    var id = nextId++
    var touched = Model.asList(target && target.entity_id ? target.entity_id : (data && data.entity_id ? data.entity_id : []))
    var marks = Object.assign({}, pending)
    for (var i = 0; i < touched.length; i++) marks[touched[i]] = true
    pending = marks
    pendingRevision++
    pendingClear.restart()

    var done = callbacks
    done[id] = function(ok, error) {
      if (!ok) {
        clearPending(touched)
        reportError(domain + "." + name + ": " + (error || "failed"))
      } else {
        lastCallError = ""
      }
      if (onDone) onDone(ok, error)
    }
    callbacks = done

    send({ type: "call", id: id, domain: domain, service: name, data: data || {}, target: target || null })
    return id
  }

  function toggle(entityId) {
    var call = Model.toggleCall(entityId, stateOf(entityId, stateRevision))
    return callService(call.domain, call.service, call.data, call.target)
  }

  // A raw websocket message whose answer only one caller wants: a camera's
  // stream URL, a to-do list's items.
  function request(message, onDone) {
    var id = nextId++
    var done = callbacks
    done[id] = onDone
    callbacks = done
    if (!send({ type: "request", id: id, message: message })) {
      delete done[id]
      onDone(false, null, "not connected")
    }
  }

  // Reference-counted, because two cards can render the same template and the
  // first one to go away must not end the other's subscription.
  function subscribe(key, message) {
    var refs = subscriptionRefs
    refs[key] = (refs[key] || 0) + 1
    subscriptionRefs = refs
    var messages = subscriptionMessages
    messages[key] = message
    subscriptionMessages = messages
    send({ type: "subscribe", key: key, message: message })
  }

  function unsubscribe(key) {
    var refs = subscriptionRefs
    refs[key] = (refs[key] || 0) - 1
    if (refs[key] > 0) return
    delete refs[key]
    delete subscriptionMessages[key]
    send({ type: "unsubscribe", key: key })
  }

  function subscriptionEvent(key, revision) {
    var event = subscriptionData[key]
    return event === undefined ? null : event
  }

  function clearPending(ids) {
    var marks = Object.assign({}, pending)
    var changed = false
    for (var i = 0; i < ids.length; i++) {
      if (marks[ids[i]]) { delete marks[ids[i]]; changed = true }
    }
    if (!changed) return
    pending = marks
    pendingRevision++
  }

  function reportError(message) {
    lastCallError = message
    console.warn("ha-overview: " + message)
    // An IPC call or a keybinding has nowhere else to say it failed.
    if (notifyErrors && !panelOpen)
      Quickshell.execDetached(["omarchy-notification-send", "--app-name", "HA Overview", "-u", "normal",
        "-g", "󰟐", "HA Overview", message])
  }

  // -------------------------------------------------------------- inbound

  function handleLine(line) {
    var message
    try {
      message = JSON.parse(line)
    } catch (error) {
      return
    }

    switch (message.type) {
    case "status":
      connectionState = message.state
      connectionMessage = String(message.message || "")
      if (message.state === "connected") {
        everConnected = true
        haVersion = connectionMessage
        imageBase = String(message.address || haUrl)
        // Subscriptions made before the bridge was up, or lost with a crash.
        for (var key in subscriptionMessages)
          send({ type: "subscribe", key: key, message: subscriptionMessages[key] })
      }
      break
    case "config":
      haConfig = message.config || ({})
      break
    case "user":
      user = message.user
      break
    case "panels":
      panels = message.panels || []
      break
    case "registry":
      if (message.kind === "areas") areas = message.items || []
      else if (message.kind === "devices") devices = message.items || []
      else if (message.kind === "entities") {
        entities = message.items || []
        var map = ({})
        for (var i = 0; i < entities.length; i++) map[entities[i].entity_id] = entities[i]
        entityInfo = map
      }
      break
    case "states":
      stateStore = message.states || ({})
      pending = ({})
      entitySetRevision++
      stateRevision++
      break
    case "delta":
      applyDelta(message.changed || {}, message.removed || [])
      break
    case "lovelace":
      var next = Object.assign({}, lovelace)
      next[message.dashboard] = {
        config: message.config,
        error: String(message.error || ""),
        message: String(message.message || ""),
        loaded: true
      }
      lovelace = next
      break
    case "result":
    case "response":
      var done = callbacks[message.id]
      if (done) {
        delete callbacks[message.id]
        if (message.type === "result") done(message.success === true, message.error)
        else done(message.success === true, message.result, message.error)
      }
      break
    case "subscription":
      var data = subscriptionData
      data[message.key] = message.error ? { error: message.error } : message.event
      subscriptionData = data
      subscriptionRevision++
      break
    }
  }

  function applyDelta(changed, removed) {
    var store = stateStore
    var setChanged = false
    var settled = []
    for (var id in changed) {
      if (store[id] === undefined) setChanged = true
      store[id] = changed[id]
      settled.push(id)
    }
    for (var i = 0; i < removed.length; i++) {
      if (store[removed[i]] !== undefined) {
        delete store[removed[i]]
        setChanged = true
      }
    }
    if (settled.length > 0) clearPending(settled)
    if (setChanged) entitySetRevision++
    stateRevision++
  }

  // -------------------------------------------------------------- bridge

  function startBridge() {
    if (!configured) {
      connectionState = "no_token"
      return
    }
    if (bridge.running) return
    connectionState = "connecting"
    bridge.running = true
  }

  function stopBridge() {
    restartTimer.stop()
    bridge.running = false
    if (!configured) connectionState = "no_token"
    else connectionState = "stopped"
  }

  // A new address or token goes down the same pipe; the bridge drops its
  // socket and dials again. What the old Home Assistant said is not true of
  // the new one.
  function reconnect() {
    lovelace = ({})
    panels = []
    stateStore = ({})
    entitySetRevision++
    stateRevision++
    everConnected = false
    imageBase = ""
    if (!configured) {
      stopBridge()
      return
    }
    if (bridge.running) {
      connectionState = "connecting"
      bridge.write(connectLine())
    } else if (shouldRun) {
      startBridge()
    }
  }

  Process {
    id: bridge
    running: false
    command: ["python3", "-I", service.bridgeScript]
    stdinEnabled: true

    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { service.handleLine(line) }
    }
    stderr: StdioCollector { id: bridgeErrors; waitForEnd: true }

    // The token goes on stdin, never in argv: a process's arguments are
    // readable by every local account through /proc.
    onStarted: write(service.connectLine())

    onExited: function(exitCode) {
      var errors = String(bridgeErrors.text || "").trim()
      if (errors !== "") console.warn("ha-overview: bridge exited " + exitCode + ": " + errors.split("\n").slice(-3).join(" | "))
      // Whatever was waiting for an answer will not get one.
      service.callbacks = ({})
      service.pending = ({})
      service.pendingRevision++
      if (service.shouldRun) {
        service.connectionState = "error"
        service.connectionMessage = "the bridge stopped; restarting"
        restartTimer.restart()
      }
    }
  }

  Timer {
    id: restartTimer
    interval: 3000
    repeat: false
    onTriggered: if (service.shouldRun) service.startBridge()
  }

  // A call HA accepted but whose entity never reported back — an assumed-state
  // device, a scene — should not spin forever.
  Timer {
    id: pendingClear
    interval: 8000
    repeat: false
    onTriggered: {
      service.pending = ({})
      service.pendingRevision++
    }
  }

  // Keeps "5m ago" honest while the panel sits open, without asking HA.
  property int tick: 0
  Timer {
    interval: 20000
    running: service.panelOpen
    repeat: true
    onTriggered: service.tick++
  }
}
