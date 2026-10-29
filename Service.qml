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
  // The token is not a setting any more: bridge.py keeps it in a private file
  // (see the top of bridge.py). A token still in shell.json, from an older
  // version or a hand edit, is handed to the bridge once and then removed.
  readonly property string legacyToken: String(setting("token", "")).trim()
  // A token typed in the panel, held only until the bridge confirms it saved it.
  property string pendingToken: ""
  // What the bridge last said: -1 not asked yet, 0 no token saved, 1 saved.
  property int tokenStatus: -1
  readonly property bool hasToken: tokenStatus !== 0 || pendingToken !== "" || legacyToken !== ""
  signal tokenMigrated()
  // Absent or empty means every dashboard goes in the dropdown.
  readonly property var dashboardPicks: Model.splitList(setting("dashboards", ""))
  readonly property string dashboardSetting: String(setting("dashboard", ""))
  readonly property string viewSetting: String(setting("view", ""))
  readonly property int columns: Math.max(1, Math.min(3, setting("columns", 2)))
  readonly property int panelWidth: setting("panelWidth", 760)
  readonly property int panelHeight: setting("panelHeight", 860)
  readonly property int cameraRefreshSec: setting("cameraRefreshSec", 10)
  readonly property bool notifyErrors: setting("notifyErrors", true)
  // Entities whose icon shows beside the bar icon while they are on. Empty
  // means the alarm panels.
  readonly property var barEntities: Model.splitList(setting("barEntities", []))
  // Entities that send a desktop notification whenever their state changes.
  readonly property var notifyEntities: Model.splitList(setting("notifyEntities", []))
  // An alarm going off always notifies, unless this is turned off.
  readonly property bool notifyAlarms: setting("notifyAlarms", true)
  // Home Assistant's own notifications (the bell in its sidebar) as toasts.
  readonly property bool notifyHa: setting("notifyHa", true)
  // Map cards draw on OpenStreetMap tiles from Home Assistant's own tile
  // proxy. Off, a map is a list of who is where.
  readonly property bool mapTiles: setting("mapTiles", true)
  readonly property string mapTheme: ["auto", "dark", "light"].indexOf(String(setting("mapTheme", "auto"))) >= 0
    ? String(setting("mapTheme", "auto")) : "auto"
  // The Assist pipeline id; empty is Home Assistant's preferred one.
  readonly property string assistPipeline: String(setting("assistPipeline", ""))

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

  // Home Assistant's persistent notifications: notification_id -> notification.
  property var notifications: ({})
  readonly property var notificationList: Model.notificationList(notifications)
  // The entity the last change toast was about, for `hass last`.
  property string lastToastEntity: ""

  // Assist: the conversation so far, kept here so it survives the panel
  // closing and is shared with `omarchy-shell hass assist`.
  property var assistLog: []
  property string assistConversation: ""
  property var assistTarget: null
  property bool assistBusy: false
  property var assistPipelines: null

  readonly property bool online: connectionState === "connected"
  readonly property bool configured: haUrl !== "" && hasToken
  // The bridge runs as soon as there is an address: it is the one that knows
  // whether a token is saved.
  readonly property bool shouldRun: haUrl !== "" && (leader || panelOpen)

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
  readonly property string notifyScript:
    decodeURIComponent(String(Qt.resolvedUrl("notify.py")).replace(/^file:\/\//, ""))

  onHaUrlChanged: reconnect()
  onLegacyTokenChanged: if (legacyToken !== "") reconnect()

  function setToken(value) {
    pendingToken = String(value || "").trim()
    if (pendingToken !== "") reconnect()
  }
  onShouldRunChanged: {
    if (shouldRun) startBridge()
    else stopBridge()
  }

  Component.onCompleted: {
    // Held for as long as the widget lives; the bridge re-subscribes on every
    // reconnect.
    subscribe(notificationsKey, { type: "persistent_notification/subscribe" })
    if (shouldRun) startBridge()
  }

  readonly property string notificationsKey: "ha-notifications"

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
    var line = { type: "connect", url: haUrl, dashboards: wanted }
    // Only a new token travels; the bridge reads a saved one from its file.
    var fresh = pendingToken !== "" ? pendingToken : legacyToken
    if (fresh !== "") line.token = fresh
    return JSON.stringify(line) + "\n"
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
    if (notifyErrors && !panelOpen) toast({ body: message, exec: ["omarchy-shell", "-q", "hass", "open"] })
  }

  // ---- notifications

  function dismissNotification(id) {
    return callService("persistent_notification", "dismiss", { notification_id: id }, null)
  }

  function dismissAllNotifications() {
    return callService("persistent_notification", "dismiss_all", {}, null)
  }

  function notificationEvent(event) {
    var folded = Model.applyNotificationEvent(notifications, event)
    notifications = folded.map
    // Only one monitor's widget speaks, or every screen would toast.
    if (!leader || !notifyHa) return
    for (var i = 0; i < folded.added.length; i++) {
      var note = folded.added[i]
      toast({
        summary: String(note.title || "Home Assistant"),
        body: String(note.message || "").replace(/\*\*|__|`/g, ""),
        glyph: "󰂚",
        exec: ["omarchy-shell", "-q", "hass", "notifications"]
      })
    }
  }

  // A watched entity changed, or an alarm went off. The click opens that
  // entity — through `hass last`, so its id stays out of argv.
  function watchChange(entityId, before, after) {
    if (!leader) return
    var watched = notifyEntities.indexOf(entityId) >= 0
    var alarm = notifyAlarms && Model.domainOf(entityId) === "alarm_control_panel"
      && after && after.state === "triggered" && (!before || before.state !== "triggered")
    if (!watched && !alarm) return
    var note = Model.changeNote(entityId, before, after, infoOf(entityId))
    if (!note && alarm) note = { summary: Model.entityName(entityId, after, ""), body: "Triggered", critical: true }
    if (!note) return
    lastToastEntity = entityId
    toast({
      summary: note.summary,
      body: note.body,
      urgency: note.critical || alarm ? "critical" : "normal",
      glyph: Model.entityGlyph(entityId, after, "", infoOf(entityId)),
      exec: ["omarchy-shell", "-q", "hass", "last"]
    })
  }

  // ---- assist

  // One utterance to Home Assistant's conversation agent — the one the
  // preferred Assist pipeline uses, in its language. The reply lands in
  // assistLog; onDone gets it too, for the IPC call.
  function assist(text, onDone) {
    var said = String(text || "").trim()
    if (said === "") return
    if (!online) {
      if (onDone) onDone({ speech: "Not connected to Home Assistant", error: true })
      return
    }
    assistLog = assistLog.concat([{ from: "me", text: said }])
    assistBusy = true

    function process() {
      var message = { type: "conversation/process", text: said }
      if (assistTarget && assistTarget.agent) message.agent_id = assistTarget.agent
      if (assistTarget && assistTarget.language) message.language = assistTarget.language
      if (assistConversation !== "") message.conversation_id = assistConversation
      request(message, function(ok, result, error) {
        assistBusy = false
        var reply = ok ? Model.assistReply(result) : { speech: error || "Assist failed", conversationId: "", error: true }
        if (reply.conversationId) assistConversation = reply.conversationId
        assistLog = assistLog.concat([{ from: "ha", text: reply.speech, error: reply.error }]).slice(-60)
        if (onDone) onDone(reply)
      })
    }

    if (assistTarget !== null) {
      process()
      return
    }
    loadPipelines(function() { process() })
  }

  function loadPipelines(onDone) {
    request({ type: "assist_pipeline/pipeline/list" }, function(ok, result) {
      assistPipelines = ok ? result : null
      // No pipelines (or no assist_pipeline at all) still leaves the default agent.
      assistTarget = (ok ? Model.assistTarget(result, assistPipeline) : null) || { agent: "", language: "", name: "" }
      if (onDone) onDone()
    })
  }

  // A different pipeline speaks another language: start the conversation over.
  onAssistPipelineChanged: {
    assistConversation = ""
    if (assistPipelines) assistTarget = Model.assistTarget(assistPipelines, assistPipeline) || assistTarget
  }

  function clearAssist() {
    assistLog = []
    assistConversation = ""
  }

  // Every toast goes through notify.py, which reads it as one JSON line on
  // stdin and calls Notify over D-Bus itself. omarchy-notification-send would
  // put "Front door: unlock failed" into its own argv and then busctl's, and
  // any local account can read a process's arguments through /proc.
  property var toastQueue: []

  function toast(note) {
    var next = toastQueue.slice()
    next.push({
      app: "HA Overview",
      glyph: note.glyph || "󰟐",
      summary: String(note.summary || "HA Overview"),
      body: String(note.body || ""),
      urgency: note.urgency || "normal",
      exec: note.exec || ["omarchy-shell", "-q", "hass", "open"]
    })
    toastQueue = next
    if (!toastProcess.running) sendNextToast()
  }

  function sendNextToast() {
    if (toastQueue.length === 0) return
    toastProcess.note = toastQueue[0]
    toastQueue = toastQueue.slice(1)
    toastProcess.stdinEnabled = true
    toastProcess.running = true
  }

  Process {
    id: toastProcess
    running: false
    command: ["python3", "-I", service.notifyScript]

    property var note: null

    onStarted: {
      write(JSON.stringify(note) + "\n")
      stdinEnabled = false
    }

    onExited: function(exitCode) {
      // python-gobject missing, or no notification daemon answering. A toast
      // that says nothing is still worth more than none, and it is the only
      // kind that may travel as arguments.
      if (exitCode !== 0) {
        console.warn("ha-overview: notify.py failed (" + exitCode + "), sending a generic toast")
        Quickshell.execDetached([
          "omarchy-notification-send", "--app-name", "HA Overview", "-u", "normal",
          "-g", "󰟐", "HA Overview", "Something needs your attention",
          "--exec", "omarchy-shell", "-q", "hass", "open"
        ])
      }
      note = null
      Qt.callLater(service.sendNextToast)
    }
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
    case "token":
      tokenStatus = message.stored ? 1 : 0
      if (message.saved) {
        pendingToken = ""
        if (legacyToken !== "") tokenMigrated()
      }
      break
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
      if (message.key === notificationsKey) {
        if (message.event) notificationEvent(message.event)
        break
      }
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
      var before = store[id]
      if (before === undefined) setChanged = true
      store[id] = changed[id]
      settled.push(id)
      watchChange(id, before, changed[id])
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
    if (haUrl === "") {
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
    notifications = ({})
    assistTarget = null
    assistPipelines = null
    assistConversation = ""
    stateStore = ({})
    entitySetRevision++
    stateRevision++
    everConnected = false
    imageBase = ""
    if (haUrl === "") {
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

    // A token goes on stdin, never in argv: a process's arguments are
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
