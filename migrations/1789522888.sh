echo "Install the packaged Steam FEX launcher on existing Apple Silicon Steam installs"

# Existing Steam installs, or a Steam library without the package, get the
# launcher (which brings Steam with it) whatever omarchy-mac this Mac has yet;
# omarchy-mac's user setup then prepares Steam's desktop entry for it.
omarchy-hw-apple-silicon || exit 0
omarchy-pkg-present steam || [[ -d $HOME/.local/share/Steam ]] || exit 0
omarchy-pkg-present omarchy-steam-fex || omarchy-pkg-add omarchy-steam-fex
omarchy-lifecycle-dispatch setup-user
