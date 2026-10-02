#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
require_command python3
require_command pacman-conf

# Every platform's repositories are a pacman.conf and mirrorlist per channel,
# copied into place whole on a channel change and at install finalization, as
# x86_64's always were.

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export OMARCHY_PATH="$ROOT"
source "$ROOT/install/helpers/pacman.sh"

platforms="generic qualcomm generic-aarch64 apple-silicon"

# ── the templates ────────────────────────────────────────────────────────────

[[ $(omarchy_pacman_templates generic) == "$ROOT/default/pacman" ]] || fail "x86 keeps its templates where they were"
[[ $(omarchy_pacman_templates qualcomm) == "$ROOT/default/pacman/aarch64" ]] || fail "Snapdragon uses the aarch64 templates"
[[ $(omarchy_pacman_templates generic-aarch64) == "$ROOT/default/pacman/aarch64" ]] || fail "generic aarch64 uses the aarch64 templates"
[[ $(omarchy_pacman_templates apple-silicon) == "$ROOT/default/pacman/apple-silicon" ]] || fail "Apple Silicon uses its own templates"
! omarchy_pacman_templates riscv 2>/dev/null || fail "an unknown platform has no templates"
pass "each platform's templates sit in a directory of their own, x86_64's where they always were"

# pacman reads each repository list from the template, with its mirrorlist
# standing in for /etc/pacman.d/mirrorlist.
repos() {
  local templates=$1 channel=$2
  sed "s|/etc/pacman.d/mirrorlist|$templates/mirrorlist-$channel|" "$templates/pacman-$channel.conf" >"$work/pacman.conf"
  pacman-conf --config "$work/pacman.conf" --repo-list | tr '\n' ' '
}
for platform in $platforms; do
  templates=$(omarchy_pacman_templates "$platform")
  for channel in stable rc edge; do
    [[ -f $templates/pacman-$channel.conf && -f $templates/mirrorlist-$channel ]] ||
      fail "$platform has a $channel template and mirrorlist"
    list=$(repos "$templates" "$channel") || fail "$platform $channel: pacman reads the template"
    case $platform in
      generic) expected="core extra multilib omarchy " ;;
      qualcomm | generic-aarch64) expected="core extra alarm aur omarchy " ;;
      apple-silicon) expected="omarchy asahi-alarm core extra alarm aur " ;;
    esac
    [[ $list == "$expected" ]] || fail "$platform $channel: repositories in order" "$list"
    # $arch stays literal: pacman fills it in on the machine.
    server=$(sed -n '/^\[omarchy\]/,/^\[/s/^Server = //p' "$templates/pacman-$channel.conf")
    # aarch64 packages are published on edge alone so far.
    omarchy_channel=$channel
    [[ $platform == "generic" ]] || omarchy_channel=edge
    [[ $server == "https://pkgs.omarchy.org/$omarchy_channel/\$arch" ]] ||
      fail "$platform $channel: Omarchy's $omarchy_channel repository" "$server"
  done
done
pass "every platform has a template and mirrorlist for every channel, with its repositories in order"

# ── install finalization ─────────────────────────────────────────────────────

finalize_bin=$work/finalize-bin
mkdir -p "$finalize_bin"
printf '#!/bin/bash\necho "$PLATFORM"\n' >"$finalize_bin/omarchy-hw-platform"
for command in omarchy-pkg-add pacman-key; do
  printf '#!/bin/bash\nexit 0\n' >"$finalize_bin/$command"
