echo "Enable hardware video decode on Apple Silicon"

# avd-fw and libva-v4l2_request-avd are Apple list defaults an owner may remove,
# not omarchy-mac dependencies, so a Mac set up before the list named them gets
# them here. The apple-avd driver requests its firmware once, when it probes at
# boot, so a reboot is what turns the decoder on.
omarchy-hw-apple-silicon || exit 0
omarchy-pkg-missing avd-fw libva-v4l2_request-avd || exit 0
omarchy-pkg-available avd-fw libva-v4l2_request-avd || exit 0
omarchy-pkg-add avd-fw libva-v4l2_request-avd
omarchy-state set reboot-required
