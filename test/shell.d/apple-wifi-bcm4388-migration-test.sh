#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
calls="$test_tmp/calls.log"
installed="$test_tmp/installed"
mkdir -p "$stub_bin" "$test_tmp/omarchy/migrations"

cat >"$stub_bin/omarchy-hw-platform" <<'SH'
#!/bin/bash
[[ ${PLATFORM:-apple-silicon} != "error" ]] || { echo "Error: contradictory platform identity" >&2; exit 1; }
echo "${PLATFORM:-apple-silicon}"
SH

cat >"$stub_bin/omarchy-hw-apple-silicon" <<'SH'
#!/bin/bash
[[ $(omarchy-hw-platform) == "apple-silicon" ]]
SH

cat >"$stub_bin/lspci" <<'SH'
#!/bin/bash
(( ${LSPCI_STATUS:-0} == 0 )) || exit "$LSPCI_STATUS"
echo "01:00.0 Network controller [0280]: Broadcom Inc. Wireless [14e4:${WIFI_ID:-4434}]"
for _ in {1..4096}; do
  echo '02:00.0 Host bridge [0600]: Filler Device [ffff:0000]'
done
SH

cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
echo "sudo $*" >>"$CALLS"
"$@"
SH

# The dispatcher resolves omarchy-mac's system setup while the add-on is installed.
cat >"$stub_bin/omarchy-lifecycle-dispatch" <<'SH'
#!/bin/bash
if [[ $1 == "--resolve" ]]; then
  [[ ! -e $INSTALLED ]] || echo "/usr/lib/omarchy/mac/$2"
  exit 0
fi
echo "omarchy-lifecycle-dispatch $*" >>"$CALLS"
exit "${SETUP_STATUS:-0}"
SH

# The installed add-on's chipset gate: an add-on older than this change answers
# no, and without the add-on there is none.
cat >"$stub_bin/wifi-supported" <<'SH'
#!/bin/bash
[[ -e $INSTALLED && ${ADDON_COVERS_4434:-1} == "1" ]]
SH

chmod +x "$stub_bin"/*

source_migration="$ROOT/migrations/1790327076.sh"
[[ $(stat -c %a "$source_migration") == "644" ]] || fail "the migration is sourced, not executed" "$(stat -c %a "$source_migration")"
[[ $(head -n 1 "$source_migration") == "echo "* ]] || fail "the migration starts with an echo"
migration="$test_tmp/omarchy/migrations/1790327076.sh"
sed "s|/usr/lib/omarchy-mac/wifi-supported|$stub_bin/wifi-supported|" "$source_migration" >"$migration"
grep -Fq "$stub_bin/wifi-supported" "$migration" || fail "the test reaches the add-on's chipset gate"

export CALLS="$calls" INSTALLED="$installed" PATH="$stub_bin:$PATH"

run_migration() {
  : >"$calls"
  bash -euo pipefail "$migration"
}

touch "$installed"
for spec in 'generic 4434' 'generic-aarch64 4434' 'qualcomm 4434' 'apple-silicon 4433' 'apple-silicon 4425' 'apple-silicon 0000'; do
  read -r platform wifi <<<"$spec"
  PLATFORM=$platform WIFI_ID=$wifi run_migration >/dev/null
  [[ ! -s $calls ]] || fail "other platforms and chips never reach sudo" "$spec: $(cat "$calls")"
done
pass "only Apple Silicon Macs with BCM4388 run setup"

for spec in 'PLATFORM=error' 'LSPCI_STATUS=5'; do
  status=0
  env "$spec" bash -euo pipefail "$migration" >/dev/null 2>&1 || status=$?
  (( status != 0 )) || fail "a detection failure keeps the migration pending" "$spec"
done
[[ ! -s $calls ]] || fail "a detection failure changes nothing" "$(cat "$calls")"
pass "a detector or lspci failure keeps the migration pending"

run_migration >/dev/null
grep -Fxq 'sudo omarchy-lifecycle-dispatch setup-system' "$calls" || fail "a BCM4388 Mac runs omarchy-mac's system setup" "$(cat "$calls")"
! grep -Fq 'setup-user' "$calls" || fail "the migration leaves user setup alone" "$(cat "$calls")"
pass "a BCM4388 Mac with the add-on runs system setup only"

rm "$installed"
status=0
run_migration >/dev/null 2>&1 || status=$?
(( status != 0 )) && ! grep -q 'sudo' "$calls" || fail "without the add-on the migration stays pending, asking for no root" "$(cat "$calls")"
touch "$installed"
pass "a BCM4388 Mac without the add-on stays pending until migration 1789780917 installs it"

status=0
SETUP_STATUS=43 run_migration >/dev/null 2>&1 || status=$?
(( status == 43 )) || fail "a setup failure fails the migration" "$status"
pass "a setup failure fails the migration"

# Through the runner: an add-on that predates BCM4388 keeps the migration pending until it is updated.
export OMARCHY_PATH="$test_tmp/omarchy" OMARCHY_MIGRATION_STATE="$test_tmp/state"
marker="$OMARCHY_MIGRATION_STATE/1790327076.sh"
status=0
ADDON_COVERS_4434=0 "$ROOT/bin/omarchy-migrate" >"$test_tmp/out" 2>&1 || status=$?
(( status != 0 )) && [[ ! -e $marker ]] || fail "an old add-on leaves the migration pending" "$(cat "$test_tmp/out")"
grep -q 'does not cover BCM4388' "$test_tmp/out" || fail "the pending migration says why" "$(cat "$test_tmp/out")"
[[ $("$ROOT/bin/omarchy-migrate" --pending) == "1790327076.sh" ]] || fail "the runner lists the migration as pending"
"$ROOT/bin/omarchy-migrate" >"$test_tmp/out" 2>&1 || fail "the updated add-on completes the migration" "$(cat "$test_tmp/out")"
[[ -e $marker ]] || fail "the completed migration is marked"
pass "an add-on that predates BCM4388 keeps the migration pending until it is updated"
