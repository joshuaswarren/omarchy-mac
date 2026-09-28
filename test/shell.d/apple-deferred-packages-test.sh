#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# An image defers hardware setup to the Mac's first boot, which is often offline,
# and images ship no pacman sync databases. So no hardware step may install a
# package on a Mac: what every Mac needs comes as omarchy-mac's dependencies, and
# the Apple list's defaults come with the image.

# Reaches a Mac only with the accessory plugged in, and builds DKMS modules for
# the running kernel, so it needs the network anyway. speaker-tuning.sh is not
# listed either: its tunings match on DMI, which a Mac does not have.
accessory_steps=(install/hardware/fix-elgato-camlink-4k.sh)

while IFS= read -r step; do
  grep -q 'omarchy-hw-apple-silicon' "$ROOT/$step" && grep -q 'omarchy-pkg-add' "$ROOT/$step" || continue
  [[ " ${accessory_steps[*]} " == *" $step "* ]] ||
    fail "$step installs packages on Apple Silicon: make them omarchy-mac dependencies or Apple list defaults"
done < <(sed -n 's|^run_logged "\$OMARCHY_INSTALL/\(hardware/[^"]*\)"$|install/\1|p' "$ROOT/install/hardware/all.sh")
pass "no Apple hardware step installs packages, except for accessories"

# The image also carries the tool that picks the startup volume from Linux.
OMARCHY_PATH="$ROOT" "$ROOT/bin/omarchy-pkg-defaults" apple-silicon | grep -Fxq asahi-bless ||
  fail "the Apple default set carries asahi-bless"
pass "the Apple default set carries asahi-bless"