done
chmod +x "$finalize_bin"/*
sed "s|/etc/pacman|$work/etc/pacman|g" "$ROOT/install/post-install/pacman.sh" >"$work/finalize.sh"
mkdir -p "$work/install/hardware"
: >"$work/install/hardware/pacman.sh"

# Finalization asks the image helper whether this is an image build, which root
# answers from the real /var/lib/omarchy; everyone else from the test's root.
if (( EUID == 0 )); then
  skip "install finalization copies the platform's channel template and mirrorlist (refuses to run as root)"
else
for platform in $platforms; do
  templates=$(omarchy_pacman_templates "$platform")
  for channel in stable rc edge; do
    rm -rf "$work/etc"
    mkdir -p "$work/etc/pacman.d"
    printf 'offline\n' | tee "$work/etc/pacman.conf" >"$work/etc/pacman.d/mirrorlist"
    OMARCHY_IMAGE_ROOT=$work OMARCHY_MIRROR=$channel PLATFORM=$platform OMARCHY_INSTALL="$work/install" PATH="$finalize_bin:$PATH" \
      bash -e -c 'source "$1"' bash "$work/finalize.sh" >/dev/null || fail "$platform finalization on $channel"
    cmp -s "$work/etc/pacman.conf" "$templates/pacman-$channel.conf" || fail "$platform $channel: finalization copies the template"
    cmp -s "$work/etc/pacman.d/mirrorlist" "$templates/mirrorlist-$channel" || fail "$platform $channel: finalization copies the mirrorlist"
  done
done
pass "install finalization copies the platform's channel template and mirrorlist"
fi

# ── refresh through the command, with every privileged step a stand-in ───────

rm -rf "$work"
source "$SHELL_TEST_DIR/fixtures/sudo-boundary-test.sh"
copy_boundary_file bin/omarchy-refresh-pacman

refresh() {
  "$SUDO_TEST_ROOT/bin/omarchy-refresh-pacman" "$@" >"$boundary_tmp/output" 2>&1
}
events() {
  grep -vE '^sudo (-h|-k)$' "$SUDO_TEST_LOG" || true
}

for platform in $platforms; do
  case $platform in
    generic) templates=$SUDO_TEST_ROOT/default/pacman ;;
    qualcomm | generic-aarch64) templates=$SUDO_TEST_ROOT/default/pacman/aarch64 ;;
    apple-silicon) templates=$SUDO_TEST_ROOT/default/pacman/apple-silicon ;;
  esac
  for channel in stable rc edge; do
    reset_boundary
    SUDO_TEST_PLATFORM=$platform refresh "$channel" || fail "$platform refreshes to $channel" "$(cat "$boundary_tmp/output")"
    python3 - "$SUDO_TEST_LOG" "$templates" "$channel" <<'PY'
import sys
events = [e for e in open(sys.argv[1]).read().splitlines() if e not in ('sudo -h', 'sudo -k')]
templates, channel = sys.argv[2:]
expected = [
  'step:cp -f /etc/pacman.conf /etc/pacman.conf.bak',
  'step:cp -f /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak',
  f'step:cp -f {templates}/pacman-{channel}.conf /etc/pacman.conf',
  f'step:cp -f {templates}/mirrorlist-{channel} /etc/pacman.d/mirrorlist',
]
copies = [e for e in events if e.startswith('step:cp ')]
assert copies == expected, events
hook = events.index('step:omarchy-hook pre-refresh-pacman')
transaction = events.index('step:pacman -Syyuu --noconfirm')
assert events.index(expected[-1]) < hook < transaction, events
PY
    assert_boundary_cold "$platform $channel"
  done
done
pass "a refresh backs up and copies the platform's channel template and mirrorlist, then runs the cold hook and the upgrade"

# A channel the platform has no template for, or a machine whose platform can't
# be told, stops before anything changes.
rm "$SUDO_TEST_ROOT/default/pacman/aarch64/pacman-rc.conf"
reset_boundary
if SUDO_TEST_PLATFORM=qualcomm refresh rc; then fail "a channel without a template is refused"; fi
[[ -z $(events) ]] || fail "a channel without a template stops before anything" "$(events)"
grep -q "Omarchy has no rc channel for qualcomm" "$boundary_tmp/output" || fail "the refusal says why" "$(cat "$boundary_tmp/output")"
assert_boundary_cold "missing template"
cat >"$SUDO_TEST_ROOT/bin/omarchy-hw-platform" <<'STUB'
#!/bin/bash
exit 1
STUB
reset_boundary
if refresh stable; then fail "an unknown platform is refused"; fi
[[ -z $(events) ]] || fail "an unknown platform stops before anything" "$(events)"
assert_boundary_cold "unknown platform"
pass "a channel without a template, or a machine whose platform can't be told, changes nothing"
