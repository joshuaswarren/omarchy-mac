echo "Migrate completed Apple setup to the omarchy-mac package"

omarchy-hw-apple-silicon || exit 0
# Migrations run in the update terminal. Acquire from the configured signed
# repository; do not silently fall back to an AUR recipe or change trust.
if ! pacman -Q omarchy-mac >/dev/null 2>&1; then
  sudo env OMARCHY_UPDATE_PACMAN=1 pacman -S --needed --noconfirm omarchy-mac
fi
# omarchy-mac's system and user setup take over from the runtime's. The
# resolve is an assignment so an undetermined platform fails the migration
# instead of skipping it.
entrypoint=$(omarchy-lifecycle-dispatch --resolve setup-system)
if [[ -n $entrypoint ]]; then
  sudo omarchy-lifecycle-dispatch setup-system
fi
omarchy-lifecycle-dispatch setup-user
