#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# omarchy-steam-fex is the Apple Silicon launcher (muvm and FEX). omarchy-mac's
# setup installs and prepares it; the Steam installer and the migration for
# existing Steam installs reach that setup through the dispatcher, which does
# nothing on other platforms.
installer="$ROOT/bin/omarchy-install-gaming-steam"
migration="$ROOT/migrations/1789522888.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stub_bin="$test_tmp/bin"
calls="$test_tmp/calls.log"
mkdir -p "$stub_bin" "$test_tmp/home"

cat >"$stub_bin/omarchy-pkg-add" <<'SH'
#!/bin/bash
printf 'omarchy-pkg-add %s\n' "$*" >>"$TEST_LOG"
SH
cat >"$stub_bin/omarchy-hw-apple-silicon" <<'SH'
#!/bin/bash
[[ $TEST_PLATFORM == "apple-silicon" ]]
SH
cat >"$stub_bin/omarchy-lifecycle-dispatch" <<'SH'
#!/bin/bash
if [[ $1 == "--resolve" ]]; then
  [[ $TEST_PLATFORM != "apple-silicon" ]] || echo "/usr/lib/omarchy/mac/$2"
  exit 0
fi
[[ $TEST_PLATFORM == "apple-silicon" ]] || exit 0
printf 'dispatch %s\n' "$*" >>"$TEST_LOG"
SH
cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
printf 'sudo ' >>"$TEST_LOG"
"$@"
SH
cat >"$stub_bin/omarchy-pkg-present" <<'SH'
#!/bin/bash
case $1 in
  steam) [[ ${STEAM:-0} == 1 ]] ;;
  omarchy-steam-fex) [[ ${FEX:-0} == 1 ]] ;;
  *) exit 1 ;;
esac
SH
for command_name in omarchy-install-gaming-gpu-lib32 setsid; do
  printf '#!/bin/bash\nexit 0\n' >"$stub_bin/$command_name"
done
chmod +x "$stub_bin"/*

run_on() {
  local platform="$1"
  shift
  : >"$calls"
  TEST_PLATFORM="$platform" TEST_LOG="$calls" HOME="$test_tmp/home" PATH="$stub_bin:$PATH" "$@" >/dev/null
}

run_on apple-silicon bash "$installer"
[[ $(<"$calls") == $'omarchy-pkg-add steam\nsudo dispatch setup-system\ndispatch setup-user' ]] ||
  fail "Apple Silicon installs Steam, then omarchy-mac's setup adds and prepares the FEX launcher" "$(cat "$calls")"
pass "the Steam installer hands Apple Silicon's FEX launcher to omarchy-mac's setup"

for platform in qualcomm generic-aarch64 generic; do
  run_on "$platform" bash "$installer"
  [[ $(<"$calls") == 'omarchy-pkg-add steam' ]] || fail "$platform installs plain Steam" "$(cat "$calls")"
done
! grep -q 'omarchy-hw-apple-silicon\|omarchy-steam-fex' "$installer" || fail "the Steam installer has no Apple branch"
pass "the Steam installer keeps the Apple FEX launcher off other platforms"

run_on apple-silicon bash -euo pipefail "$migration"
[[ ! -s $calls ]] || fail "the migration leaves a Mac without Steam alone" "$(cat "$calls")"
STEAM=1 run_on apple-silicon bash -euo pipefail "$migration"
[[ $(<"$calls") == $'omarchy-pkg-add omarchy-steam-fex\ndispatch setup-user' ]] ||
  fail "the migration adds the launcher to existing Apple Silicon Steam installs, then omarchy-mac's user setup" "$(cat "$calls")"
STEAM=1 FEX=1 run_on apple-silicon bash -euo pipefail "$migration"
[[ $(<"$calls") == 'dispatch setup-user' ]] || fail "an installed launcher is not added again" "$(cat "$calls")"
mkdir -p "$test_tmp/home/.local/share/Steam"
run_on apple-silicon bash -euo pipefail "$migration"
[[ $(<"$calls") == $'omarchy-pkg-add omarchy-steam-fex\ndispatch setup-user' ]] ||
  fail "a Steam library without the package gets the launcher, which brings Steam" "$(cat "$calls")"
rm -rf "$test_tmp/home/.local/share/Steam"
for platform in qualcomm generic-aarch64 generic; do
  STEAM=1 run_on "$platform" bash -euo pipefail "$migration"
  [[ ! -s $calls ]] || fail "the migration leaves $platform alone" "$(cat "$calls")"
done
pass "the migration adds the launcher to existing Apple Silicon Steam installs and runs omarchy-mac's user setup"
