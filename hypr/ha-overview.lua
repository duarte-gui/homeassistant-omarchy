-- HA Overview camera stream window rules.
--
-- Optional. Clicking a camera's play button opens its live stream in mpv under
-- a dedicated wayland app id, so these rules can float it without catching
-- every other mpv window. Load it from ~/.config/hypr/hyprland.lua with:
--
--   dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.duarte-gui.ha-overview/hypr/ha-overview.lua")

o.window({ class = "^ha-overview-camera$" }, {
  float = true,
  pin = true,
  keep_aspect_ratio = true,
  size = { "(monitor_w*2/5)", "(monitor_w*2/5*9/16)" },
  move = { "(monitor_w-monitor_w*2/5-24)", "(monitor_h-monitor_w*2/5*9/16-24)" },
})
