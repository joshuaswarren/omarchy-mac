#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

require_command lua
require_command node

# omarchy-mac fills Omarchy's platform hooks with the Mac's defaults: early
# Hyprland defaults (lid switch, capture chords, Shift+brightness on the
# keyboard backlight, menus on the built-in screen), settings (the trackpad),
# the keybindings menu's key names and the notch the bar keeps clear of. The
# runtime carries none of them. OMARCHY_TEST_RUNTIME points the test at another
# runtime layout (an upstream checkout with the same hooks) to show the package
# behaves the same.

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
runtime=${OMARCHY_TEST_RUNTIME:-$ROOT}
"$ROOT/packages/omarchy-mac/install" "$tmpdir/pkg" >/dev/null
packaged=$tmpdir/pkg/usr/share/omarchy

mkdir -p "$tmpdir/apple-bin" "$tmpdir/other-bin"
printf '#!/bin/sh\nexit 0\n' >"$tmpdir/apple-bin/omarchy-hw-apple-silicon"
printf '#!/bin/sh\nexit 1\n' >"$tmpdir/other-bin/omarchy-hw-apple-silicon"
chmod +x "$tmpdir"/*-bin/omarchy-hw-apple-silicon

# Loads the runtime's hyprland.lua against a user's ~/.config/hypr and prints
# every bind ("bind<TAB>keys<TAB>command", "global <name>" for the shell's
# global shortcut, or "focus <keyboards>" for a bind scoped to keyboards) and
# device setting ("device<TAB>name<TAB>tap_to_click").
load_config() {
  local platform=$1 packaged_path=${2:-$packaged} edit=${3:-} home
  home=$(mktemp -d "$tmpdir/home.XXXXXX")
  mkdir -p "$home/.config"
  cp -R "$runtime/config/hypr" "$home/.config/hypr"
  [[ -z $edit ]] || printf '%s\n' "$edit" >>"$home/.config/hypr/input.lua"
  [[ -z ${NO_DEFAULT_BINDINGS:-} ]] || sed -i 's/^-- omarchy_default_bindings = false$/omarchy_default_bindings = false/' "$home/.config/hypr/hyprland.lua"
  HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.local/state" OMARCHY_PATH="$runtime" \
    OMARCHY_PACKAGED_PATH="$packaged_path" PATH="$tmpdir/$platform-bin:$PATH" lua <<'LUA'
local function proxy()
  return setmetatable({}, {
    __index = function(self, key)
      local value = proxy()
      rawset(self, key, value)
      return value
    end,
    __call = function()
      return {}
    end,
  })
end

local dsp = proxy()
rawset(dsp, "exec_cmd", function(cmd) return { cmd = cmd } end)
rawset(dsp, "global", function(name) return { cmd = "global " .. name } end)

hl = setmetatable({
  dsp = dsp,
  bind = function(keys, dispatcher, opts)
    if opts and opts.device then
      print("bind\t" .. keys .. "\tfocus " .. table.concat(opts.device.list, ","))
    elseif type(dispatcher) == "table" and dispatcher.cmd then
      print("bind\t" .. keys .. "\t" .. dispatcher.cmd)
    else
      print("bind\t" .. keys .. "\tother")
    end
  end,
  unbind = function(keys) print("unbind\t" .. keys) end,
  device = function(device) print("device\t" .. device.name .. "\t" .. tostring(device.tap_to_click)) end,
  get_config = function() return nil end,
  get_active_window = function() return nil end,
  get_monitors = function() return {} end,
}, {
  __index = function()
    return function()
      return {}
    end
  end,
})

dofile(os.getenv("HOME") .. "/.config/hypr/hyprland.lua")
LUA
}

apple=$(load_config apple) || fail "the config loads on a Mac with omarchy-mac" "$apple"
other=$(load_config other) || fail "the config loads elsewhere with omarchy-mac on disk" "$other"
bare=$(load_config apple "$tmpdir/none") || fail "the config loads on a Mac without omarchy-mac" "$bare"

bound() { grep -Fxq "bind"$'\t'"$2"$'\t'"$3" <<<"$1"; }

lid_on=("switch:on:Apple SMC power/lid events" "omarchy-system-lid-close")
lid_off=("switch:off:Apple SMC power/lid events" "omarchy-hyprland-monitor-clamshell")
captures=("SUPER + F12|omarchy-capture-screenshot fullscreen" "SUPER + F11|omarchy-capture-screenshot region"
  "SUPER + F10|omarchy-capture-screenshot windows" "SUPER + XF86AudioMute|omarchy-capture-screenshot windows"
  "SUPER + XF86AudioLowerVolume|omarchy-capture-screenshot region" "SUPER + XF86AudioRaiseVolume|omarchy-capture-screenshot fullscreen")

bound "$apple" "${lid_on[@]}" && bound "$apple" "${lid_off[@]}" || fail "a Mac binds its SMC lid switch" "$apple"
for capture in "${captures[@]}"; do
  bound "$apple" "${capture%%|*}" "${capture#*|}" || fail "a Mac binds ${capture%%|*} to capture" "$apple"
done
! grep -q $'^bind\tSUPER + ALT + F12\t' <<<"$apple" || fail "Super+Alt+F12 stays unbound" "$apple"
bound "$apple" "SHIFT + XF86MonBrightnessUp" "omarchy-brightness-keyboard up" &&
  bound "$apple" "SHIFT + XF86MonBrightnessDown" "omarchy-brightness-keyboard down" ||
  fail "Shift+brightness drives a Mac's keyboard backlight" "$apple"
(( $(grep -c $'^bind\tSHIFT + XF86MonBrightnessUp\t' <<<"$apple") == 1 )) ||
  fail "the Mac's Shift+brightness replaces Omarchy's display maximum instead of joining it" "$apple"
grep -Fxq $'device\tapple-mtp-multi-touch\tfalse' <<<"$apple" && grep -Fxq $'device\tapple-spi-trackpad\tfalse' <<<"$apple" ||
  fail "a Mac's built-in trackpad does not tap to click" "$apple"
# A runtime with the settings slot loads settings/apple.lua itself; an older
# one gets it through defaults/apple.lua. Either way each device is set once.
(( $(grep -c $'^device\tapple-spi-trackpad\t' <<<"$apple") == 1 && $(grep -c $'^device\tapple-mtp-multi-touch\t' <<<"$apple") == 1 )) ||
  fail "the Mac's trackpad settings load once" "$apple"
if [[ -f $runtime/default/hypr/platform.lua ]]; then
  trackpad_line=$(grep -n $'^device\tapple-spi-trackpad\t' <<<"$apple" | cut -d: -f1)
  terminal_line=$(grep -n $'^bind\tSUPER + RETURN\t' <<<"$apple" | cut -d: -f1)
  [[ -n $trackpad_line && -n $terminal_line ]] && (( trackpad_line > terminal_line )) ||
    fail "with the settings slot, the Mac's trackpad settings follow Omarchy's defaults" "$apple"
fi
pass "a Mac gets its lid switch, capture chords, keyboard backlight chords and trackpad from omarchy-mac"

tapping=$(load_config apple "$packaged" 'hl.device({ name = "apple-spi-trackpad", tap_to_click = true })') ||
  fail "the config loads with the user's tap-to-click" "$tapping"
[[ $(grep $'^device\tapple-spi-trackpad\t' <<<"$tapping" | tail -n 1) == $'device\tapple-spi-trackpad\ttrue' ]] ||
  fail "the user's input.lua turns tap-to-click back on" "$tapping"
pass "the user's input.lua replaces the Mac's trackpad settings"

for output in "$other" "$bare"; do
  ! grep -q 'Apple SMC\|omarchy-capture-screenshot \(fullscreen\|region\|windows\)$\|SHIFT + XF86MonBrightness.*brightness-keyboard\|^device\|focus apple' <<<"$output" ||
    fail "no Mac default without a Mac or without omarchy-mac" "$output"
  bound "$output" "SHIFT + XF86MonBrightnessUp" "omarchy-brightness-display 100%" || fail "Omarchy's Shift+brightness stays elsewhere" "$output"
  bound "$output" "PRINT" "omarchy-capture-screenshot" || fail "Omarchy's own capture bind stays" "$output"
done
pass "off a Mac, or on a Mac without omarchy-mac, the runtime alone adds nothing of the Mac's"

keyboards="apple-spi-keyboard,apple-mtp-keyboard"
# The runtime binds a menu or panel as a command, or (a runtime whose
# bindings say { menu = ... } and whose shell registers the shortcut) as the
# shell's global shortcut; either comes right after the focus bind.
focus_then() {
  local keys=$1 command
  shift
  for command in "$@"; do
    [[ $'\n'"$apple"$'\n' == *$'\nbind\t'"$keys"$'\tfocus '"$keyboards"$'\nbind\t'"$keys"$'\t'"$command"$'\n'* ]] && return
  done
  fail "$keys focuses the built-in screen first when typed on the MacBook keyboard" "$apple"
}
focus_then "SUPER + SPACE" "omarchy-menu toggle" "global omarchy:menu.root"
focus_then "SUPER + ESCAPE" "omarchy-menu toggle system" "global omarchy:menu.system"
focus_then "SUPER + K" "omarchy-menu-keybindings"
focus_then "SUPER + CTRL + A" "omarchy-shell shell toggle omarchy.audio" "global omarchy:panel.omarchy.audio"
focus_then "SUPER + CTRL + code:10" "omarchy-shell -q shell togglePanelAt right 1"
for keys in "SUPER + RETURN" "SUPER + CTRL + E" "SUPER + CTRL + V" "PRINT" "SUPER + F12" "SUPER + 1"; do
  ! grep -qxF "bind"$'\t'"$keys"$'\tfocus '"$keyboards" <<<"$apple" || fail "$keys keeps today's focus" "$apple"
done
pass "menus and panels typed on the MacBook keyboard focus its screen first; apps, pasting pickers and captures don't"

# A user's rebind goes through the same decoration: a menu keeps the focus
# bind, an app gets none.
rebinds=$(load_config apple "$packaged" $'o.rebind("SUPER + ESCAPE", "System menu", "omarchy-menu toggle system")\no.rebind("SUPER + SHIFT + F", "File manager", "uwsm-app -- flea")') ||
  fail "the config loads with the user's rebinds" "$rebinds"
[[ $rebinds == *$'unbind\tSUPER + ESCAPE\nbind\tSUPER + ESCAPE\tfocus '"$keyboards"$'\nbind\tSUPER + ESCAPE\tomarchy-menu toggle system'* ]] ||
  fail "rebinding a menu keeps the built-in screen focus" "$rebinds"
[[ $rebinds == *$'unbind\tSUPER + SHIFT + F\nbind\tSUPER + SHIFT + F\tuwsm-app -- flea'* ]] ||
  fail "rebinding an app opens it on the focused screen" "$rebinds"
pass "the user's rebinds keep the menu and app split"

grep -qx -- '-- omarchy_default_bindings = false' "$runtime/config/hypr/hyprland.lua" || fail "hyprland.lua documents the default bindings switch"
nodefaults=$(NO_DEFAULT_BINDINGS=1 load_config apple) || fail "the config loads without default bindings" "$nodefaults"
! grep -q 'Apple SMC\|SUPER + F12' <<<"$nodefaults" || fail "omarchy_default_bindings = false drops the Mac's binds too" "$nodefaults"
pass "omarchy_default_bindings = false turns the Mac's binds off with Omarchy's"

# The keybindings menu shows the brightness keys as the F1 and F2 they are.
[[ $(<"$packaged/default/omarchy/platform/key-names") == $'XF86MonBrightnessUp F2\nXF86MonBrightnessDown F1' ]] ||
  fail "omarchy-mac names the brightness keys F2 and F1"
grep -Fq 'default/omarchy/platform/key-names' "$runtime/bin/omarchy-menu-keybindings" || fail "the keybindings menu reads the platform's key names"
pass "the keybindings menu names the Mac's brightness keys as its F-keys"

# The bar keeps clear of each MacBook panel's notch.
PACKAGED="$packaged" RUNTIME="$runtime" node <<'JS'
const fs = require('fs')
const model = require(process.env.RUNTIME + '/shell/plugins/bar/BarModel.js')
const cutouts = model.parseCutouts(fs.readFileSync(process.env.PACKAGED + '/default/shell/platform/display-cutouts.json', 'utf8'))
const expect = (ok, what) => { if (!ok) { console.error('not ok - ' + what); process.exit(1) } }
expect(cutouts.length === 4, 'four MacBook panels')
expect(model.notchFloor(cutouts, 'top', 'eDP-1', 1728, 1117, 2, 0) === 32, '16" MacBook Pro at scale 2: 32 px')
expect(model.notchFloor(cutouts, 'top', 'eDP-1', 1512, 982, 2, 0) === 32, '14" MacBook Pro at scale 2: 32 px')
expect(model.notchFloor(cutouts, 'top', 'eDP-1', 1280, 832, 2, 0) === 28, 'MacBook Air 13.6" at scale 2: 28 px')
expect(model.notchFloor(cutouts, 'top', 'DP-1', 1728, 1117, 2, 0) === 0, 'external monitors keep no floor')
expect(model.notchFloor(cutouts, 'bottom', 'eDP-1', 1728, 1117, 2, 0) === 0, 'a bottom bar keeps no floor')
expect(model.centerBesideRight(cutouts, 'top', 'eDP-1', 1728, 1117, 2), 'the center section moves beside the right')
JS
pass "the bar keeps clear of the notch on every MacBook panel omarchy-mac describes"

# The focus bind moves to the built-in screen only when another screen has it.
focus_with() {
  PATH="$tmpdir/apple-bin:$PATH" lua - "$packaged/default/hypr/platform/defaults/apple.lua" "$1" <<'LUA'
local file, layout = arg[1], arg[2]
local focus
hl = {
  dsp = { focus = function(args) return args end, exec_cmd = function(cmd) return cmd end },
  dispatch = function(dispatcher) print("focus " .. dispatcher.monitor) end,
  device = function() end,
  bind = function(_, dispatcher, opts) if opts and opts.device then focus = dispatcher end end,
  get_monitors = function()
    local monitors = {}
    for name, focused in layout:gmatch("([%w%-]+)(%*?)") do
      monitors[#monitors + 1] = { name = name, focused = focused == "*" }
    end
    return monitors
  end,
}
o = { bind_decorators = {}, bind = function() end, shell_succeeds = function() return true end }
_G.omarchy_default_bindings = false
dofile(file)
o.bind_decorators[1]("SUPER + SPACE", "omarchy-menu toggle", {})
focus()
print("done")
LUA
}
[[ $(focus_with "DP-1* eDP-1") == $'focus eDP-1\ndone' ]] || fail "focus moves to the built-in screen from an external one"
[[ $(focus_with "DP-1 eDP-1*") == "done" ]] || fail "focus stays when the built-in screen already has it"
[[ $(focus_with "DP-1* HDMI-A-1") == "done" ]] || fail "clamshell: no built-in screen, focus stays"
[[ $(focus_with "eDP-1*") == "done" ]] || fail "built-in screen alone: nothing to do"
pass "the built-in screen focus handles external, built-in only and clamshell layouts"

# The decorator reads the command a bind runs: the dispatcher itself when it is
# one, or the command Omarchy passes fourth when the bind reaches the shell
# through its global shortcut.
decorated() {
  PATH="$tmpdir/apple-bin:$PATH" lua - "$packaged/default/hypr/platform/defaults/apple.lua" "$@" <<'LUA'
local file, dispatcher, command = arg[1], arg[2], arg[3]
hl = { device = function() end, bind = function(_, _, opts) if opts and opts.device then print("focus") end end }
o = { bind_decorators = {}, bind = function() end, shell_succeeds = function() return true end }
_G.omarchy_default_bindings = false
dofile(file)
if dispatcher == "global" then
  dispatcher = { global = "omarchy:shortcut" }
end
o.bind_decorators[1]("SUPER + X", dispatcher, {}, command)
LUA
}
[[ $(decorated "omarchy-menu toggle root") == "focus" ]] || fail "a menu command gets the focus bind"
[[ $(decorated global "omarchy-menu toggle 'root'") == "focus" ]] || fail "a menu reached through the shell's shortcut gets the focus bind"
[[ $(decorated "omarchy-menu toggle 'root'" "omarchy-menu toggle 'root'") == "focus" ]] || fail "a menu command passed twice gets the focus bind"
[[ $(decorated global "omarchy-shell shell toggle 'omarchy.audio'") == "focus" ]] || fail "a panel reached through the shell's shortcut gets the focus bind"
[[ -z $(decorated global "omarchy-shell shell toggle 'omarchy.emojis'") ]] || fail "the emoji picker reached through the shortcut keeps today's focus"
[[ -z $(decorated global "omarchy-shell shell toggle 'omarchy.clipboard'") ]] || fail "the clipboard reached through the shortcut keeps today's focus"
[[ -z $(decorated "omarchy-shell shell toggle omarchy.emojis") ]] || fail "the emoji picker command keeps today's focus"
[[ -z $(decorated global "omarchy-launch-browser") ]] || fail "an app keeps today's focus"
[[ -z $(decorated global) ]] || fail "an opaque dispatcher with no command keeps today's focus"
pass "the focus bind follows the command a bind runs, whether it is the dispatcher or passed alongside it"
