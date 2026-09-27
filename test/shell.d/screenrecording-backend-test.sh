#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

require_command jq

work=$(mktemp -d)
cleanup() {
  local pid
  for pid in "$work"/*/runtime/omarchy-screenrecord-pid; do
    [[ -s $pid ]] && kill "$(<"$pid")" 2>/dev/null || true
  done
  if [[ -e $work/state-before ]]; then
    cp -p "$work/state-before" "$state"
  elif [[ -n ${state:-} ]]; then
    rm -f "$state"
  fi
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/bin"
stub() {
  printf '#!/bin/bash\n%s\n' "$2" >"$work/bin/$1"
  chmod +x "$work/bin/$1"
}

# The recorder each platform uses is in its default packages, so images, the
# reinstall and the migration engine install it.
export OMARCHY_PATH="$ROOT"
"$ROOT/bin/omarchy-pkg-defaults" apple-silicon | grep -Fxq wf-recorder || fail "Apple Silicon's default packages carry wf-recorder"
generic=$("$ROOT/bin/omarchy-pkg-defaults" generic)
grep -Fxq gpu-screen-recorder <<<"$generic" || fail "x86_64's default packages carry gpu-screen-recorder"
! grep -Fxq wf-recorder <<<"$generic" || fail "x86_64's default packages are unchanged"
pass "each platform's default packages carry the recorder it uses"

# Existing installs get wf-recorder where their defaults name it.
migration="$ROOT/migrations/1790504252.sh"
stub omarchy-pkg-defaults '[[ $OMARCHY_TEST_DEFAULTS != fail ]] || exit 23; printf "%s\n" $OMARCHY_TEST_DEFAULTS'
stub omarchy-pkg-missing '[[ $OMARCHY_TEST_MISSING == 1 ]]'
stub omarchy-pkg-add 'echo "pkg-add $*" >>"$OMARCHY_TEST_CALLS"; [[ ${OMARCHY_TEST_ADD_FAILS:-0} != 1 ]]'
# $1: default packages, or "fail"; $2: 1 when wf-recorder is missing. Prints
# what the migration installed and its exit status.
migrate() {
  local status=0
  : >"$work/calls"
  OMARCHY_TEST_DEFAULTS="$1" OMARCHY_TEST_MISSING="$2" OMARCHY_TEST_CALLS="$work/calls" \
    PATH="$work/bin:$PATH" bash -euo pipefail "$migration" >/dev/null 2>&1 || status=$?
  printf '%s%s\n' "$(<"$work/calls")" "status=$status"
}
[[ $(migrate "gpu-screen-recorder wf-recorder" 1) == "pkg-add wf-recorderstatus=0" ]] || fail "the migration installs a missing wf-recorder"
[[ $(migrate "gpu-screen-recorder wf-recorder" 0) == "status=0" ]] || fail "the migration leaves an installed wf-recorder alone"
[[ $(migrate "gpu-screen-recorder" 1) == "status=0" ]] || fail "the migration installs nothing where the defaults do not name wf-recorder"
pass "the migration installs wf-recorder only where the defaults name it and it is missing"

[[ $(migrate fail 1) != *status=0 ]] || fail "a failed defaults lookup fails the migration, so it runs again"
[[ $(OMARCHY_TEST_ADD_FAILS=1 migrate "wf-recorder" 1) != *status=0 ]] || fail "a failed install fails the migration, so it runs again"
pass "the migration is not marked done when the lookup or the install fails"

# The script keeps its filename state at a fixed /tmp name, which a recording
# in progress on this machine owns.
if "$ROOT/bin/omarchy-capture-screenrecording-process"; then
  pass "a screen recording is in progress here; skipping the recorder runs"
  exit 0
fi
state=/tmp/omarchy-screenrecord-filename
[[ ! -e $state ]] || cp -p "$state" "$work/state-before"

stub omarchy-hw-apple-silicon '[[ $OMARCHY_TEST_PLATFORM == apple-silicon ]]'
stub omarchy-hyprland-monitor-focused 'echo eDP-1'
stub hyprctl "echo '[{\"focused\":true,\"width\":3024,\"height\":1890}]'"
stub pactl '[[ $1 == get-default-sink ]] && echo speakers'
stub omarchy-shell ':'
stub omarchy-notification-send ':'
# Each recorder logs its arguments, creates the file it was given and records
# until the test ends.
recorder='printf "%s\n" "$@" >"$OMARCHY_TEST_LOG/$(basename "$0")"
for arg in "$@"; do
  [[ -n ${next:-} ]] && { : >"$arg"; break; }
  [[ $arg == "$OUTPUT_FLAG" ]] && next=1
done
exec sleep 30'
stub wf-recorder "OUTPUT_FLAG=-f; $recorder"
stub gpu-screen-recorder "OUTPUT_FLAG=-o; $recorder"

# $1: platform. Starts a fullscreen recording with desktop audio and prints the
# recorder that ran.
record() {
  local run="$work/$1"
  mkdir -p "$run/runtime" "$run/videos" "$run/log"
  HOME="$run" XDG_RUNTIME_DIR="$run/runtime" OMARCHY_SCREENRECORD_DIR="$run/videos" \
    OMARCHY_TEST_PLATFORM="$1" OMARCHY_TEST_LOG="$run/log" PATH="$work/bin:$ROOT/bin:$PATH" \
    "$ROOT/bin/omarchy-capture-screenrecording" --fullscreen --with-desktop-audio >/dev/null 2>&1 ||
    fail "$1: the recording starts"
  [[ -s $run/runtime/omarchy-screenrecord-pid ]] || fail "$1: the recorder pid is kept for stop"
  ls "$run/log"
}

[[ $(record apple-silicon) == "wf-recorder" ]] || fail "Apple Silicon records with wf-recorder alone" "$(ls "$work/apple-silicon/log")"
args=$(<"$work/apple-silicon/log/wf-recorder")
grep -Fxq -- '-o' <<<"$args" && grep -Fxq eDP-1 <<<"$args" || fail "wf-recorder records the focused monitor" "$args"
grep -Fxq -- '-R' <<<"$args" && grep -Fxq 48000 <<<"$args" || fail "wf-recorder writes 48 kHz audio" "$args"
grep -Fxq -- '--audio=speakers.monitor' <<<"$args" || fail "wf-recorder records the desktop from the default sink's monitor" "$args"
pass "Apple Silicon records the focused monitor with wf-recorder at 48 kHz"

[[ $(record generic) == "gpu-screen-recorder" ]] || fail "x86_64 records with gpu-screen-recorder alone" "$(ls "$work/generic/log")"
pass "x86_64 still records with gpu-screen-recorder"
