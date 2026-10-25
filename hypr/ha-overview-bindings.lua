-- HA Overview keyboard shortcuts.
--
-- Copy these lines into ~/.config/hypr/bindings.lua, or load the whole file
-- from ~/.config/hypr/hyprland.lua with:
--
--   dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.duarte-gui.ha-overview/hypr/ha-overview-bindings.lua")
--
-- SUPER+ALT+H is free on a stock Omarchy install. Change it to taste — the
-- commands are what matter.

-- Drop the dashboard down.
o.bind("SUPER + ALT + H", "Home Assistant", "omarchy-shell -q hass toggle")

-- Assist, and Home Assistant's notifications. Free on a stock install too.
-- o.bind("SUPER + ALT + A", "Assist", "omarchy-shell -q hass chat")
-- o.bind("SUPER + ALT + N", "Home Assistant notifications", "omarchy-shell -q hass notifications")

-- Any entity can get a key of its own. Uncomment and point at yours:
-- o.bind("SUPER + ALT + L", "Desk lamp", "omarchy-shell -q hass toggleEntity light.desk")
-- o.bind("SUPER + ALT + M", "Movie scene", "omarchy-shell -q hass call scene.turn_on scene.movie")
