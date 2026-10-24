.pragma library
.import "Icons.js" as Icons

// Pure helpers for HA Overview. Nothing here touches QML types or the shell, so
// it can be exercised from plain JS while the widget is being built.
//
// The one idea worth knowing before reading the rest: a Lovelace dashboard is
// turned into a list of *blocks* once, from its config alone, and every block
// reads live state at render time. Nothing here takes `states` except the
// condition checks and the auto-generated Overview, because a block list that
// changed on every state_changed would rebuild every card — and drop any open
// dropdown — several times a second.

// ------------------------------------------------------------------ basics

function trimSlashes(value) {
  return String(value || "").trim().replace(/\/+$/, "")
}

// Accepts a comma-separated string or a real array, because a value typed into
// shell.json by hand and one written back by the settings panel should behave
// the same.
function splitList(value) {
  if (value === undefined || value === null) return []

  var parts = []
  if (typeof value === "string") parts = value.split(",")
  else if (value.length !== undefined && typeof value !== "function") {
    for (var i = 0; i < value.length; i++) parts.push(String(value[i]))
  } else return []

  return parts
    .map(function(part) { return String(part).trim() })
    .filter(function(part) { return part.length > 0 })
}

function titleCase(value) {
  var text = String(value || "").replace(/[_-]+/g, " ").trim()
  if (text === "") return ""
  return text.charAt(0).toUpperCase() + text.slice(1)
}

