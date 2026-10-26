#!/bin/bash

source "$(dirname "$0")/base-test.sh"

# Keep the real read/exit path; desktop commands must not affect this session.
hyprctl() { return 0; }
stty() { return 0; }
tty() { printf '/dev/test\n'; }
ttfx() { return 0; }
pgrep() { return 0; }
pkill() { return 0; }
export -f hyprctl stty tty ttfx pgrep pkill

output=$(printf '\033[<0;10;10M' | timeout 3 bash "$ROOT/bin/omarchy-screensaver") ||
  fail "mouse input reaches the screensaver exit path"
[[ $output == *$'\033[?1000h\033[?1006h'* ]] ||
  fail "the screensaver enables mouse reporting"
[[ $output == *$'\033[?1000l\033[?1006l'* ]] ||
  fail "mouse input exits and disables mouse reporting"
pass "mouse input exits the screensaver and resets mouse reporting"
