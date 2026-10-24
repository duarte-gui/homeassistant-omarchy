// Tests for Model.js, runnable with plain node — no shell, no Qt.
//
//   node Model.test.js
//
// Model.js is a QML JS library, so it opens with `.pragma library` and an
// `.import` of Icons.js, neither of which node understands. Icons.js is
// evaluated first under the name the import gives it, then both directives
// are stripped and the rest is ordinary JavaScript.

const fs = require("fs")
const path = require("path")

const strip = (file) => fs.readFileSync(path.join(__dirname, file), "utf8")
  .replace(/^\s*\.pragma\s+library\s*$/m, "")
  .replace(/^\s*\.import\s+.*$/gm, "")

const Icons = new Function(strip("Icons.js") + "\nreturn { glyph: glyph }")()
eval(strip("Model.js"))

let failures = 0
const eq = (label, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want)
  if (g !== w) failures++
  console.log((g === w ? "ok   " : "FAIL ") + label + (g === w ? "" : `\n       got  ${g}\n       want ${w}`))
}

// --- address ---
eq("bare ip gets 8123", normalizeHaUrl("192.168.0.20"), "http://192.168.0.20:8123")
eq("hostname gets 8123", normalizeHaUrl("homeassistant.local"), "http://homeassistant.local:8123")
eq("host:port kept", normalizeHaUrl("ha.lan:8124"), "http://ha.lan:8124")
eq("https kept, no port", normalizeHaUrl("https://ha.example.org/"), "https://ha.example.org")
eq("path kept", normalizeHaUrl("https://example.org/ha/"), "https://example.org/ha")
eq("garbage", normalizeHaUrl("not a url"), "")
eq("empty", normalizeHaUrl("  "), "")
eq("address text strips default port", haAddressText("http://10.0.0.5:8123"), "10.0.0.5")
eq("address text keeps others", haAddressText("https://ha.example.org"), "https://ha.example.org")
eq("picture relative", pictureUrl("http://h:8123", "/api/camera_proxy/camera.x?token=t", 3),
  "http://h:8123/api/camera_proxy/camera.x?token=t&_t=3")
eq("picture absolute", pictureUrl("http://h:8123", "https://cdn/x.png"), "https://cdn/x.png")
eq("token shape ok", tokenLooksValid("aaa.bbb.ccc"), true)
eq("token shape bad", tokenLooksValid("hello world"), false)

// --- dashboards ---
const panels = [
  { url_path: "map", title: "Map", icon: "mdi:map" },
  { url_path: "lovelace", title: "Overview", icon: "mdi:view-dashboard" },
  { url_path: "dashboard-energy", title: "", icon: "" },
]
const options = dashboardOptions(panels)
eq("overview first", options.map(o => o.value), ["lovelace", "dashboard-energy", "map"])
eq("untitled gets a name", options[1].label, "Dashboard energy")
eq("all when unpicked", visibleDashboards(options, "").length, 3)
eq("picked only", visibleDashboards(options, ["map"]).map(o => o.value), ["map"])
eq("picked as string", visibleDashboards(options, "lovelace, map").map(o => o.value), ["lovelace", "map"])
eq("stale dashboards", staleDashboards(options, ["map", "gone"]), ["gone"])

// --- views ---
const user = { id: "u1" }
const config = {
  views: [
    { title: "Home", path: "home", cards: [{ type: "entities", entities: ["light.desk"] }] },
    { title: "Hidden", path: "secret", visible: [{ user: "someone-else" }], cards: [] },
    { title: "Mine", path: "mine", visible: [{ user: "u1" }], cards: [] },
    { title: "Sub", path: "sub", subview: true, cards: [] },
    { path: "untitled", cards: [] },
  ]
}
const views = viewsFor(config, { user })
eq("visibility filters", views.map(v => v.path), ["home", "mine", "sub", "untitled"])
eq("index survives filtering", views[1].index, 2)
eq("tabs drop subviews", tabViews(views).map(v => v.path), ["home", "mine", "untitled"])
eq("title from path", views[3].title, "Untitled")
eq("find by path", findView(views, "mine"), 1)
eq("find by title", findView(views, "HOME"), 0)
eq("find by index", findView(views, "3"), 2)
eq("find empty -> first", findView(views, ""), 0)
eq("find missing", findView(views, "nope"), -1)

