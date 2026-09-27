echo "Install wf-recorder where this platform's default packages name it, so screen recording works on Macs"

# Apple Silicon records with wf-recorder, which Mac installs made before it was
# in the Apple package list do not have. A failed lookup fails the migration
# rather than marking it done.
defaults=$(omarchy-pkg-defaults)

if grep -Fxq wf-recorder <<<"$defaults" && omarchy-pkg-missing wf-recorder; then
  omarchy-pkg-add wf-recorder
fi
