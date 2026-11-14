echo "Set the display backlight from the ambient light sensor"

# install/user/first-run only runs on the first login, so existing installs
# enable the unit here. It stays inert without a light sensor.
systemctl --user daemon-reload >/dev/null 2>&1 || true

# `systemctl enable` needs a live user manager, which an update from a TTY does
# not have, so fall back to writing the symlink it would have written.
if ! systemctl --user enable omarchy-brightness-auto.service >/dev/null 2>&1; then
  wants_dir="$HOME/.config/systemd/user/graphical-session.target.wants"
  mkdir -p "$wants_dir"
  ln -sfn /usr/lib/systemd/user/omarchy-brightness-auto.service \
    "$wants_dir/omarchy-brightness-auto.service"
fi

if systemctl --user is-active --quiet graphical-session.target; then
  systemctl --user start omarchy-brightness-auto.service >/dev/null 2>&1 || true
fi