eq("navigate other dashboard", parseNavigation("/map/0", "lovelace", ["lovelace", "map"]), { dashboard: "map", view: "0" })
eq("navigate same dashboard", parseNavigation("/lovelace/alarm", "map", ["lovelace", "map"]), { dashboard: "lovelace", view: "alarm" })
eq("navigate relative", parseNavigation("alarm", "map", ["lovelace", "map"]), { dashboard: "map", view: "alarm" })

// --- auto-generated Overview ---
const states = {
  "light.desk": { entity_id: "light.desk", state: "on", attributes: { friendly_name: "Desk", brightness: 128, supported_color_modes: ["brightness"] } },
  "switch.fan": { entity_id: "switch.fan", state: "off", attributes: { friendly_name: "Fan plug" } },
  "sensor.temp": { entity_id: "sensor.temp", state: "21.456", attributes: { friendly_name: "Temp", unit_of_measurement: "°C", device_class: "temperature" } },
  "sensor.diag": { entity_id: "sensor.diag", state: "1", attributes: { friendly_name: "Diag" } },
  "camera.door": { entity_id: "camera.door", state: "idle", attributes: { friendly_name: "Door", entity_picture: "/api/camera_proxy/camera.door?token=x" } },
  "person.alex": { entity_id: "person.alex", state: "home", attributes: { friendly_name: "Alex" } },
  "notify.phone": { entity_id: "notify.phone", state: "unknown", attributes: {} },
}
const ctx = {
  states,
  areas: [{ area_id: "office", name: "Office" }],
  devices: [{ id: "d1", area_id: "office" }],
  entities: [
    { entity_id: "light.desk", device_id: "d1" },
    { entity_id: "camera.door", area_id: "office" },
    { entity_id: "sensor.diag", entity_category: 1 },
  ],
  user
}
const auto = viewsFor(null, ctx)
eq("auto: one view", auto.length, 1)
eq("auto: badges are people", auto[0].badges, [{ entity: "person.alex" }])
eq("auto: card order", auto[0].cards.map(c => c.type + ":" + (c.title || c.entity)),
  ["entities:Office", "picture-entity:camera.door", "entities:Sensors", "entities:Switches"])
eq("auto: area via device", auto[0].cards[0].entities, [{ entity: "light.desk" }])
eq("auto: strategy config too", viewsFor({ strategy: { type: "original-states" } }, ctx)[0].cards.length, 4)

// --- blocks ---
const view = {
  index: 0, type: "masonry", badges: ["person.alex"],
  cards: [
    { type: "grid", columns: 1, cards: [
      { type: "entities", title: "Yard", entities: [{ entity: "light.desk", name: "Front" }, { type: "divider" }, "switch.fan"] },
      { type: "picture-entity", entity: "camera.door" }
    ]},
    { type: "tile", entity: "light.desk" },
    { type: "tile", entity: "switch.fan" },
    { type: "markdown", content: "**hi**" },
    { type: "conditional", conditions: [{ entity: "switch.fan", state: "on" }], card: { type: "alarm-panel", entity: "alarm_control_panel.home" } },
    { type: "custom:mushroom-light-card", entity: "light.desk" },
    { type: "custom:clock-card" },
  ]
}
const blocks = blocksForView(view, ctx)
eq("block kinds", blocks.map(b => b.kind), ["badges", "stack", "tiles", "markdown", "alarm", "entities", "note"])
eq("grid of mixed -> vertical stack", [blocks[1].direction, blocks[1].children.map(c => c.kind)], ["vertical", ["entities", "camera"]])
eq("rows normalized", blocks[1].children[0].rows.map(r => r.type + ":" + (r.name || r.entity)), ["entity:Front", "divider:", "entity:switch.fan"])
eq("consecutive tiles share a grid", [blocks[2].tiles.length, blocks[2].columns], [2, 2])
eq("conditional carries conditions", blocks[4].conditions, [{ entity: "switch.fan", state: "on" }])
eq("custom card falls back to its entities", blocks[5].rows.map(r => r.entity), ["light.desk"])
eq("keys unique", new Set(blocks.map(b => b.key)).size, blocks.length)

const sections = blocksForView({ index: 1, type: "sections", sections: [
  { type: "grid", cards: [{ type: "heading", heading: "Living" }, { type: "tile", entity: "light.desk" }, { type: "tile", entity: "switch.fan" }] }
]}, ctx)
eq("sections -> one stack each", [sections.length, sections[0].children.map(c => c.kind)], [1, ["heading", "tiles"]])

