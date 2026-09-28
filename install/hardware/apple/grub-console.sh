# Apple boot policy belongs to the independently packaged boot support, which
# hardware setup now runs through the platform setup leaf (setup-boot). This
# shim stays for the image builder, which sources it inside the image, and for
# the hardware queue of an image built before, which runs it by name.
if omarchy-hw-apple-silicon; then
  source "${OMARCHY_MAC_BOOT_LIB:-/usr/lib/omarchy-mac/boot}/setup/grub-console.sh" || return 1
fi
