#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat >"$work/bin/omarchy-hw-apple-silicon" <<'STUB'
#!/bin/bash
[[ ${APPLE:-0} == 1 ]]
STUB
cat >"$work/bin/omarchy-hw-platform" <<'STUB'
#!/bin/bash
if [[ ${APPLE:-0} == 1 ]]; then echo apple-silicon; else echo generic; fi
STUB
cat >"$work/bin/sudo" <<'STUB'
#!/bin/bash
"$@"
STUB
cat >"$work/bin/pacman" <<'STUB'
#!/bin/bash
echo "$*" >>"$CALLS"
if [[ $1 == "-Q" ]]; then
  [[ -e $INSTALLED ]] || exit 1
else
  (( ${PKG_STATUS:-0} == 0 )) || exit "$PKG_STATUS"
  touch "$INSTALLED"
fi
STUB
# The dispatcher resolves omarchy-mac's setup on a Mac and nothing elsewhere.
cat >"$work/bin/omarchy-lifecycle-dispatch" <<'STUB'
#!/bin/bash
if [[ $1 == "--resolve" ]]; then
  [[ ${APPLE:-0} != 1 ]] || echo "/usr/lib/omarchy/mac/$2"
  exit 0
fi
[[ ${APPLE:-0} == 1 ]] || exit 0
echo "dispatch $*" >>"$CALLS"
[[ -z ${SPEAKERS_STARTED:-} ]] || touch "$SPEAKERS_STARTED"
exit "${SETUP_STATUS:-0}"
STUB
cat >"$work/bin/systemctl" <<'STUB'
#!/bin/bash
[[ $1 == is-active ]] && exit "$([[ ${SPEAKERS:-inactive} == active || -e ${SPEAKERS_STARTED:-/nonexistent} ]] && echo 0 || echo 3)"
[[ $1 != is-enabled ]]
STUB
cat >"$work/bin/omarchy-state" <<'STUB'
#!/bin/bash
echo "state $*" >>"$CALLS"
STUB
cat >"$work/bin/omarchy-pkg-present" <<'STUB'
#!/bin/bash
[[ ${AVD:-1} == 1 ]]
STUB
cat >"$work/bin/lspci" <<'STUB'
#!/bin/bash
echo 'Broadcom [14e4:4433]'
STUB
chmod +x "$work/bin/"*
export OMARCHY_PATH="$ROOT" INSTALLED="$work/installed" CALLS="$work/calls" PATH="$work/bin:$PATH"

[[ ! -e $ROOT/bin/omarchy-setup-mac ]] || fail 'the runtime-to-package handover command is gone'
# Each historical migration hands its work to omarchy-mac's setup through the
# dispatcher, in the scope the leaf it used to run had.
for spec in '1789132600 setup-system' '1789140994 setup-system' '1789136143 setup-user' '1789135950 setup-user' \
  '1790326963 setup-user' '1790327183 setup-user' '1789138445 setup-system,setup-user' '1789780917 setup-system,setup-user'; do
  read -r migration scopes <<<"$spec"
  : >"$CALLS"
  APPLE=0 bash -euo pipefail "$ROOT/migrations/$migration.sh" >/dev/null
  [[ ! -s $CALLS ]] || fail "$migration does nothing off Apple Silicon" "$(cat "$CALLS")"
  touch "$INSTALLED"
  APPLE=1 bash -euo pipefail "$ROOT/migrations/$migration.sh" >/dev/null
  [[ $(grep '^dispatch' "$CALLS" | cut -d' ' -f2 | paste -sd,) == "$scopes" ]] ||
    fail "$migration runs omarchy-mac's $scopes" "$(cat "$CALLS")"
done
pass "historical Apple migrations run omarchy-mac's setup through the dispatcher, off Apple Silicon nothing"

for migration in 1789275235 1789780917; do
  rm -f "$INSTALLED"
  : >"$CALLS"
  APPLE=0 bash -euo pipefail "$ROOT/migrations/$migration.sh" >/dev/null
  [[ ! -e $INSTALLED ]] || fail "$migration installs no add-on off Apple Silicon"
  APPLE=1 bash -euo pipefail "$ROOT/migrations/$migration.sh" >/dev/null
  APPLE=1 bash -euo pipefail "$ROOT/migrations/$migration.sh" >/dev/null
  [[ -e $INSTALLED && $(grep -c -- '^-S --needed --noconfirm omarchy-mac$' "$CALLS") == 1 ]] ||
    fail "$migration acquires the add-on once, when it is missing" "$(cat "$CALLS")"
done
: >"$CALLS"
APPLE=1 PKG_STATUS=42 bash -euo pipefail "$ROOT/migrations/1789275235.sh"
! grep -q -- '^-S ' "$CALLS" || fail 'installed add-on must not require a sync repository entry'
rm "$INSTALLED"
status=0
APPLE=1 PKG_STATUS=42 bash -euo pipefail "$ROOT/migrations/1789780917.sh" >/dev/null || status=$?
[[ $status == 42 && ! -e $INSTALLED ]] || fail 'failed installation stays pending'
status=0
APPLE=1 SETUP_STATUS=43 bash -euo pipefail "$ROOT/migrations/1789780917.sh" >/dev/null || status=$?
[[ $status == 43 ]] || fail 'setup failure stays pending after package acquisition'
APPLE=1 bash -euo pipefail "$ROOT/migrations/1789780917.sh" >/dev/null
pass 'Apple-only acquisition and interrupted transition are retryable'