eq("special rows", [
  normalizeRow({ type: "section", label: "Power" }).label,
  normalizeRow({ type: "call-service", name: "Go", service: "script.go" }).tapAction.perform_action,
  normalizeRow({ type: "attribute", entity: "sun.sun", attribute: "elevation", suffix: "°" }).suffix,
  normalizeRow({ type: "conditional", row: { entity: "light.desk" }, conditions: [{ entity: "x", state: "on" }] }).conditions.length,
], ["Power", "script.go", "°", 1])

const cols = distribute([{ weight: 5 }, { weight: 1 }, { weight: 1 }, { weight: 1 }], 2)
eq("masonry balances", cols.map(c => c.length), [1, 3])
eq("masonry one column", distribute([{ weight: 1 }, { weight: 1 }], 1)[0].length, 2)

// --- conditions ---
eq("state match", conditionsMet([{ entity: "light.desk", state: "on" }], states), true)
eq("state_not", conditionsMet([{ condition: "state", entity: "light.desk", state_not: "on" }], states), false)
eq("state list", conditionsMet([{ condition: "state", entity: "switch.fan", state: ["on", "off"] }], states), true)
eq("numeric above", conditionsMet([{ condition: "numeric_state", entity: "sensor.temp", above: 20 }], states), true)
eq("numeric below fails", conditionsMet([{ condition: "numeric_state", entity: "sensor.temp", below: 20 }], states), false)
eq("or", conditionsMet([{ condition: "or", conditions: [{ entity: "switch.fan", state: "on" }, { entity: "light.desk", state: "on" }] }], states), true)
eq("user", conditionsMet([{ condition: "user", users: ["u2"] }], states, user), false)
eq("screen always", conditionsMet([{ condition: "screen", media_query: "(min-width: 0px)" }], states), true)
eq("missing entity is unavailable", conditionsMet([{ entity: "light.none", state: "unavailable" }], states), true)

// --- states ---
eq("number with unit", stateText(states["sensor.temp"], null), "21.456 °C")
eq("display precision", stateText(states["sensor.temp"], { display_precision: 1 }), "21.5 °C")
eq("percent no space", stateText({ entity_id: "sensor.h", state: "40", attributes: { unit_of_measurement: "%" } }), "40%")
eq("binary motion", stateText({ entity_id: "binary_sensor.m", state: "on", attributes: { device_class: "motion" } }), "Detected")
eq("binary door off", stateText({ entity_id: "binary_sensor.d", state: "off", attributes: { device_class: "door" } }), "Closed")
eq("light brightness", stateText(states["light.desk"]), "On · 50%")
eq("alarm text", stateText({ entity_id: "alarm_control_panel.a", state: "armed_away", attributes: {} }), "Armed away")
eq("unavailable", stateText({ entity_id: "switch.x", state: "unavailable", attributes: {} }), "Unavailable")
eq("person away", stateText({ entity_id: "person.p", state: "not_home", attributes: {} }), "Away")
eq("weather", stateText({ entity_id: "weather.w", state: "partlycloudy", attributes: {} }), "Partly cloudy")
eq("relative", [relativeTime(100, 105), relativeTime(0, 90), relativeTime(7300, 100)], ["now", "1m ago", "in 2h"])

eq("active light", isActive(states["light.desk"]), true)
eq("inactive switch", isActive(states["switch.fan"]), false)
eq("sensor never active", isActive(states["sensor.temp"]), false)
eq("alarm armed is active", isActive({ entity_id: "alarm_control_panel.a", state: "armed_home" }), true)
eq("alarming triggered", isAlarming({ entity_id: "alarm_control_panel.a", state: "triggered" }), true)

// --- actions ---
eq("toggle light", toggleCall("light.desk", states["light.desk"]), { domain: "light", service: "toggle", data: {}, target: { entity_id: "light.desk" } })
eq("toggle lock", toggleCall("lock.door", { state: "locked" }).service, "unlock")
eq("toggle scene", toggleCall("scene.movie", { state: "unknown" }).service, "turn_on")
eq("toggle button", toggleCall("button.ring", null).service, "press")
eq("toggle unknown domain", toggleCall("foo.bar", null).domain, "homeassistant")
eq("has toggle", [hasToggle(states["light.desk"]), hasToggle(states["sensor.temp"]), hasToggle({ entity_id: "group.g", state: "home" })], [true, false, false])

