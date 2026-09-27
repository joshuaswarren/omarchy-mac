echo "Enable hardware video decode on Apple Silicon"

# avd-fw and libva-v4l2_request-avd come with omarchy-mac now, which this
# update installed. The apple-avd driver requests its firmware once, when it
# probes at boot, so a reboot is what turns the decoder on.
omarchy-hw-apple-silicon || exit 0
if omarchy-pkg-present avd-fw libva-v4l2_request-avd; then
  omarchy-state set reboot-required
fi
