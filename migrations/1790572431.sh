echo "Retire the password reset with the disk recovery key; a recovery key a Mac already has stays a second disk password"

# Owner setup no longer gives a disk a recovery key, and omarchy-drive-recover
# is gone. A Mac an earlier setup armed still has its two units in the unit
# directory, and the check would fail at every boot. Another user's run may
# have removed them already; then this one needs no sudo.
unit_dir=${OMARCHY_SYSTEMD_UNIT_DIR:-/etc/systemd/system}
paths=()
for unit in omarchy-drive-recover-check.service omarchy-drive-recover.service; do
  for path in "$unit_dir/multi-user.target.wants/$unit" "$unit_dir/$unit"; do
    if [[ -e $path || -L $path ]]; then
      paths+=("$path")
    fi
  done
done

if (( ${#paths[@]} )); then
  sudo rm -f "${paths[@]}"
  sudo systemctl daemon-reload
fi
