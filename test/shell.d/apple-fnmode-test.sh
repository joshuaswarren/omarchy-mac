#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

leaf="$ROOT/install/hardware/fix-fkeys.sh"
migration="$ROOT/migrations/1790327324.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
calls="$test_tmp/calls.log"
conf="$test_tmp/hid_apple.conf"
state="$test_tmp/state"
mkdir -p "$stub_bin" "$state"

cat >"$stub_bin/omarchy-hw-apple-silicon" <<'SH'
#!/bin/bash
[[ ${APPLE_SILICON:-0} == "1" ]]
SH

cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
printf 'sudo' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
"$@"
SH

cat >"$stub_bin/omarchy-mac-setup-keyboard" <<'SH'
#!/bin/bash
exit "${SETUP_KEYBOARD_STATUS:-0}"
SH

cat >"$stub_bin/omarchy-brightness-keyboard" <<'SH'
#!/bin/bash
printf 'keyboard %s\n' "$*"
SH

cat >"$stub_bin/omarchy-brightness-display" <<'SH'
#!/bin/bash
printf 'display %s\n' "$*"
SH

chmod +x "$stub_bin"/*

run_leaf() {
  APPLE_SILICON="${1:-0}" OMARCHY_HID_APPLE_CONF="$conf" PATH="$stub_bin:$PATH" \
    TEST_LOG="$calls" bash -c 'source "$1"' _ "$leaf"
}

run_migration() {
  APPLE_SILICON="${1:-0}" OMARCHY_MIGRATION_STATE="$state" \
    PATH="$stub_bin:$PATH" TEST_LOG="$calls" \
    bash -euo pipefail "$migration"
}

rm -f "$conf"
run_leaf 0
[[ $(<"$conf") == "options hid_apple fnmode=2" ]] ||
  fail "x86 install still writes fnmode=2" "$(cat "$conf")"
pass "x86 install still writes fnmode=2"

rm -f "$conf"
: >"$calls"
run_leaf 1
[[ ! -e $conf && ! -s $calls ]] || fail "Apple Silicon install leaves the keyboard mode to omarchy-mac"
pass "Apple Silicon install leaves the keyboard mode to omarchy-mac"

printf 'options hid_apple fnmode=0\n' >"$conf"
run_leaf 0
[[ $(<"$conf") == "options hid_apple fnmode=0" ]] ||
  fail "install leaves an existing hid_apple.conf alone"
pass "install leaves an existing hid_apple.conf alone"

: >"$calls"
run_migration 0 >/dev/null
[[ ! -s $calls ]] || fail "the keyboard migration is a no-op off Apple Silicon"
pass "the keyboard migration is a no-op off Apple Silicon"

for spec in ': 2' '1789132067 1' '1790305681 3'; do
  read -r fork generated <<<"$spec"
  rm -f "$state"/*
  [[ $fork == : ]] || touch "$state/$fork.sh"
  : >"$calls"
  run_migration 1 >/dev/null
  [[ $(<"$calls") == $'sudo\tomarchy-mac-setup-keyboard\t'"$generated" ]] ||
    fail "the keyboard migration names fnmode=$generated as generated after $fork" "$(cat "$calls")"
done
pass "the keyboard migration names the line each fork generated"

if SETUP_KEYBOARD_STATUS=1 run_migration 1 >/dev/null; then
  fail "a failed keyboard setup fails the migration so it retries"
fi
pass "a failed keyboard setup fails the migration so it retries"

matches=$(grep -l 'fnmode' "$ROOT"/migrations/*.sh)
[[ $matches == "$migration" ]] ||
  fail "one migration changes the keyboard mode, so an update rebuilds the boot image once" "$matches"
pass "one migration changes the keyboard mode, so an update rebuilds the boot image once"
