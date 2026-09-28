echo "Wrap Electron apps when Apple Silicon has no render GPU"

# omarchy-mac's system setup wraps the launchers and its user setup repairs the
# user's desktop entries; this runs both on Macs set up before. The resolve is
# an assignment so an undetermined platform fails the migration instead of
# skipping it.
entrypoint=$(omarchy-lifecycle-dispatch --resolve setup-system)
if [[ -n $entrypoint ]]; then
  sudo omarchy-lifecycle-dispatch setup-system
fi
omarchy-lifecycle-dispatch setup-user
