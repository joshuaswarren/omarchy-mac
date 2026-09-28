-- omarchy-mac: Apple Silicon Hyprland settings. Omarchy loads this directory
-- (default/hypr/platform/settings in the packaged tree) after its own defaults
-- and before the theme and the user's files, so these replace Omarchy's and the
-- user's input.lua can still replace them.

if not (o and o.shell_succeeds and o.shell_succeeds("omarchy-hw-apple-silicon")) then
  return
end

-- The built-in trackpad clicks physically; Asahi's disable-while-typing does
-- not stop stray taps, so tap-to-click stays off. The user's input.lua can turn
-- it back on with the same line and tap_to_click = true.
hl.device({ name = "apple-mtp-multi-touch", tap_to_click = false })
hl.device({ name = "apple-spi-trackpad", tap_to_click = false })
