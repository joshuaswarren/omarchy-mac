echo "Install the protected Asahi audio stack on Apple Silicon"

# The speaker stack comes with omarchy-mac now, which this update installed,
# and its system setup presets speakersafetyd. WirePlumber reads the protected
# graph only at startup, so where the daemon was not running before this setup
# a reboot applies both without briefly exposing the raw speakers. The resolve
# is an assignment so an undetermined platform fails the migration instead of
# skipping it.
omarchy-hw-apple-silicon || exit 0
speakers_before=inactive
systemctl is-active --quiet speakersafetyd.service && speakers_before=active
entrypoint=$(omarchy-lifecycle-dispatch --resolve setup-system)
if [[ -n $entrypoint ]]; then
  sudo omarchy-lifecycle-dispatch setup-system
fi
[[ $speakers_before == "active" ]] || omarchy-state set reboot-required
