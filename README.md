# HA Overview

Your Home Assistant dashboards in the [Omarchy](https://omarchy.org) bar. Click
the icon and the dashboard drops down — drawn natively, card by card, with
every switch, slider, thermostat, alarm keypad and camera working live.

- **Your real dashboards.** It reads the same Lovelace config the HA frontend
  does, so the cards, titles, views and order are the ones you built. The
  auto-generated Overview (before you ever "took control") is rebuilt from your
  areas, the way HA does it.
- **A dropdown of dashboards.** Pick which ones it lists in the settings; tabs
  switch between a dashboard's views.
- **Every control.** Lights (brightness, colour temperature, colour, effects),
  switches, fans, covers (position, tilt), climate (modes, presets, ranges),
  media players (transport, volume, source), locks, alarm panels (with keypad),
  vacuums, valves, selects, numbers, text, scenes, scripts, buttons, updates,
  timers, counters and to-do lists. Tap any entity for its full controls.
- **Live.** State changes arrive over Home Assistant's websocket the moment
  they happen — no polling.
- **Cameras.** Snapshots refresh while the panel is open; the play button opens
  the live stream in mpv.

## Install

```bash
omarchy plugin add https://github.com/duarte-gui/homeassistant-omarchy
```

or from a clone:

```bash
git clone https://github.com/duarte-gui/homeassistant-omarchy
cd homeassistant-omarchy
./install.sh
```

Then right click the bar icon (or press `s` in the panel) and fill in:

1. **Home Assistant address** — an IP such as `192.168.1.10`, a hostname such
   as `homeassistant.local`, or a full URL. A bare IP or hostname gets port 8123.
2. **Access token** — in Home Assistant, open your profile → *Security* →
   *Long-lived access tokens* → *Create token*, and paste it.
3. **Dashboards in the dropdown** — every dashboard is listed until you untick
   one.

Requirements: `python3` (standard library only) for the websocket bridge, and
`mpv` if you want live camera streams.

## Using it

| Where | What |
|---|---|
| Left click | drop the dashboard down |
| Right click | settings |
| Middle click | open Home Assistant in the browser, on the same view |
| Tap an entity | its tap action — usually its full controls |
| Right click an entity | always its full controls |
| Tile icon | toggle |
| Middle click a camera | live stream in mpv |

Keys in the panel: `1`–`9` views, `←`/`→` previous/next view, `d`/`D` next/previous
dashboard, `↑`/`↓` scroll, `s` settings, `r` refresh, `o` open in the browser,
`Esc` back/close.

### From a keybinding or a script

```bash
omarchy-shell hass toggle                          # the panel
omarchy-shell hass dashboard map                   # a dashboard, by url_path or title
omarchy-shell hass view alarm                      # a view, by path, title or number
omarchy-shell hass toggleEntity light.desk         # an entity id or friendly name
omarchy-shell hass call scene.turn_on scene.movie  # any service
omarchy-shell hass state "Living room temperature"
omarchy-shell hass moreInfo climate.office         # open that entity's controls
omarchy-shell hass dashboards | status | refresh | setup | browser
```

`hypr/ha-overview-bindings.lua` has ready-made Hyprland bindings
(`SUPER+ALT+H` opens the panel), and `hypr/ha-overview.lua` floats and pins the
camera stream window.

## Settings

Everything lives on the widget's entry in `~/.config/omarchy/shell.json`:

| Key | Default | |
|---|---|---|
| `haUrl` | `http://homeassistant.local:8123` | where Home Assistant is |
| `token` | | long-lived access token |
| `dashboards` | all | url_paths listed in the dropdown |
| `columns` | `2` | card columns |
| `panelWidth` | `760` | dropdown width in px |
| `panelHeight` | `860` | height before it scrolls |
| `cameraRefreshSec` | `10` | camera snapshot refresh, only while open |
| `notifyErrors` | `true` | toast a failed action when the panel is closed |

`dashboard` and `view` are written back by the panel so it reopens where you
left it.

## How it works

`bridge.py` keeps one websocket open to Home Assistant — the dashboards
themselves (`lovelace/config`), the registries and the stream of state changes
are only served there, and the shell has no websocket module. It speaks the
protocol with the Python standard library and talks to the widget in JSON
lines. The access token reaches it on stdin, never in a command line, where any
local account could read it from `/proc`. Camera stream URLs reach mpv the same
way.

`Model.js` turns a dashboard into a list of blocks once, from its config alone;
every card then reads live state as it renders, so a state change re-renders
only the rows it touches.

Card types drawn natively: entities (with section, divider, attribute, weblink,
text, button and buttons rows, and the header toggle), tile (with its
features), button, glance, entity, sensor, gauge, light, thermostat,
humidifier, media-control, alarm-panel, weather-forecast, markdown (templates
rendered by HA, live), picture-entity, picture-glance, picture, heading, map
(as a list of people and trackers), grid, vertical-stack, horizontal-stack,
conditional and sections views, plus `visibility` conditions and view badges.
Any other card — including custom ones — is shown as a list of the entities it
mentions, so nothing on a dashboard is out of reach.

## Development

```bash
./install.sh --watch   # re-sync on every save; the shell hot-reloads the QML
node Model.test.js     # the pure logic, no shell needed
```

Imported `.js` files are not hot-reloaded: after editing `Model.js`, run
`omarchy restart shell`. `tools/gen-icons.py` regenerates `Icons.js`, the
`mdi:` name → Nerd Font codepoint table.

## License

MIT