# The packages the video decode and audio repairs installed come with
# omarchy-mac now; each asks for the reboot that brings its stack up.
video=$ROOT/migrations/1789135902.sh audio=$ROOT/migrations/1789136142.sh
for apple in 0 1; do
  for avd in 0 1; do
    : >"$CALLS"
    APPLE=$apple AVD=$avd bash -euo pipefail "$video" >/dev/null
    if (( apple && avd )); then
      [[ $(<"$CALLS") == "state set reboot-required" ]] || fail 'the decoder asks for a reboot once its packages are there' "$(cat "$CALLS")"
    else
      [[ ! -s $CALLS ]] || fail 'no reboot without the decode packages or off Apple Silicon' "$(cat "$CALLS")"
    fi
  done
done
: >"$CALLS"
APPLE=0 bash -euo pipefail "$audio" >/dev/null
[[ ! -s $CALLS ]] || fail 'the audio repair does nothing off Apple Silicon' "$(cat "$CALLS")"
: >"$CALLS"
APPLE=1 SPEAKERS=active bash -euo pipefail "$audio" >/dev/null
[[ $(<"$CALLS") == "dispatch setup-system" ]] || fail 'running speakers need setup but no reboot' "$(cat "$CALLS")"
: >"$CALLS"
APPLE=1 bash -euo pipefail "$audio" >/dev/null
[[ $(<"$CALLS") == $'dispatch setup-system\nstate set reboot-required' ]] || fail 'speakers that were not running ask for a reboot after setup' "$(cat "$CALLS")"
: >"$CALLS"
APPLE=1 SPEAKERS_STARTED="$work/speakers-started" bash -euo pipefail "$audio" >/dev/null
[[ $(<"$CALLS") == $'dispatch setup-system\nstate set reboot-required' ]] ||
  fail 'speakers the setup itself started still ask for a reboot' "$(cat "$CALLS")"
status=0
APPLE=1 SETUP_STATUS=44 bash -euo pipefail "$audio" >/dev/null 2>&1 || status=$?
(( status == 44 )) || fail 'a failed setup keeps the audio repair pending'
pass 'the video decode and audio repairs set up the Mac and ask for the reboot their stacks need'

# Fresh setup no longer calls omarchy-mac from the network leaf: the last
# hardware leaf runs its setup through the dispatcher.
! grep -q 'omarchy-mac' "$ROOT/install/hardware/network.sh" || fail 'the network leaf names no Apple package'
grep -Fxq omarchy-mac "$ROOT/install/omarchy-apple.packages" || fail 'Apple fresh-install inputs require the package'
pass 'fresh Apple installs get omarchy-mac from the Apple list and its setup from the platform leaf'

# The Apple desktop leaves moved into omarchy-mac. What stays in the runtime
# only forwards an image's queued hardware step to the platform leaf.
for leaf in audio video-decode electron-gl; do
  [[ $(grep -v '^#' "$ROOT/install/hardware/apple/$leaf.sh") == 'source "${OMARCHY_INSTALL:-$OMARCHY_PATH/install}/hardware/platform-setup.sh"' ]] ||
    fail "install/hardware/apple/$leaf.sh only forwards a queued step to the platform leaf"
  ! grep -q "hardware/apple/$leaf.sh" "$ROOT/install/hardware/all.sh" || fail "hardware setup no longer runs apple/$leaf.sh"
done
for leaf in touchpad mic electron-gl share-picker browser-video-decode; do
  [[ ! -e $ROOT/install/user/hardware/apple/$leaf.sh ]] && ! grep -rq "user/hardware/apple/$leaf.sh" "$ROOT/install" "$ROOT/bin" "$ROOT/migrations" ||
    fail "the user leaf apple/$leaf.sh is gone with its callers"
done
[[ ! -e $ROOT/default/pacman/apple-silicon/pacman-edge.conf ]] ||
  cmp -s "$ROOT/default/pacman/apple-silicon/pacman-edge.conf" "$ROOT/packages/omarchy-mac/share/omarchy-mac/pacman/pacman-edge.conf" ||
  fail "the runtime's transitional Apple template matches omarchy-mac's"
pass "the runtime keeps no Apple desktop leaf, only forwarders for queued hardware steps"

grep -A4 '^copy_chromium_flags()' "$ROOT/bin/omarchy-install-browser" | grep -Fxq '  omarchy-lifecycle-dispatch setup-user' ||
  fail "a browser install runs the platform's user setup after writing its flags"
! grep -Fq 'AcceleratedVideoDecoder' "$ROOT/config/chromium-flags.conf" ||
  fail "shipped Chromium flags keep hardware decode on for x86 and other ARM"
pass "a browser install hands its fresh flags to the platform's user setup"

list_names() {
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$@"
}
for package in avd-fw libva-v4l2_request-avd; do
  list_names "$ROOT/install/omarchy-apple.packages" | grep -Fxq "$package" ||
    fail "Apple Silicon images install $package from the Apple package list"
  ! list_names "$ROOT/install/omarchy-base.packages" "$ROOT/install/omarchy-other.packages" | grep -Fxq "$package" ||
    fail "$package stays out of the package lists every platform installs"
done
pass "the Apple package list, and only it, carries the decode stack"

grep -Fq 'omarchy-audio-asahi-mic-map --save-state' "$ROOT/bin/omarchy-restart-audio" ||
  fail "audio restart saves Asahi mic mapping gain before resetting daemons"
grep -Fq 'omarchy-hw-apple-silicon && systemctl --user is-enabled --quiet omarchy-asahi-mic.service && systemctl --user start omarchy-asahi-mic.service' "$ROOT/default/hypr/autostart.lua" ||
  fail "session start launches the Asahi mic mapper"
pass "audio restart and session start keep the Asahi mic mapping gated"