function shellQuote(value) {
  return "'" + String(value === undefined || value === null ? "" : value).replace(/'/g, "'\\''") + "'"
}

function domainOf(entityId) {
  var text = String(entityId || "")
  var dot = text.indexOf(".")
  return dot > 0 ? text.slice(0, dot) : ""
}

function asList(value) {
  if (value === undefined || value === null) return []
  if (typeof value === "string") return [value]
  if (value.length !== undefined) {
    var out = []
    for (var i = 0; i < value.length; i++) out.push(value[i])
    return out
  }
  return [value]
}

function hasFeature(state, bit) {
  var features = state && state.attributes ? Number(state.attributes.supported_features || 0) : 0
  return (features & bit) !== 0
}

// ----------------------------------------------------------------- address

// Whatever someone types for "where is Home Assistant" -> the base URL, or ""
// when it cannot be one. A bare IP or hostname gets Home Assistant's own port;
// a full URL is kept as given, because anything with a scheme is likely behind
// a reverse proxy on a port of its own.
//
//   "192.168.0.20"            -> "http://192.168.0.20:8123"
//   "homeassistant.local"     -> "http://homeassistant.local:8123"
//   "https://ha.example.org/" -> "https://ha.example.org"
function normalizeHaUrl(value) {
  var text = trimSlashes(value)
  if (text === "") return ""

  var hasScheme = /^[a-z][a-z0-9+.-]*:\/\//i.test(text)
  if (!hasScheme) text = "http://" + text

  var match = text.match(/^(https?):\/\/([^\/\s:?#]+|\[[0-9a-f:.]+\])(:\d{1,5})?(\/[^\s?#]*)?$/i)
  if (!match) return ""

  var port = match[3] || (hasScheme ? "" : ":8123")
  return match[1].toLowerCase() + "://" + match[2] + port + trimSlashes(match[4] || "")
}

// The address field shows what was typed, not the URL it became: an IP with
// Home Assistant's default port reads as just the IP.
function haAddressText(url) {
  var text = trimSlashes(url)
  var match = text.match(/^http:\/\/([^\/]+):8123$/i)
  return match ? match[1] : text
}

function urlHost(url) {
  var match = String(url || "").match(/^[a-z][a-z0-9+.-]*:\/\/([^\/\s:?#]+|\[[0-9a-f:.]+\])/i)
  return match ? match[1] : ""
}

// entity_picture is a path on the server, already signed with a short-lived
// token for camera and media proxies. `tick` only exists to bust Qt's image
// cache when a camera should show a fresh frame.
function pictureUrl(base, path, tick) {
  var text = String(path || "")
  if (text === "") return ""
  var url = /^https?:\/\//i.test(text) ? text : trimSlashes(base) + (text.charAt(0) === "/" ? "" : "/") + text
  if (tick === undefined || tick === null) return url
  return url + (url.indexOf("?") >= 0 ? "&" : "?") + "_t=" + tick
}

// A token that is obviously not one: what pasting the wrong clipboard yields.
function tokenLooksValid(token) {
  var text = String(token || "").trim()
  return /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(text)
}

// The bridge's status in words someone can act on.
function describeStatus(state, message) {
  if (state === "auth_invalid") return "the access token was refused — create a new one in your HA profile"
  if (state === "no_token") return "no access token yet — paste one under the gear"
  if (state === "error") return String(message || "") !== "" ? String(message) : "Home Assistant unreachable"
  if (state === "connecting") return "connecting…"
  return ""
}

// -------------------------------------------------------------- dashboards

// Lovelace panels from get_panels as dropdown options. The default dashboard
// lives at "lovelace" and is the one HA itself calls Overview.
function dashboardOptions(panels) {
  var out = []
  var list = panels || []
  for (var i = 0; i < list.length; i++) {
    var panel = list[i]
    if (!panel || !panel.url_path) continue
    out.push({
      value: String(panel.url_path),
      label: panel.title ? String(panel.title) : (panel.url_path === "lovelace" ? "Overview" : titleCase(panel.url_path)),
      icon: panel.icon ? String(panel.icon) : "mdi:view-dashboard"
    })
  }
  out.sort(function(a, b) {
    if (a.value === "lovelace") return -1
    if (b.value === "lovelace") return 1
    return a.label.localeCompare(b.label)
  })
  return out
}

// What the dropdown offers: every dashboard when nothing was picked, otherwise
// the picked ones in the order HA lists them. A picked dashboard HA no longer
// has is dropped here and reported by staleDashboards.
function visibleDashboards(options, picked) {
  var wanted = splitList(picked)
  if (wanted.length === 0) return options.slice()
  return options.filter(function(option) { return wanted.indexOf(option.value) >= 0 })
}

function staleDashboards(options, picked) {
  var known = (options || []).map(function(option) { return option.value })
  return splitList(picked).filter(function(name) { return known.indexOf(name) < 0 })
}

// ------------------------------------------------------------------ views

// Every view the user may see, numbered as HA numbers them, so a navigate to
// "/lovelace/1" and a click on the second tab land on the same place.
//
// `config` null, or a strategy, means the dashboard is generated: HA's own
// Overview before anybody took control of it. That one is rebuilt here from
// the registries.
function viewsFor(config, ctx) {
  var source = config
  if (!source || source.strategy || !source.views) source = { views: autoViews(ctx, source && source.strategy) }

  var out = []
  var list = source.views || []
  for (var i = 0; i < list.length; i++) {
    var view = list[i] || {}
    if (!viewVisibleTo(view, ctx && ctx.user)) continue
    var cards = view.cards || []
    if (view.strategy) cards = autoViews(ctx, view.strategy)[0].cards
    out.push({
      index: i,
      path: view.path ? String(view.path) : String(i),
      title: view.title ? String(view.title) : (view.path ? titleCase(view.path) : "View " + (i + 1)),
      icon: view.icon ? String(view.icon) : "",
      type: view.type ? String(view.type) : (view.panel ? "panel" : "masonry"),
      subview: view.subview === true,
      cards: cards,
      sections: view.sections || [],
      badges: view.badges || [],
      maxColumns: view.max_columns || 0
    })
  }
  return out
}

// `visible` is either false or a list of { user } entries.
function viewVisibleTo(view, user) {
  if (!view) return false
  if (view.visible === false) return false
  if (!view.visible || view.visible === true) return true
  if (!user || !user.id) return true
  var list = asList(view.visible)
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].user === user.id) return true
  }
  return false
}

// Tabs show the views that are not subviews; a subview is only reachable by a
// navigate action, exactly as in HA.
function tabViews(views) {
  return (views || []).filter(function(view) { return !view.subview })
}

function findView(views, wanted) {
  var list = views || []
  var text = String(wanted === undefined || wanted === null ? "" : wanted)
  if (text === "") return list.length > 0 ? 0 : -1
  for (var i = 0; i < list.length; i++) {
    if (list[i].path === text) return i
  }
  var lower = text.toLowerCase()
  for (i = 0; i < list.length; i++) {
    if (String(list[i].title).toLowerCase() === lower) return i
  }
  if (/^\d+$/.test(text)) {
    for (i = 0; i < list.length; i++) {
      if (list[i].index === parseInt(text, 10)) return i
    }
  }
  return -1
}

// "/lovelace/alarme" -> { dashboard: "lovelace", view: "alarme" }. A path that
// names no dashboard ("alarme", "/alarme" when that is not a dashboard) stays
// on the current one.
function parseNavigation(path, currentDashboard, dashboards) {
  var text = String(path || "").trim().replace(/^#/, "")
  var parts = text.split("?")[0].split("/").filter(function(part) { return part !== "" })
  if (parts.length === 0) return { dashboard: currentDashboard, view: "" }

  var known = (dashboards || []).map(function(d) { return typeof d === "string" ? d : d.value })
  if (text.charAt(0) === "/" && (known.indexOf(parts[0]) >= 0 || parts[0] === "lovelace"))
    return { dashboard: parts[0], view: parts.length > 1 ? parts[1] : "" }
  return { dashboard: currentDashboard, view: parts[parts.length - 1] }
}

// --------------------------------------------------------- auto-generation

// What never belongs on a generated dashboard: plumbing domains, and things HA
// itself shows elsewhere.
var AUTO_HIDDEN = ["ai_task", "assist_satellite", "configurator", "conversation", "event", "geo_location",
  "notify", "persistent_notification", "stt", "tag", "tts", "wake_word", "zone", "image", "todo",
  "device_tracker"]
var AUTO_BADGES = ["person", "sun"]

var DOMAIN_TITLES = {
  alarm_control_panel: "Alarm", automation: "Automations", binary_sensor: "Binary sensors",
  button: "Buttons", calendar: "Calendars", camera: "Cameras", climate: "Climate",
  counter: "Counters", cover: "Covers", fan: "Fans", humidifier: "Humidifiers",
  input_boolean: "Toggles", input_button: "Buttons", input_datetime: "Date and time",
  input_number: "Numbers", input_select: "Selects", input_text: "Text", lawn_mower: "Lawn mowers",
  light: "Lights", lock: "Locks", media_player: "Media players", number: "Numbers",
  remote: "Remotes", scene: "Scenes", script: "Scripts", select: "Selects", sensor: "Sensors",
  siren: "Sirens", switch: "Switches", text: "Text", timer: "Timers", update: "Updates",
  vacuum: "Vacuums", valve: "Valves", water_heater: "Water heaters", weather: "Weather"
}

function domainTitle(domain) {
  return DOMAIN_TITLES[domain] || titleCase(domain)
}

// The cards a domain gets on a generated dashboard, beyond a row in a list.
function autoCardFor(entityId) {
  switch (domainOf(entityId)) {
  case "camera": return { type: "picture-entity", entity: entityId }
  case "climate": return { type: "thermostat", entity: entityId }
  case "media_player": return { type: "media-control", entity: entityId }
  case "alarm_control_panel": return { type: "alarm-panel", entity: entityId }
  case "weather": return { type: "weather-forecast", entity: entityId, show_forecast: true }
  }
  return null
}

// HA's "original-states" Overview: one card per area, then one per domain for
// whatever has no area. ctx = { states, entities, devices, areas }.
function autoViews(ctx, strategy) {
  var states = (ctx && ctx.states) || {}
  var entities = (ctx && ctx.entities) || []
  var devices = (ctx && ctx.devices) || []
  var areas = ((ctx && ctx.areas) || []).slice()

  if (strategy && strategy.type === "map") {
    return [{ title: "Map", path: "map", cards: [{ type: "map" }] }]
  }

  var deviceArea = ({})
  for (var d = 0; d < devices.length; d++) deviceArea[devices[d].id] = devices[d].area_id

  var info = ({})
  for (var e = 0; e < entities.length; e++) info[entities[e].entity_id] = entities[e]

  var byArea = ({})
  var byDomain = ({})
  var badges = []
  var ids = Object.keys(states).sort(function(a, b) {
    return entityName(a, states[a], null).localeCompare(entityName(b, states[b], null))
  })

  for (var i = 0; i < ids.length; i++) {
    var id = ids[i]
    var domain = domainOf(id)
    var meta = info[id] || {}
    if (meta.hidden) continue
    if (meta.entity_category !== undefined && meta.entity_category !== null) continue
    if (AUTO_HIDDEN.indexOf(domain) >= 0) continue
    if (AUTO_BADGES.indexOf(domain) >= 0) { badges.push({ entity: id }); continue }

    var area = meta.area_id || (meta.device_id ? deviceArea[meta.device_id] : null)
    if (area) {
      if (!byArea[area]) byArea[area] = []
      byArea[area].push(id)
    } else {
      if (!byDomain[domain]) byDomain[domain] = []
      byDomain[domain].push(id)
    }
  }

  var cards = []
  areas.sort(function(a, b) { return String(a.name).localeCompare(String(b.name)) })
  for (var a = 0; a < areas.length; a++) {
    var list = byArea[areas[a].area_id]
    if (!list || list.length === 0) continue
    pushAutoCards(cards, String(areas[a].name), areas[a].icon, list)
  }

  var domains = Object.keys(byDomain).sort(function(x, y) { return domainTitle(x).localeCompare(domainTitle(y)) })
  for (var k = 0; k < domains.length; k++) pushAutoCards(cards, domainTitle(domains[k]), "", byDomain[domains[k]])

  return [{ title: "Home", path: "home", cards: cards, badges: badges }]
}

function pushAutoCards(cards, title, icon, ids) {
  var rows = []
  var extra = []
  for (var i = 0; i < ids.length; i++) {
    var card = autoCardFor(ids[i])
    if (card) extra.push(card)
    else rows.push({ entity: ids[i] })
  }
  if (rows.length > 0) cards.push({ type: "entities", title: title, icon: icon || undefined, entities: rows })
  for (var j = 0; j < extra.length; j++) cards.push(extra[j])
}

// ----------------------------------------------------------------- blocks

// Card types that become one cell of a tile grid when they sit in a grid.
var TILE_TYPES = ["tile", "button", "entity", "sensor", "gauge", "light"]

// One view -> the blocks the panel lays out. A sections view is flattened into
// one stack per section, so each section stays together in a column.
function blocksForView(view, ctx) {
  if (!view) return []
  var out = []
  var prefix = "v" + view.index

  if (view.badges && view.badges.length > 0) {
    var chips = []
    for (var b = 0; b < view.badges.length; b++) {
      var badge = view.badges[b]
      var entity = typeof badge === "string" ? badge : (badge && badge.entity)
      if (!entity) continue
      chips.push({
        entity: String(entity),
        name: badge && badge.name ? String(badge.name) : "",
        icon: badge && badge.icon ? String(badge.icon) : "",
        conditions: badge && badge.visibility ? badge.visibility : []
      })
    }
    if (chips.length > 0) out.push({ key: prefix + "-badges", kind: "badges", chips: chips, conditions: [], weight: 0.6, wide: true })
  }

  if (view.type === "sections") {
    var sections = view.sections || []
    for (var s = 0; s < sections.length; s++) {
      var section = sections[s] || {}
      var children = blocksForCards(section.cards || [], prefix + "-s" + s)
      if (children.length === 0) continue
      out.push({
        key: prefix + "-s" + s,
        kind: "stack",
        direction: "vertical",
        title: "",
        children: children,
        conditions: section.visibility || [],
        weight: sumWeight(children),
        framed: false
      })
    }
    return out
  }

  var cards = view.cards || []
  if (view.type === "panel") cards = cards.slice(0, 1)
  var blocks = blocksForCards(cards, prefix)
  for (var i = 0; i < blocks.length; i++) {
    if (view.type === "panel") blocks[i].wide = true
    out.push(blocks[i])
  }
  return out
}

function blocksForCards(cards, prefix) {
  var out = []
  var run = []

  // Consecutive tile-like cards in the same container share one grid, which is
  // how a sections view of tiles reads in HA.
  function flushRun() {
    if (run.length === 0) return
    out.push(tileBlock(run, prefix + "-t" + out.length, run.length > 1 ? 2 : 1))
    run = []
  }

  for (var i = 0; i < (cards || []).length; i++) {
    var card = cards[i]
    if (!card || typeof card !== "object") continue
    if (TILE_TYPES.indexOf(card.type) >= 0) { run.push(card); continue }
    flushRun()
    var block = blockForCard(card, prefix + "-" + i)
    if (block) out.push(block)
  }
  flushRun()
  return out
}

function sumWeight(blocks) {
  var total = 0
  for (var i = 0; i < blocks.length; i++) total += blocks[i].weight || 1
  return total
}

function cardConditions(card) {
  return (card && card.visibility) ? asList(card.visibility) : []
}

function blockForCard(card, key) {
  var type = String(card.type || "")
  var conditions = cardConditions(card)
  var block = null

  switch (type) {
  case "entities":
    block = entitiesBlock(card, key)
    break
  case "glance":
    block = tileBlock((card.entities || []).map(function(item) {
      var row = typeof item === "string" ? { entity: item } : item
      return {
        type: "glance", entity: row.entity, name: row.name, icon: row.icon,
        show_state: card.show_state !== false && row.show_state !== false,
        show_name: card.show_name !== false && row.show_name !== false,
        tap_action: row.tap_action || card.tap_action, hold_action: row.hold_action
      }
    }), key, card.columns || Math.min(5, Math.max(1, (card.entities || []).length)))
    block.title = card.title ? String(card.title) : ""
    break
  case "grid":
    block = gridBlock(card, key)
    break
  case "vertical-stack":
  case "horizontal-stack":
    var kids = blocksForCards(card.cards || [], key)
    block = {
      kind: "stack", direction: type === "horizontal-stack" ? "horizontal" : "vertical",
      title: card.title ? String(card.title) : "", children: kids,
      weight: type === "horizontal-stack" ? maxWeight(kids) : sumWeight(kids)
    }
    break
  case "conditional":
    if (!card.card) return null
    var inner = blockForCard(card.card, key)
    if (!inner) return null
    inner.conditions = asList(card.conditions).concat(inner.conditions || [])
    inner.conditions = inner.conditions.concat(conditions)
    return withKey(inner, key)
  case "picture-entity":
  case "picture-glance":
  case "picture":
    block = {
      kind: "camera",
      entity: card.camera_image || card.entity || "",
      stateEntity: card.entity || "",
      image: card.image || "",
      title: card.title ? String(card.title) : "",
      name: card.name ? String(card.name) : "",
      showName: card.show_name !== false,
      showState: card.show_state !== false,
      entities: (card.entities || []).map(function(item) {
        return typeof item === "string" ? { entity: item } : item
      }),
      tapAction: card.tap_action || null,
      fit: card.fit_mode || "cover",
      weight: 4
    }
    break
  case "alarm-panel":
    block = { kind: "alarm", entity: card.entity || "", name: card.name ? String(card.name) : "",
      states: card.states || ["arm_home", "arm_away"], weight: 5.5 }
    break
  case "weather-forecast":
    block = { kind: "weather", entity: card.entity || "", name: card.name ? String(card.name) : "",
      showForecast: card.show_forecast !== false, showCurrent: card.show_current !== false,
      forecastType: card.forecast_type || "daily", weight: card.show_forecast !== false ? 4 : 2.2 }
    break
  case "markdown":
    block = { kind: "markdown", title: card.title ? String(card.title) : "",
      content: String(card.content || ""), weight: 1 + Math.min(6, String(card.content || "").split("\n").length * 0.35) }
    break
  case "media-control":
    block = { kind: "media", entity: card.entity || "", name: card.name ? String(card.name) : "", weight: 3 }
    break
  case "thermostat":
  case "humidifier":
    block = { kind: "thermostat", entity: card.entity || "", name: card.name ? String(card.name) : "", weight: 3.5 }
    break
  case "heading":
    block = { kind: "heading", title: String(card.heading || card.title || ""),
      icon: card.icon ? String(card.icon) : "", style: card.heading_style || "title",
      chips: (card.badges || []).map(function(item) {
        return typeof item === "string" ? { entity: item } : item
      }).filter(function(item) { return item && item.entity }), weight: 0.6 }
    break
  case "map":
    block = { kind: "map", title: card.title ? String(card.title) : "Map",
      entities: (card.entities || []).map(function(item) { return typeof item === "string" ? item : item.entity }),
      weight: 3 }
    break
  case "history-graph":
  case "statistics-graph":
  case "statistic":
  case "sensor":
  case "plant-status":
  case "logbook":
  case "area":
  case "todo-list":
  case "calendar":
  case "energy-distribution":
  case "iframe":
  default:
    block = fallbackBlock(card, key)
    break
  }

  if (!block) return null
  block.conditions = (block.conditions || []).concat(conditions)
  return withKey(block, key)
}

function withKey(block, key) {
  block.key = key
  if (block.weight === undefined) block.weight = 1
  return block
}

function maxWeight(blocks) {
  var top = 0
  for (var i = 0; i < blocks.length; i++) top = Math.max(top, blocks[i].weight || 1)
  return top
}

// A grid of tiles is a tile grid. A grid that holds anything bigger is a stack,
// so a [list, camera] grid reads as one card, the way the dashboard draws it.
function gridBlock(card, key) {
  var cards = card.cards || []
  var allTiles = cards.length > 0 && cards.every(function(c) { return c && TILE_TYPES.indexOf(c.type) >= 0 })
  var columns = card.columns || 3
  if (allTiles) {
    var tiles = tileBlock(cards, key, columns)
    tiles.title = card.title ? String(card.title) : ""
    return tiles
  }
  var kids = blocksForCards(cards, key)
  var cols = Math.max(1, Math.min(columns, kids.length))
  return {
    kind: "stack",
    direction: cols > 1 ? "grid" : "vertical",
    columns: cols,
    title: card.title ? String(card.title) : "",
    children: kids,
    weight: cols > 1 ? sumWeight(kids) / cols : sumWeight(kids)
  }
}

// A card type with no native rendering still has entities worth controlling:
// everything it mentions becomes a list, so the dashboard loses its looks but
// none of its switches.
function fallbackBlock(card, key) {
  var found = []
  collectEntities(card, found)
  var title = card.title || card.name || titleCase(String(card.type || "").replace(/^custom:/, ""))
  if (found.length === 0) {
    return { kind: "note", title: String(title || "Card"),
      text: "This card (" + String(card.type || "unknown") + ") has no entities to show here.", weight: 1 }
  }
  var block = entitiesBlock({ title: title, entities: found.map(function(id) { return { entity: id } }) }, key)
  block.note = String(card.type || "")
  return block
}

function collectEntities(node, out) {
  if (!node) return
  if (typeof node === "string") {
    if (/^[a-z_]+\.[a-z0-9_]+$/.test(node) && out.indexOf(node) < 0) out.push(node)
    return
  }
  if (typeof node !== "object") return
  if (node.length !== undefined) {
    for (var i = 0; i < node.length; i++) collectEntities(node[i], out)
    return
  }
  for (var key in node) {
    if (key === "entity" || key === "entities" || key === "entity_id" || key === "cards" || key === "card"
        || key === "camera_image" || key === "elements" || key === "badges")
      collectEntities(node[key], out)
  }
}

function entitiesBlock(card, key) {
  var rows = []
  var list = card.entities || []
  for (var i = 0; i < list.length; i++) {
    var row = normalizeRow(list[i], card)
    if (row) rows.push(row)
  }
  return {
    kind: "entities",
    title: card.title ? String(card.title) : "",
    icon: card.icon ? String(card.icon) : "",
    headerToggle: card.show_header_toggle !== false,
    stateColor: card.state_color === true,
    rows: rows,
    weight: 0.8 + rows.length * 0.75
  }
}

// One entities-card row in a single shape. Rows are entity rows unless they
// say otherwise; the special rows are what HA calls "special rows".
function normalizeRow(item, card) {
  if (!item) return null
  if (typeof item === "string") return { type: "entity", entity: item, conditions: [] }

  var type = item.type ? String(item.type) : (item.entity ? "entity" : "")
  var row = {
    type: type,
    entity: item.entity ? String(item.entity) : "",
    name: typeof item.name === "string" ? item.name : "",
    icon: item.icon ? String(item.icon) : "",
    secondary: item.secondary_info ? String(item.secondary_info) : "",
    tapAction: item.tap_action || null,
    format: item.format ? String(item.format) : "",
    conditions: []
  }

  switch (type) {
  case "entity":
  case "simple-entity":
  case "custom:multiple-entity-row":
    row.type = type === "simple-entity" ? "simple" : "entity"
    return row
  case "section":
    row.label = item.label ? String(item.label) : ""
    return row
  case "divider":
    return row
  case "attribute":
    row.attribute = String(item.attribute || "")
    row.prefix = item.prefix ? String(item.prefix) : ""
    row.suffix = item.suffix ? String(item.suffix) : ""
    return row
  case "weblink":
    row.url = String(item.url || "")
    row.name = row.name || row.url
    return row
  case "text":
    row.text = String(item.text || "")
    return row
  case "button":
  case "call-service":
  case "perform-action":
    row.type = "button"
    row.actionName = item.action_name ? String(item.action_name) : "Run"
    if (type !== "button") {
      row.tapAction = {
        action: "perform-action",
        perform_action: item.perform_action || item.action || item.service,
        data: item.data || item.service_data || {},
        target: item.target
      }
    }
    return row
  case "buttons":
    row.items = (item.entities || []).map(function(entry) { return typeof entry === "string" ? { entity: entry } : entry })
    return row
  case "conditional":
    var inner = normalizeRow(item.row, card)
    if (!inner) return null
    inner.conditions = asList(item.conditions)
    return inner
  }

  // An unknown custom row with an entity is still an entity row.
  if (row.entity !== "") { row.type = "entity"; return row }
  return null
}

function tileBlock(cards, key, columns) {
  var tiles = []
  for (var i = 0; i < cards.length; i++) {
    var card = cards[i]
    if (!card) continue
    tiles.push({
      type: String(card.type || "tile"),
      entity: card.entity ? String(card.entity) : "",
      name: typeof card.name === "string" ? card.name : "",
      icon: card.icon ? String(card.icon) : "",
      showState: card.show_state !== false && card.type !== "button" ? true : card.show_state === true,
      showName: card.show_name !== false,
      tapAction: card.tap_action || null,
      iconTapAction: card.icon_tap_action || null,
      unit: card.unit ? String(card.unit) : "",
      min: card.min !== undefined ? Number(card.min) : 0,
      max: card.max !== undefined ? Number(card.max) : 100,
      features: card.features || [],
      conditions: cardConditions(card)
    })
  }
  var cols = Math.max(1, Math.min(columns || 2, tiles.length || 1))
  return {
    key: key,
    kind: "tiles",
    title: "",
    columns: cols,
    tiles: tiles,
    conditions: [],
    weight: Math.ceil(tiles.length / cols) * 1.3
  }
}

// Masonry: each block goes to the shortest column, by estimated weight. Real
// heights are unknown until QML lays them out, and an estimate lands close
// enough that columns rarely end more than a card apart.
function distribute(blocks, columns) {
  var cols = []
  var heights = []
  var count = Math.max(1, columns || 1)
  for (var c = 0; c < count; c++) { cols.push([]); heights.push(0) }

  for (var i = 0; i < (blocks || []).length; i++) {
    var block = blocks[i]
    var shortest = 0
    for (var j = 1; j < count; j++) if (heights[j] < heights[shortest] - 0.01) shortest = j
    cols[shortest].push(block)
    heights[shortest] += block.weight || 1
  }
  return cols
}

// ------------------------------------------------------------- conditions

// HA's card conditions, old and new spelling:
//   { entity, state, state_not }                        (conditional card, legacy)
//   { condition: "state", entity, state, state_not }
//   { condition: "numeric_state", entity, above, below }
//   { condition: "user", users: [...] }
//   { condition: "and" | "or", conditions: [...] }
//   { condition: "screen", media_query }                — always true here
function conditionsMet(conditions, states, user) {
  var list = asList(conditions)
  for (var i = 0; i < list.length; i++) {
    if (!conditionMet(list[i], states, user)) return false
  }
  return true
}

function conditionMet(cond, states, user) {
  if (!cond || typeof cond !== "object") return true
  var kind = cond.condition || "state"

  if (kind === "and") return conditionsMet(cond.conditions, states, user)
  if (kind === "or") {
    var list = asList(cond.conditions)
    for (var i = 0; i < list.length; i++) if (conditionMet(list[i], states, user)) return true
    return list.length === 0
  }
  if (kind === "screen" || kind === "location") return true
  if (kind === "user") {
    if (!user || !user.id) return true
    return asList(cond.users).indexOf(user.id) >= 0
  }

  var entity = cond.entity
  var state = entity && states ? states[entity] : null
  var value = state ? String(state.state) : "unavailable"

  if (kind === "numeric_state") {
    var number = parseFloat(value)
    if (isNaN(number)) return false
    var above = numericOperand(cond.above, states)
    var below = numericOperand(cond.below, states)
    if (above !== null && !(number > above)) return false
    if (below !== null && !(number < below)) return false
    return true
  }

  if (cond.state !== undefined) {
    var wanted = asList(cond.state).map(function(s) { return String(s) })
    if (wanted.indexOf(value) < 0) return false
  }
  if (cond.state_not !== undefined) {
    var unwanted = asList(cond.state_not).map(function(s) { return String(s) })
    if (unwanted.indexOf(value) >= 0) return false
  }
  return true
}

// An operand may be a number or an entity id whose state is one.
function numericOperand(value, states) {
  if (value === undefined || value === null || value === "") return null
  if (typeof value === "number") return value
  var number = parseFloat(value)
  if (!isNaN(number)) return number
  var state = states ? states[value] : null
  var fromEntity = state ? parseFloat(state.state) : NaN
  return isNaN(fromEntity) ? null : fromEntity
}

// ---------------------------------------------------------------- entities

function entityName(entityId, state, override) {
  if (override && typeof override === "string" && override !== "") return override
  if (state && state.attributes && state.attributes.friendly_name) return String(state.attributes.friendly_name)
  var text = String(entityId || "")
  var dot = text.indexOf(".")
  return titleCase(dot >= 0 ? text.slice(dot + 1) : text)
}

function isUnavailable(state) {
  return !state || state.state === "unavailable"
}

var INACTIVE = ["off", "closed", "locked", "idle", "standby", "disarmed", "docked", "not_home", "unavailable",
  "unknown", "paused", "below_horizon", "none", "0", "clear", "jammed", "returning"]

// Whether the entity is in its "on" sense: lit, open, playing, armed. This is
// the tint on its icon and nothing more.
function isActive(state) {
  if (!state) return false
  var domain = domainOf(state.entity_id)
  var value = String(state.state)
  if (domain === "alarm_control_panel") return value !== "disarmed" && value !== "unavailable"
  if (domain === "lock") return value === "unlocked" || value === "open" || value === "opening"
  if (domain === "climate") return value !== "off" && value !== "unavailable"
  if (domain === "sensor" || domain === "weather" || domain === "input_number" || domain === "number"
      || domain === "input_select" || domain === "select" || domain === "input_text" || domain === "text"
      || domain === "counter" || domain === "event")
    return false
  if (domain === "update") return value === "on"
  return INACTIVE.indexOf(value) < 0
}

// The red ones: an alarm going off, a problem sensor, a jammed lock.
function isAlarming(state) {
  if (!state) return false
  var value = String(state.state)
  var domain = domainOf(state.entity_id)
  if (domain === "alarm_control_panel") return value === "triggered" || value === "pending"
  if (domain === "lock") return value === "jammed"
  if (domain === "binary_sensor") {
    var cls = state.attributes ? state.attributes.device_class : ""
    return value === "on" && ["problem", "smoke", "gas", "carbon_monoxide", "safety", "tamper", "moisture"].indexOf(cls) >= 0
  }
  if (domain === "siren") return value === "on"
  return false
}

var TOGGLE_DOMAINS = ["light", "switch", "input_boolean", "fan", "automation", "siren", "humidifier", "remote", "group"]

// Whether a row gets a switch. A group only does when it is a group of things
// that switch, which its state says.
function hasToggle(state) {
  if (!state) return false
  var domain = domainOf(state.entity_id)
  if (TOGGLE_DOMAINS.indexOf(domain) < 0) return false
  if (domain === "group") return state.state === "on" || state.state === "off"
  return true
}

function isOn(state) {
  return !!state && state.state === "on"
}

// What "toggle" means per domain, as a service call. HA's own toggle exists
// for most domains; the rest need the verb spelled out.
function toggleCall(entityId, state) {
  var domain = domainOf(entityId)
  var value = state ? String(state.state) : ""
  var target = { entity_id: entityId }

  switch (domain) {
  case "lock":
    return { domain: "lock", service: value === "locked" ? "unlock" : "lock", data: {}, target: target }
  case "cover":
    return { domain: "cover", service: "toggle", data: {}, target: target }
  case "valve":
    return { domain: "valve", service: "toggle", data: {}, target: target }
  case "scene":
    return { domain: "scene", service: "turn_on", data: {}, target: target }
  case "script":
    return { domain: "script", service: value === "on" ? "turn_off" : "turn_on", data: {}, target: target }
  case "button":
  case "input_button":
    return { domain: domain, service: "press", data: {}, target: target }
  case "media_player":
    return { domain: "media_player", service: value === "off" || value === "standby" ? "turn_on" : "turn_off", data: {}, target: target }
  case "vacuum":
    return { domain: "vacuum", service: value === "cleaning" ? "return_to_base" : "start", data: {}, target: target }
  case "lawn_mower":
    return { domain: "lawn_mower", service: value === "mowing" ? "dock" : "start_mowing", data: {}, target: target }
  case "automation":
  case "fan":
  case "humidifier":
  case "input_boolean":
  case "light":
  case "remote":
  case "siren":
  case "switch":
  case "climate":
  case "water_heater":
    return { domain: domain, service: "toggle", data: {}, target: target }
  }
  return { domain: "homeassistant", service: "toggle", data: {}, target: target }
}

// Whether tapping an entity's card should switch it rather than show it.
function defaultTapIsToggle(entityId) {
  var domain = domainOf(entityId)
  return TOGGLE_DOMAINS.indexOf(domain) >= 0 || ["lock", "cover", "scene", "script", "button", "input_button", "valve"].indexOf(domain) >= 0
}

// An action config -> what to do. `fallback` is the card's default when the
// config says nothing: "toggle" or "more-info".
//
//   { kind: "call", domain, service, data, target, confirm }
//   { kind: "toggle", entity }   { kind: "more-info", entity }
//   { kind: "navigate", path }   { kind: "url", url }   { kind: "none" }
function resolveAction(config, entityId, fallback) {
  var cfg = config || {}
  var kind = cfg.action || fallback || "more-info"
  var entity = cfg.entity ? String(cfg.entity) : String(entityId || "")
  var confirm = cfg.confirmation ? (cfg.confirmation.text || "Are you sure?") : ""

  if (kind === "call-service" || kind === "perform-action") {
    var name = String(cfg.perform_action || cfg.service || "")
    var dot = name.indexOf(".")
    if (dot <= 0) return { kind: "none" }
    var target = cfg.target || null
    var data = cfg.data || cfg.service_data || {}
    return { kind: "call", domain: name.slice(0, dot), service: name.slice(dot + 1),
      data: data, target: target, confirm: confirm }
  }
  if (kind === "toggle") return entity !== "" ? { kind: "toggle", entity: entity, confirm: confirm } : { kind: "none" }
  if (kind === "more-info") return entity !== "" ? { kind: "more-info", entity: entity } : { kind: "none" }
  if (kind === "navigate") return { kind: "navigate", path: String(cfg.navigation_path || "") }
  if (kind === "url") return { kind: "url", url: String(cfg.url_path || "") }
  return { kind: "none" }
}

// ------------------------------------------------------------------ states

var BINARY_TEXT = {
  battery: ["Normal", "Low"], battery_charging: ["Not charging", "Charging"],
  carbon_monoxide: ["Clear", "Detected"], cold: ["Normal", "Cold"], connectivity: ["Disconnected", "Connected"],
  door: ["Closed", "Open"], garage_door: ["Closed", "Open"], gas: ["Clear", "Detected"], heat: ["Normal", "Hot"],
  light: ["No light", "Light detected"], lock: ["Locked", "Unlocked"], moisture: ["Dry", "Wet"],
  motion: ["Clear", "Detected"], moving: ["Not moving", "Moving"], occupancy: ["Clear", "Detected"],
  opening: ["Closed", "Open"], plug: ["Unplugged", "Plugged in"], power: ["Off", "On"],
  presence: ["Away", "Home"], problem: ["OK", "Problem"], running: ["Not running", "Running"],
  safety: ["Safe", "Unsafe"], smoke: ["Clear", "Detected"], sound: ["Clear", "Detected"],
  tamper: ["Clear", "Tampering"], update: ["Up-to-date", "Update available"], vibration: ["Clear", "Detected"],
  window: ["Closed", "Open"]
}

var WEATHER_TEXT = {
  "clear-night": "Clear, night", cloudy: "Cloudy", exceptional: "Exceptional", fog: "Fog", hail: "Hail",
  lightning: "Lightning", "lightning-rainy": "Lightning, rainy", partlycloudy: "Partly cloudy",
  pouring: "Pouring", rainy: "Rainy", snowy: "Snowy", "snowy-rainy": "Snowy, rainy", sunny: "Sunny",
  windy: "Windy", "windy-variant": "Windy, cloudy"
}

var ALARM_TEXT = {
  disarmed: "Disarmed", armed_home: "Armed home", armed_away: "Armed away", armed_night: "Armed night",
  armed_vacation: "Armed vacation", armed_custom_bypass: "Armed custom", pending: "Pending",
  arming: "Arming", disarming: "Disarming", triggered: "Triggered"
}

function formatNumber(value, precision) {
  var number = Number(value)
  if (!isFinite(number)) return String(value)
  if (precision !== undefined && precision !== null && precision >= 0) return number.toFixed(precision)
  // Whatever HA sent, without the float noise of a raw division.
  var text = String(value)
  if (/^-?\d+(\.\d+)?$/.test(text)) return text
  return String(Math.round(number * 1000) / 1000)
}

function unitJoin(value, unit) {
  if (!unit) return value
  return value + (unit === "%" || unit === "°" ? "" : " ") + unit
}

// The state as a person reads it. `info` is the entity's registry entry, for
// its display precision.
function stateText(state, info) {
  if (!state) return "Unavailable"
  var value = String(state.state)
  var attrs = state.attributes || {}
  var domain = domainOf(state.entity_id)

  if (value === "unavailable") return "Unavailable"
  if (value === "unknown") return "Unknown"

  if (domain === "binary_sensor") {
    var pair = BINARY_TEXT[attrs.device_class] || ["Off", "On"]
    return value === "on" ? pair[1] : pair[0]
  }
  if (domain === "weather") return WEATHER_TEXT[value] || titleCase(value)
  if (domain === "alarm_control_panel") return ALARM_TEXT[value] || titleCase(value)
  if (domain === "update") return value === "on" ? "Update available" : "Up-to-date"
  if (domain === "person" || domain === "device_tracker") {
    if (value === "home") return "Home"
    if (value === "not_home") return "Away"
    return value
  }
  if (domain === "sun") return value === "above_horizon" ? "Above horizon" : "Below horizon"
  if (domain === "todo") return value + (value === "1" ? " item" : " items")
  if (domain === "climate") {
    var current = attrs.current_temperature
    return titleCase(value) + (current !== undefined && current !== null ? " · " + current + "°" : "")
  }
  if (domain === "media_player") {
    var title = attrs.media_title ? String(attrs.media_title) : ""
    var artist = attrs.media_artist ? String(attrs.media_artist) : ""
    if (title !== "" && (value === "playing" || value === "paused"))
      return (artist !== "" ? artist + " — " : "") + title
    return titleCase(value)
  }
  if (domain === "cover" && attrs.current_position !== undefined && value === "open")
    return "Open · " + attrs.current_position + "%"
  if (domain === "light" && value === "on" && attrs.brightness)
    return "On · " + Math.round(Number(attrs.brightness) / 2.55) + "%"

  if (attrs.device_class === "timestamp" || domain === "input_datetime" && attrs.has_time && attrs.has_date) {
    var when = Date.parse(value)
    if (!isNaN(when)) return relativeTime(when / 1000, Date.now() / 1000)
  }

  if (/^-?\d+(\.\d+)?(e[-+]?\d+)?$/i.test(value)) {
    var precision = info && info.display_precision !== undefined ? info.display_precision : null
    return unitJoin(formatNumber(value, precision), attrs.unit_of_measurement || "")
  }

  if (attrs.unit_of_measurement) return unitJoin(value, attrs.unit_of_measurement)
  if (domain === "sensor" || domain === "input_text" || domain === "text" || domain === "input_select" || domain === "select")
    return value
  return titleCase(value)
}

function relativeTime(epochSeconds, nowSeconds) {
  var delta = Math.floor(nowSeconds - epochSeconds)
  var future = delta < 0
  delta = Math.abs(delta)
  var text
  if (delta < 10) return "now"
  if (delta < 60) text = delta + "s"
  else if (delta < 3600) text = Math.floor(delta / 60) + "m"
  else if (delta < 86400) text = Math.floor(delta / 3600) + "h"
  else text = Math.floor(delta / 86400) + "d"
  return future ? "in " + text : text + " ago"
}

function lastChangedText(state, nowSeconds) {
  if (!state || !state.last_changed) return ""
  var when = Date.parse(state.last_changed)
  if (isNaN(when)) return ""
  return relativeTime(when / 1000, nowSeconds)
}

// What a row says under its name, by the secondary_info it asked for.
function secondaryText(kind, state, nowSeconds) {
  if (!state || !kind) return ""
  var attrs = state.attributes || {}
  switch (kind) {
  case "last-changed": return lastChangedText(state, nowSeconds)
  case "last-updated":
    var when = Date.parse(state.last_updated || "")
    return isNaN(when) ? "" : relativeTime(when / 1000, nowSeconds)
  case "entity-id": return String(state.entity_id)
  case "brightness": return attrs.brightness ? Math.round(Number(attrs.brightness) / 2.55) + "%" : ""
  case "position": return attrs.current_position !== undefined ? attrs.current_position + "%" : ""
  case "tilt-position": return attrs.current_tilt_position !== undefined ? attrs.current_tilt_position + "%" : ""
  case "state": return stateText(state, null)
  }
  return ""
}

function attributeText(state, attribute, prefix, suffix) {
  if (!state || !state.attributes) return ""
  var value = state.attributes[attribute]
  if (value === undefined || value === null) return "—"
  if (typeof value === "object") value = JSON.stringify(value)
  return String(prefix || "") + String(value) + String(suffix || "")
}

// ------------------------------------------------------------------- icons

var DEVICE_CLASS_ICONS = {
  sensor: {
    temperature: "thermometer", humidity: "water-percent", power: "flash", energy: "lightning-bolt",
    battery: "battery", illuminance: "brightness-5", pressure: "gauge", timestamp: "clock-outline",
    voltage: "sine-wave", current: "current-ac", signal_strength: "wifi", carbon_dioxide: "molecule-co2",
    pm25: "air-filter", pm10: "air-filter", monetary: "cash", duration: "progress-clock",
    distance: "arrow-left-right", speed: "speedometer", frequency: "sine-wave", gas: "meter-gas",
    water: "water", weight: "weight", wind_speed: "weather-windy", data_size: "database",
    data_rate: "transmission-tower", power_factor: "angle-acute", apparent_power: "flash",
    reactive_power: "flash", enum: "format-list-bulleted", aqi: "air-filter"
  },
  binary_sensor: {
    motion: ["motion-sensor-off", "motion-sensor"], door: ["door-closed", "door-open"],
    garage_door: ["garage", "garage-open"], window: ["window-closed", "window-open"],
    opening: ["square", "square-outline"], occupancy: ["home-outline", "home"],
    presence: ["home-outline", "home"], connectivity: ["close-network-outline", "check-network-outline"],
    problem: ["check-circle", "alert-circle"], smoke: ["smoke-detector", "smoke-detector-alert"],
    moisture: ["water-off", "water"], battery: ["battery", "battery-outline"], lock: ["lock", "lock-open"],
    plug: ["power-plug-off", "power-plug"], power: ["power-plug-off", "power-plug"],
    light: ["brightness-5", "brightness-7"], sound: ["music-note-off", "music-note"],
    vibration: ["crop-portrait", "vibrate"], gas: ["check-circle", "alert-circle"],
    safety: ["check-circle", "alert-circle"], tamper: ["check-circle", "alert-circle"],
    running: ["stop", "play"], heat: ["thermometer", "fire"], cold: ["thermometer", "snowflake"],
    update: ["package", "package-up"], carbon_monoxide: ["smoke-detector", "smoke-detector-alert"],
    moving: ["arrow-right", "arrow-right-bold"]
  },
  cover: {
    garage: ["garage", "garage-open"], door: ["door-closed", "door-open"], gate: ["gate", "gate-open"],
    blind: ["blinds", "blinds-open"], curtain: ["curtains-closed", "curtains"], shutter: ["window-shutter", "window-shutter-open"],
    window: ["window-closed", "window-open"], awning: ["awning-outline", "awning-outline"], damper: ["circle", "circle-slice-8"]
  },
  media_player: { tv: "television", speaker: "speaker", receiver: "audio-video" },
  switch: { outlet: ["power-plug-off", "power-plug"] }
}

var DOMAIN_ICONS = {
  light: ["lightbulb-off", "lightbulb"], switch: ["toggle-switch-variant-off", "toggle-switch-variant"],
  input_boolean: ["toggle-switch-outline", "toggle-switch"], fan: ["fan-off", "fan"],
  cover: ["window-closed", "window-open"], lock: ["lock", "lock-open-variant"], climate: "thermostat",
  media_player: ["cast-off", "cast"], sensor: "eye", binary_sensor: ["radiobox-blank", "radiobox-marked"],
  scene: "palette", script: "script-text", automation: ["robot-off", "robot"],
  button: "gesture-tap-button", input_button: "gesture-tap-button", input_number: "ray-vertex",
  number: "ray-vertex", input_select: "format-list-bulleted", select: "format-list-bulleted",
  input_text: "form-textbox", text: "form-textbox", input_datetime: "calendar-clock", camera: "video",
  person: "account", device_tracker: "account", sun: "white-balance-sunny", update: ["package", "package-up"],
  todo: "clipboard-list", vacuum: "robot-vacuum", siren: "bullhorn", remote: "remote", valve: "valve",
  water_heater: "water-boiler", humidifier: "air-humidifier", image: "image", event: "gesture-tap",
  counter: "counter", timer: "timer-outline", zone: "map-marker-radius", calendar: "calendar",
  lawn_mower: "robot-mower", group: "google-circles-communities", weather: "weather-partly-cloudy",
  alarm_control_panel: "shield", conversation: "forum", notify: "bell", tts: "speaker-message",
  stt: "microphone-message", ai_task: "star-four-points", schedule: "calendar-clock", date: "calendar",
  time: "clock-outline", datetime: "calendar-clock", water: "water"
}

var ALARM_ICONS = {
  disarmed: "shield-off", armed_home: "shield-home", armed_away: "shield-lock", armed_night: "shield-moon",
  armed_vacation: "shield-airplane", armed_custom_bypass: "security", pending: "shield-outline",
  arming: "shield-outline", disarming: "shield-outline", triggered: "bell-ring"
}

var WEATHER_ICONS = {
  "clear-night": "weather-night", cloudy: "weather-cloudy", exceptional: "alert-circle-outline",
  fog: "weather-fog", hail: "weather-hail", lightning: "weather-lightning", "lightning-rainy": "weather-lightning-rainy",
  partlycloudy: "weather-partly-cloudy", pouring: "weather-pouring", rainy: "weather-rainy",
  snowy: "weather-snowy", "snowy-rainy": "weather-snowy-rainy", sunny: "weather-sunny",
  windy: "weather-windy", "windy-variant": "weather-windy-variant"
}

function pick(icon, on) {
  if (typeof icon === "string") return icon
  return icon ? icon[on ? 1 : 0] : ""
}

// The icon name HA would pick: the configured one, the entity's own, then the
// default for its device class and state.
function iconName(entityId, state, override, info) {
  if (override) return String(override)
  if (state && state.attributes && state.attributes.icon) return String(state.attributes.icon)
  if (info && info.icon) return String(info.icon)

  var domain = domainOf(entityId)
  var value = state ? String(state.state) : ""
  var cls = state && state.attributes ? state.attributes.device_class : ""
  var on = isActive(state)

  if (domain === "alarm_control_panel") return "mdi:" + (ALARM_ICONS[value] || "shield")
  if (domain === "weather") return "mdi:" + (WEATHER_ICONS[value] || "weather-partly-cloudy")
  if (domain === "sun") return "mdi:" + (value === "above_horizon" ? "white-balance-sunny" : "weather-night")
  if (domain === "person" || domain === "device_tracker") return "mdi:" + (value === "home" ? "account" : "account-arrow-right")
  if (domain === "lock") return "mdi:" + (value === "locked" ? "lock" : value === "jammed" ? "lock-alert" : "lock-open-variant")
  if (domain === "media_player" && value === "off" && cls === "tv") return "mdi:television-off"
  if (domain === "camera") return "mdi:" + (value === "unavailable" ? "video-off" : "video")
  if (domain === "sensor" && cls === "battery" && state) {
    var level = parseFloat(state.state)
    if (!isNaN(level)) {
      var step = Math.round(level / 10) * 10
      return "mdi:" + (step >= 100 ? "battery" : step <= 0 ? "battery-outline" : "battery-" + step)
    }
  }

  var byClass = DEVICE_CLASS_ICONS[domain]
  if (byClass && cls && byClass[cls]) return "mdi:" + pick(byClass[cls], on)
  return "mdi:" + (pick(DOMAIN_ICONS[domain], on) || "bookmark")
}

function glyph(name) {
  var text = String(name || "")
  // Only mdi: icons exist in the font. hass:* is the old spelling of the same set.
  text = text.replace(/^hass:/, "mdi:")
  return Icons.glyph(text) || Icons.glyph("mdi:bookmark")
}

function entityGlyph(entityId, state, override, info) {
  return glyph(iconName(entityId, state, override, info))
}

// ---------------------------------------------------------------- controls

// Light
function brightnessPercent(state) {
  if (!state || state.state !== "on") return 0
  var value = Number(state.attributes && state.attributes.brightness || 0)
  return Math.round(value / 2.55)
}

function lightModes(state) {
  return (state && state.attributes && state.attributes.supported_color_modes) || []
}

function supportsBrightness(state) {
  var modes = lightModes(state)
  for (var i = 0; i < modes.length; i++) if (modes[i] !== "onoff") return true
  return false
}

function supportsColorTemp(state) {
  return lightModes(state).indexOf("color_temp") >= 0
}

function supportsColor(state) {
  var modes = lightModes(state)
  return ["hs", "rgb", "rgbw", "rgbww", "xy"].some(function(mode) { return modes.indexOf(mode) >= 0 })
}

// Cover features
var COVER = { OPEN: 1, CLOSE: 2, SET_POSITION: 4, STOP: 8, OPEN_TILT: 16, CLOSE_TILT: 32, STOP_TILT: 64, SET_TILT: 128 }
// Media features
var MEDIA = { PAUSE: 1, SEEK: 2, VOLUME_SET: 4, VOLUME_MUTE: 8, PREVIOUS: 16, NEXT: 32, TURN_ON: 128,
  TURN_OFF: 256, PLAY_MEDIA: 512, VOLUME_STEP: 1024, SELECT_SOURCE: 2048, STOP: 4096, PLAY: 16384,
  SHUFFLE: 32768, SELECT_SOUND_MODE: 65536, REPEAT: 262144 }
// Climate features
var CLIMATE = { TARGET_TEMPERATURE: 1, TARGET_TEMPERATURE_RANGE: 2, TARGET_HUMIDITY: 4, FAN_MODE: 8,
  PRESET_MODE: 16, SWING_MODE: 32, TURN_OFF: 128, TURN_ON: 256 }
// Fan features
var FAN = { SET_SPEED: 1, OSCILLATE: 2, DIRECTION: 4, PRESET_MODE: 8 }
// Vacuum features
var VACUUM = { PAUSE: 4, STOP: 8, RETURN_HOME: 16, FAN_SPEED: 32, LOCATE: 512, CLEAN_SPOT: 1024, START: 8192 }
// Lock, update, alarm features
var LOCK = { OPEN: 1 }
var UPDATE = { INSTALL: 1 }
var ALARM = { ARM_HOME: 1, ARM_AWAY: 2, ARM_NIGHT: 4, TRIGGER: 8, ARM_CUSTOM_BYPASS: 16, ARM_VACATION: 32 }

// The temperature step a thermostat moves by.
function climateStep(state) {
  var attrs = (state && state.attributes) || {}
  if (attrs.target_temp_step) return Number(attrs.target_temp_step)
  var unit = String(attrs.temperature_unit || attrs.unit_of_measurement || "")
  return unit.indexOf("F") >= 0 ? 1 : 0.5
}

function clampTemp(value, state) {
  var attrs = (state && state.attributes) || {}
  var low = attrs.min_temp !== undefined ? Number(attrs.min_temp) : 7
  var high = attrs.max_temp !== undefined ? Number(attrs.max_temp) : 35
  var step = climateStep(state)
  var snapped = Math.round(value / step) * step
  return Math.max(low, Math.min(high, Math.round(snapped * 100) / 100))
}

// The buttons an alarm panel offers in its current state. `wanted` is the
// card's `states`, in HA's spelling ("arm_home"), filtered by what the panel
// actually supports.
var ALARM_ACTIONS = [
  { state: "arm_home", service: "alarm_arm_home", label: "Arm home", feature: 1 },
  { state: "arm_away", service: "alarm_arm_away", label: "Arm away", feature: 2 },
  { state: "arm_night", service: "alarm_arm_night", label: "Arm night", feature: 4 },
  { state: "arm_vacation", service: "alarm_arm_vacation", label: "Arm vacation", feature: 32 },
  { state: "arm_custom_bypass", service: "alarm_arm_custom_bypass", label: "Custom bypass", feature: 16 }
]

function alarmActions(state, wanted) {
  if (!state || state.state === "unavailable") return []
  if (state.state !== "disarmed") return [{ service: "alarm_disarm", label: "Disarm", needsCode: alarmNeedsCode(state, true) }]
  var list = asList(wanted && wanted.length ? wanted : ["arm_home", "arm_away"])
  var out = []
  for (var i = 0; i < ALARM_ACTIONS.length; i++) {
    var action = ALARM_ACTIONS[i]
    if (list.indexOf(action.state) < 0) continue
    var features = Number(state.attributes && state.attributes.supported_features || 0)
    if (features && !(features & action.feature)) continue
    out.push({ service: action.service, label: action.label, needsCode: alarmNeedsCode(state, false) })
  }
  return out
}

function alarmNeedsCode(state, disarming) {
  var attrs = (state && state.attributes) || {}
  if (attrs.code_format === null || attrs.code_format === undefined) return false
  return disarming ? true : attrs.code_arm_required !== false
}

// Options for a select-like entity, whichever attribute carries them.
function optionsOf(state, attribute) {
  var attrs = (state && state.attributes) || {}
  var list = attrs[attribute || "options"] || []
  return asList(list).map(function(value) { return { value: String(value), label: String(value) } })
}

// input_number / number: { min, max, step, mode, unit }
function numberRange(state) {
  var attrs = (state && state.attributes) || {}
  return {
    min: attrs.min !== undefined ? Number(attrs.min) : 0,
    max: attrs.max !== undefined ? Number(attrs.max) : 100,
    step: attrs.step !== undefined ? Number(attrs.step) : 1,
    mode: String(attrs.mode || "slider"),
    unit: attrs.unit_of_measurement ? String(attrs.unit_of_measurement) : ""
  }
}

// The attributes worth listing in the detail view: everything that is not
// plumbing, a token, or already shown as a control.
var HIDDEN_ATTRIBUTES = ["friendly_name", "icon", "entity_picture", "supported_features", "access_token",
  "token", "assumed_state", "attribution", "restored", "editable", "device_class", "unit_of_measurement",
  "state_class", "supported_color_modes", "color_mode", "hs_color", "rgb_color", "xy_color", "entity_id",
  "id", "context", "options", "effect_list", "source_list", "sound_mode_list", "hvac_modes",
  "preset_modes", "fan_modes", "swing_modes", "min_color_temp_kelvin", "max_color_temp_kelvin",
  "min_mireds", "max_mireds", "color_temp", "entity_picture_local", "code_format"]

function attributeRows(state) {
  var attrs = (state && state.attributes) || {}
  var out = []
  for (var key in attrs) {
    if (HIDDEN_ATTRIBUTES.indexOf(key) >= 0) continue
    var value = attrs[key]
    if (value === null || value === undefined || value === "") continue
    if (typeof value === "number" && !Number.isInteger(value)) value = Math.round(value * 1000) / 1000
    if (typeof value === "object") {
      var text = JSON.stringify(value)
      if (text.length > 80) text = text.slice(0, 77) + "…"
      value = text
    }
    out.push({ key: titleCase(key), value: String(value) })
  }
  return out
}

// "Light · living room" -> the entities a fuzzy IPC name could mean. Exact id
// first, then a friendly name in any case.
function resolveEntity(text, states) {
  var wanted = String(text || "").trim()
  if (wanted === "" || !states) return ""
  if (states[wanted]) return wanted
  var lower = wanted.toLowerCase()
  for (var id in states) {
    if (id.toLowerCase() === lower) return id
  }
  for (id in states) {
    var name = states[id] && states[id].attributes ? String(states[id].attributes.friendly_name || "") : ""
    if (name.toLowerCase() === lower) return id
  }
  return ""
}

// Weather forecast rows from weather/subscribe_forecast.
function forecastRows(forecast, type, limit) {
  var out = []
  var list = forecast || []
  for (var i = 0; i < list.length && out.length < (limit || 5); i++) {
    var item = list[i]
    var when = Date.parse(item.datetime || "")
    var label = ""
    if (!isNaN(when)) {
      var date = new Date(when)
      label = type === "hourly"
        ? (date.getHours() < 10 ? "0" : "") + date.getHours() + "h"
        : ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][date.getDay()]
    }
    out.push({
      label: label,
      icon: "mdi:" + (WEATHER_ICONS[item.condition] || "weather-partly-cloudy"),
      high: item.temperature !== undefined && item.temperature !== null ? Math.round(item.temperature) + "°" : "",
      low: item.templow !== undefined && item.templow !== null ? Math.round(item.templow) + "°" : "",
      rain: item.precipitation_probability ? item.precipitation_probability + "%" : ""
    })
  }
  return out
}

// Markdown cards are Jinja templates rendered by HA. This only tidies the
// result for Qt's CommonMark: HA's <ha-alert> and <ha-icon> have no meaning
// here, so they become plain text instead of leaking as tags.
function cleanMarkdown(text) {
  return String(text || "")
    .replace(/<ha-icon[^>]*icon="([^"]+)"[^>]*>\s*<\/ha-icon>/g, function(_, name) { return glyph(name) })
    .replace(/<ha-alert[^>]*>/g, "> ")
    .replace(/<\/ha-alert>/g, "")
    .replace(/<\/?(center|font|div|span)[^>]*>/g, "")
    // A placeholder such as "<name>" in prose is not a tag, but Qt reads it as
    // one and swallows the rest of the paragraph — and any table after it.
    .replace(/<(?!\/?(a|b|i|u|s|br|p|em|strong|code|pre|img|ul|ol|li|h[1-6]|hr|sub|sup|table|tr|td|th|blockquote)\b)/gi, "&lt;")
}
