echo "Recover Wi-Fi after resume on Apple Silicon Macs"

# The Broadcom firmware on Apple Silicon Macs (BCM4378/BCM4387) can wedge
# across s2idle, leaving Wi-Fi able to scan but rejecting every association
# until the driver is reloaded. Fresh installs get the recovery service from
# the hardware leaf; run the same leaf here for existing installs.

omarchy-hw-apple-silicon || exit 0
# grep without -q reads all of lspci's output: this runs under pipefail, where
# an early -q exit would kill a chatty lspci with SIGPIPE and read the failed
# pipeline as "no such hardware".
lspci -nn | grep -E "14e4:(4425|4433)" >/dev/null || exit 0

if systemctl is-enabled --quiet omarchy-wifi-resume-fix.service 2>/dev/null; then
  exit 0
fi

# omarchy-mac's system setup enables the recovery service. The resolve is an
# assignment so an undetermined platform fails the migration instead of
# skipping it.
entrypoint=$(omarchy-lifecycle-dispatch --resolve setup-system)
if [[ -n $entrypoint ]]; then
  sudo omarchy-lifecycle-dispatch setup-system
fi
