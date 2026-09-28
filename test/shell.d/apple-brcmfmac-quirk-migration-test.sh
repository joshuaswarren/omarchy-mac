#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

# Migration 1790570950 hands the Intel Mac Broadcom quirk's removal to
# omarchy-mac's system setup, then rebuilds the initramfs it recorded.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state"
export OMARCHY_BRCMFMAC_CONF="$tmp/brcmfmac.conf" OMARCHY_BRCMFMAC_PENDING="$tmp/state/pending" TEST_LOG="$tmp/log"
export PATH="$tmp/bin:$PATH" PLATFORM=apple-silicon SETUP=removes RESOLVES=1 REBUILD_FAIL=0
cat >"$tmp/bin/sudo" <<'STUB'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$TEST_LOG"
"$@"
STUB
cat >"$tmp/bin/omarchy-hw-platform" <<'STUB'
#!/bin/bash
[[ $PLATFORM != "fail" ]] || exit 1
echo "$PLATFORM"
STUB
cat >"$tmp/bin/omarchy-lifecycle-dispatch" <<'STUB'
#!/bin/bash
if [[ $1 == "--resolve" ]]; then
  (( RESOLVES )) && echo /usr/lib/omarchy/mac/setup-system
  exit 0
fi
echo "dispatch $*" >>"$TEST_LOG"
if [[ $SETUP == "removes" && ! -L $OMARCHY_BRCMFMAC_CONF ]]; then
  touch "$OMARCHY_BRCMFMAC_PENDING"
  sed -i '/^options brcmfmac feature_disable=0x82000$/d' "$OMARCHY_BRCMFMAC_CONF"
fi
STUB
cat >"$tmp/bin/omarchy-state" <<'STUB'
#!/bin/bash
echo "state $*" >>"$TEST_LOG"
STUB
cat >"$tmp/bin/mkinitcpio" <<'STUB'
#!/bin/bash
(( ! REBUILD_FAIL ))
STUB
chmod +x "$tmp/bin/"*
run() { bash -euo pipefail "$ROOT/migrations/1790570950.sh" >"$tmp/out" 2>"$tmp/err"; }
reset() { rm -f "$OMARCHY_BRCMFMAC_CONF" "$OMARCHY_BRCMFMAC_PENDING" "$tmp/target"; : >"$TEST_LOG"; }
quirk='options brcmfmac feature_disable=0x82000'

reset
printf 'options brcmfmac roamoff=1\n%s\n' "$quirk" >"$OMARCHY_BRCMFMAC_CONF"
PLATFORM=generic run
[[ ! -s $TEST_LOG ]] || fail 'a machine that is not a Mac is untouched'
if PLATFORM=fail run; then fail 'a failed detector keeps the migration pending'; fi
run
grep -qx 'dispatch setup-system' "$TEST_LOG" && grep -qx 'state set reboot-required' "$TEST_LOG" &&
  grep -qx 'sudo mkinitcpio -P' "$TEST_LOG" || fail 'setup removes the quirk, and the initramfs is rebuilt' "$(cat "$TEST_LOG")"
[[ ! -e $OMARCHY_BRCMFMAC_PENDING && $(<"$OMARCHY_BRCMFMAC_CONF") == 'options brcmfmac roamoff=1' ]] ||
  fail 'the rebuild obligation is cleared once done'
: >"$TEST_LOG"
run
[[ ! -s $TEST_LOG ]] || fail 'a second run is a no-op'
reset
run
[[ ! -s $TEST_LOG ]] || fail 'no file, nothing to do'
pass 'Apple gate, removal through setup, rebuild and idempotence'

# An omarchy-mac that doesn't remove it yet, or none at all: nothing changed,
# so the migration stays pending without stopping the update.
for spec in 'keeps 1' 'removes 0'; do
  read -r SETUP RESOLVES <<<"$spec"
  reset
  printf '%s\n' "$quirk" >"$OMARCHY_BRCMFMAC_CONF"
  status=0
  SETUP=$SETUP RESOLVES=$RESOLVES run || status=$?
  (( status == 75 )) && grep -q 'update again to finish' "$tmp/err" && ! grep -q 'reboot-required' "$TEST_LOG" ||
    fail "setup that leaves the quirk defers: $spec" "status $status"
done
SETUP=removes RESOLVES=1
reset
printf '%s\n' "$quirk" >"$tmp/target"
ln -s "$tmp/target" "$OMARCHY_BRCMFMAC_CONF"
status=0
run || status=$?
(( status == 75 )) && grep -q 'is a link' "$tmp/err" && [[ -L $OMARCHY_BRCMFMAC_CONF ]] || fail 'a link defers with the manual fix' "status $status"
pass 'a quirk setup could not remove defers with the fix'

# A rebuild owed from an earlier run, or one that fails and stays owed.
reset
touch "$OMARCHY_BRCMFMAC_PENDING"
run
[[ ! -e $OMARCHY_BRCMFMAC_PENDING ]] && grep -qx 'sudo mkinitcpio -P' "$TEST_LOG" || fail 'an owed rebuild is finished'
reset
printf '%s\n' "$quirk" >"$OMARCHY_BRCMFMAC_CONF"
if REBUILD_FAIL=1 run; then fail 'a failed rebuild fails the migration'; fi
[[ -f $OMARCHY_BRCMFMAC_PENDING ]] || fail 'a failed rebuild stays owed'
run
[[ ! -e $OMARCHY_BRCMFMAC_PENDING ]] || fail 'the retry finishes the rebuild'
pass 'the rebuild obligation survives a failure and is finished on retry'