eq("resolve default", resolveAction(null, "light.desk", "toggle"), { kind: "toggle", entity: "light.desk", confirm: "" })
eq("resolve perform-action", resolveAction({ action: "perform-action", perform_action: "light.turn_on", target: { entity_id: "light.desk" }, data: { brightness_pct: 10 } }, "", "more-info"),
  { kind: "call", domain: "light", service: "turn_on", data: { brightness_pct: 10 }, target: { entity_id: "light.desk" }, confirm: "" })
eq("resolve call-service (legacy)", resolveAction({ action: "call-service", service: "script.go", service_data: { x: 1 } }).service, "go")
eq("resolve navigate", resolveAction({ action: "navigate", navigation_path: "/lovelace/1" }), { kind: "navigate", path: "/lovelace/1" })
eq("resolve none", resolveAction({ action: "none" }, "light.desk"), { kind: "none" })
eq("resolve confirmation", resolveAction({ action: "toggle", confirmation: { text: "Sure?" } }, "switch.fan").confirm, "Sure?")

// --- controls ---
const alarm = { entity_id: "alarm_control_panel.home", state: "disarmed", attributes: { supported_features: 3, code_format: "number", code_arm_required: false } }
eq("alarm arm buttons", alarmActions(alarm, ["arm_away", "arm_night"]).map(a => a.service), ["alarm_arm_away"])
eq("alarm arm no code", alarmActions(alarm, ["arm_away"])[0].needsCode, false)
eq("alarm disarm needs code", alarmActions(Object.assign({}, alarm, { state: "armed_away" }))[0], { service: "alarm_disarm", label: "Disarm", needsCode: true })
eq("climate step", [climateStep({ attributes: {} }), climateStep({ attributes: { temperature_unit: "°F" } }), climateStep({ attributes: { target_temp_step: 0.1 } })], [0.5, 1, 0.1])
eq("clamp temp", clampTemp(40.3, { attributes: { min_temp: 10, max_temp: 30 } }), 30)
eq("clamp snaps", clampTemp(21.3, { attributes: {} }), 21.5)
eq("brightness percent", brightnessPercent(states["light.desk"]), 50)
eq("supports brightness", [supportsBrightness(states["light.desk"]), supportsBrightness({ attributes: { supported_color_modes: ["onoff"] } })], [true, false])
eq("number range", numberRange({ attributes: { min: 1, max: 5, step: 0.5, unit_of_measurement: "x" } }), { min: 1, max: 5, step: 0.5, mode: "slider", unit: "x" })
eq("attribute rows hide plumbing", attributeRows({ attributes: { friendly_name: "x", access_token: "t", elevation: 3, list: [1, 2] } }),
  [{ key: "Elevation", value: "3" }, { key: "List", value: "[1,2]" }])
eq("resolve entity by name", resolveEntity("desk", states), "light.desk")
eq("resolve entity exact", resolveEntity("switch.fan", states), "switch.fan")

// --- icons ---
eq("icon override", iconName("light.desk", states["light.desk"], "mdi:lamp"), "mdi:lamp")
eq("icon by state", [iconName("light.desk", states["light.desk"]), iconName("switch.fan", states["switch.fan"])], ["mdi:lightbulb", "mdi:toggle-switch-variant-off"])
eq("icon by device class", iconName("binary_sensor.m", { state: "on", attributes: { device_class: "motion" } }), "mdi:motion-sensor")
eq("icon battery level", iconName("sensor.b", { state: "47", attributes: { device_class: "battery" } }), "mdi:battery-50")
eq("glyph resolves", glyph("mdi:home-assistant"), String.fromCodePoint(0xF07D0))
eq("hass: prefix", glyph("hass:lightbulb"), glyph("mdi:lightbulb"))
eq("unknown icon falls back", glyph("mdi:does-not-exist"), glyph("mdi:bookmark"))

eq("forecast rows", forecastRows([{ datetime: "2026-01-05T12:00:00Z", condition: "sunny", temperature: 30.4, templow: 20.6, precipitation_probability: 10 }], "daily", 5),
  [{ label: "Mon", icon: "mdi:weather-sunny", high: "30°", low: "21°", rain: "10%" }])
eq("clean markdown", cleanMarkdown("<ha-alert alert-type=\"info\">Hi</ha-alert>"), "> Hi")
eq("placeholder is not a tag", cleanMarkdown("say <name> or <b>x</b>"), "say &lt;name> or <b>x</b>")

console.log(failures === 0 ? "\nall passed" : `\n${failures} failed`)
process.exit(failures === 0 ? 0 : 1)
