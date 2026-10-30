echo "Install omarchy-ane, the Apple Neural Engine tools, on Apple Silicon Macs"

# New Apple installs get it from the package set; this brings the Macs that
# were installed before it was added. Idempotent: a Mac that has it is left
# alone, and anything that is not an Apple Silicon Mac exits before pacman.

omarchy-hw-aarch64-apple || exit 0
omarchy-pkg-present omarchy-ane && exit 0

omarchy-pkg-add omarchy-ane
