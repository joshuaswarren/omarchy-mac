#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

dns="$ROOT/bin/omarchy-dns"
hardware_network="$ROOT/install/hardware/network.sh"

! grep -F 'systemd-networkd' "$dns" >/dev/null || fail "omarchy-dns no longer restarts systemd-networkd"
grep -F 'NetworkManager/conf.d/20-omarchy-dns.conf' "$dns" >/dev/null
grep -F '[global-dns-domain-*]' "$dns" >/dev/null
grep -F 'ipv4.ignore-auto-dns yes' "$dns" >/dev/null
grep -F 'ipv4.ignore-auto-dns no' "$dns" >/dev/null
grep -F 'nmcli device reapply' "$dns" >/dev/null
grep -F 'nmcli general reload conf' "$dns" >/dev/null
grep -F 'nmcli general reload dns-full' "$dns" >/dev/null
if grep -F 'nmcli general reload conf,dns-full' "$dns" >/dev/null; then
  fail "omarchy-dns must not push DNS before reapplying active profiles"
fi
pass "omarchy-dns configures DNS through NetworkManager"

grep -F 'systemd-networkd.service' "$hardware_network" >/dev/null
grep -F 'systemd-networkd.socket' "$hardware_network" >/dev/null
grep -F '20-wlan.network' "$hardware_network" >/dev/null
grep -F 'omarchy-networkd-retired' "$hardware_network" >/dev/null
pass "hardware setup retires archinstall networkd state"

# Apple Silicon's iwd backend is omarchy-mac's, set up by the platform leaf
# that ends hardware setup; the network leaf keeps no Apple branch.
! grep -Eq 'omarchy-hw-apple-silicon|omarchy-mac' "$hardware_network" || fail 'the network leaf has no Apple branch'
! grep -F 'install -Dm644 /dev/stdin' "$hardware_network" >/dev/null || fail 'Wi-Fi configuration is package-owned'
[[ $(grep '^run_logged' "$ROOT/install/hardware/all.sh" | tail -n 1) == 'run_logged "$OMARCHY_INSTALL/hardware/platform-setup.sh"' ]] ||
  fail 'the platform setup ends hardware setup'
pass "hardware setup leaves Apple Silicon's iwd backend to omarchy-mac's setup"
