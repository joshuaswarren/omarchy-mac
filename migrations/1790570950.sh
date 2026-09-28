echo "Remove the Intel Mac Broadcom quirk from anywhere in a Mac's brcmfmac.conf"

# An unguarded 1786391100 appended it on Apple Silicon, where it breaks Wi-Fi,
# and 1789172112 only took the block off the end of the file on two chips.
# omarchy-mac's system setup removes the line wherever it is and records the
# initramfs rebuild it owes. A failed detector keeps the migration pending.
platform=$(omarchy-hw-platform)
[[ $platform == "apple-silicon" ]] || exit 0

conf="${OMARCHY_BRCMFMAC_CONF:-/etc/modprobe.d/brcmfmac.conf}"
pending="${OMARCHY_BRCMFMAC_PENDING:-/var/lib/omarchy/migrations/1789172112-initramfs-pending}"
quirk="options brcmfmac feature_disable=0x82000"

if [[ -f $conf ]] && grep -Fxq -- "$quirk" "$conf"; then
  entrypoint=$(omarchy-lifecycle-dispatch --resolve setup-system)
  if [[ -n $entrypoint ]]; then
    sudo omarchy-lifecycle-dispatch setup-system
  fi
  # Nothing changed: stay pending without stopping the update.
  if [[ -f $conf ]] && grep -Fxq -- "$quirk" "$conf"; then
    if [[ -L $conf ]]; then
      echo "$conf is a link: remove the line \"$quirk\" where it points, then reboot." >&2
    else
      echo "The installed omarchy-mac does not remove \"$quirk\" from $conf yet; update again to finish." >&2
    fi
    exit 75
  fi
  omarchy-state set reboot-required
fi

[[ -f $pending ]] || exit 0
omarchy-state set reboot-required
sudo mkinitcpio -P
sudo rm -- "$pending"
