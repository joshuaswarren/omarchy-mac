#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"
require_command lua
lua - "$ROOT" <<'LUA'
local root = arg[1]
local devices = 0
local config
hl = {
  config = function(value) config = value end,
  device = function() devices = devices + 1 end,
}
o = { window = function() end }
dofile(root .. "/default/hypr/input.lua")
assert(config.input.touchpad.tap_to_click == nil, "no global tap override")
assert(config.input.touchpad.natural_scroll == false, "traditional scrolling")
assert(devices == 0, "the runtime overrides no device; a platform package's defaults may")
LUA
pass "the shipped touchpad default overrides no device"

default_input="$ROOT/default/hypr/input.lua"
user_input="$ROOT/config/hypr/input.lua"

# Apple Silicon applies natural_scroll from a user leaf; x86 stays traditional.
grep -Fq 'natural_scroll = false,' "$default_input" ||
  fail "shipped touchpad default uses traditional scrolling"
pass "shipped touchpad default uses traditional scrolling"

grep -Fq -- '--       natural_scroll = true,' "$user_input" ||
  fail "user override example documents natural scrolling"
pass "user override example documents natural scrolling"

