# Pacman repository templates. Every platform has a pacman.conf and mirrorlist
# per channel, copied into place whole, as x86_64's always were: x86_64's in
# default/pacman, each ARM platform's in a directory of its own. Sourcing this
# file only defines functions; it never changes the system.

# The directory holding <platform>'s pacman-<channel>.conf and
# mirrorlist-<channel>. A channel without both files isn't offered there.
omarchy_pacman_templates() {
  case ${1:-} in
    generic) echo "$OMARCHY_PATH/default/pacman" ;;
    qualcomm | generic-aarch64) echo "$OMARCHY_PATH/default/pacman/aarch64" ;;
    apple-silicon) echo "$OMARCHY_PATH/default/pacman/apple-silicon" ;;
    *)
      echo "Error: Unknown platform '${1:-}'." >&2
      return 1
      ;;
  esac
}
