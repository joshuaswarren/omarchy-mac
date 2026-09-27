#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"

# update-takeover, which omarchy-lifecycle-dispatch runs before an update moves
# aside files no package owns: the Mac's boot chain, initramfs and pacman
# configuration refuse the whole takeover; anything else may go.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$ROOT/install" "$work/root"
takeover=$work/root/usr/lib/omarchy/mac-boot/update-takeover
[[ -x $takeover && $(stat -c %a "$takeover") == 755 ]] || fail 'the update-takeover entrypoint is staged for omarchy-lifecycle-dispatch'

"$takeover" || fail 'no path, nothing to refuse'
"$takeover" /usr/share/omarchy/default/foo /etc/xdg/omarchy.conf /usr/bin/omarchy-new ||
  fail 'files outside the platform paths may be taken over'
for path in /boot /boot/efi/limine.conf /etc/default/grub /etc/grub/themes/x /etc/limine/x /etc/mkinitcpio.conf \
  /etc/mkinitcpio.conf.d/omarchy_hooks.conf /etc/modprobe.d/omarchy-usb-autosuspend.conf /etc/pacman.conf /etc/pacman.d/mirrorlist \
  /etc/systemd/oomd.conf.d/10-omarchy.conf /etc/tmpfiles.d/omarchy-zswap.conf /usr/lib/initcpio/install/x \
  /usr/lib/systemd/user/app.slice.d/10-oomd.conf /usr/lib/systemd/zram-generator.conf.d/90-omarchy.conf; do
  status=0
  output=$("$takeover" /usr/share/omarchy/ok "$path" 2>&1) || status=$?
  (( status == 1 )) && [[ $output == "Refusing to replace Apple Silicon platform path: $path" ]] ||
    fail "a platform path refuses the whole takeover: $path" "status $status: $output"
done
pass 'the boot chain, initramfs and pacman configuration refuse the takeover; other files may go'
