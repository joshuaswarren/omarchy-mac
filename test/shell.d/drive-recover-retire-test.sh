#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The migration that retires the password reset with the recovery key: a Mac
# an earlier owner setup armed loses both units and their enablement links,
# once, and a Mac never armed needs no sudo.
migration=$ROOT/migrations/1790572431.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/sudo" <<'SH'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$TEST_TMP/sudo-calls"
[[ $1 == systemctl ]] || exec "$@"
SH
chmod +x "$tmp/bin/sudo"
export PATH="$tmp/bin:$PATH" TEST_TMP=$tmp OMARCHY_SYSTEMD_UNIT_DIR=$tmp/units

run_migration() {
  : >"$tmp/sudo-calls"
  bash -euo pipefail "$migration" >/dev/null 2>&1
}

run_migration || fail "the migration succeeds where nothing was armed"
[[ ! -s $tmp/sudo-calls ]] || fail "a Mac never armed runs no sudo" "$(cat "$tmp/sudo-calls")"

mkdir -p "$tmp/units/multi-user.target.wants"
for unit in omarchy-drive-recover-check.service omarchy-drive-recover.service; do
  printf '[Unit]\n' >"$tmp/units/$unit"
  ln -s "../$unit" "$tmp/units/multi-user.target.wants/$unit"
done
printf '[Unit]\n' >"$tmp/units/other.service"
run_migration || fail "the migration retires an armed reset"
[[ -z $(find "$tmp/units" -name 'omarchy-drive-recover*') && -f $tmp/units/other.service ]] ||
  fail "both units and their links are gone, and nothing else" "$(find "$tmp/units")"
grep -qx 'sudo systemctl daemon-reload' "$tmp/sudo-calls" || fail "systemd reloads after the units go" "$(cat "$tmp/sudo-calls")"
run_migration || fail "the migration runs again for another user"
[[ ! -s $tmp/sudo-calls ]] || fail "a retired Mac needs no sudo for the next user" "$(cat "$tmp/sudo-calls")"

rm -f "$tmp/units/other.service"
ln -s ../omarchy-drive-recover-check.service "$tmp/units/multi-user.target.wants/omarchy-drive-recover-check.service"
run_migration || fail "the migration removes a dangling link"
[[ -z $(find "$tmp/units" -name 'omarchy-drive-recover*') ]] || fail "a dangling enablement link is removed" "$(find "$tmp/units")"
pass "the migration retires an armed password reset once, dangling links included, and needs no sudo where nothing is armed"
