echo "Enable the Asahi notch strip so the bar can use the full panel height"

# omarchy-mac's system setup retires the old notch file and ships the module
# default; this runs it on Macs set up before. The resolve is an assignment so
# an undetermined platform fails the migration instead of skipping it.
omarchy-hw-apple-silicon || exit 0
entrypoint=$(omarchy-lifecycle-dispatch --resolve setup-system)
if [[ -n $entrypoint ]]; then
  sudo omarchy-lifecycle-dispatch setup-system
fi
