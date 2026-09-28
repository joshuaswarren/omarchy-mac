-- omarchy-mac: Apple Silicon Hyprland settings. Omarchy loads this directory
-- (hypr/settings under /usr/share/omarchy-platform) after its own defaults and
-- before the theme and the user's files, so these replace Omarchy's and the
-- user's input.lua can still replace them.

if not (o and o.shell_succeeds and o.shell_succeeds("omarchy-hw-apple-silicon")) then
  return
end

-- The built-in trackpad clicks physically; Asahi's disable-while-typing does
-- not stop stray taps, so tap-to-click stays off. The user's input.lua can turn
-- it back on with the same line and tap_to_click = true.
hl.device({ name = "apple-mtp-multi-touch", tap_to_click = false })
hl.device({ name = "apple-spi-trackpad", tap_to_click = false })

-- A workspace swipe steps by number, so it reaches empty workspaces as Spaces
-- do in macOS. Hyprland's default steps only through workspaces that exist and
-- never out of an empty one into a new one. The user's input.lua turns it off
-- with hl.config({ gestures = { workspace_swipe_use_r = false } }).
hl.config({ gestures = { workspace_swipe_use_r = true } })
