#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
iio="$test_tmp/iio"
level_file="$test_tmp/level"
writes="$test_tmp/writes"
runtime="$test_tmp/runtime"
mkdir -p "$mock_bin" "$iio" "$runtime"

cat >"$mock_bin/omarchy-hw-display" <<'SH'
#!/bin/bash
echo panel
SH

# A backlight holding one percentage, read and set as brightnessctl does.
cat >"$mock_bin/brightnessctl" <<SH
#!/bin/bash
[[ \$1 == "-d" && \$2 == "panel" ]] || exit 1
case "\$3" in
-m) level=\$(cat "$level_file"); echo "panel,backlight,\$((level * 10)),\$level%,1000" ;;
set) echo "\${4%\\%}" >"$level_file"; echo "\$4" >>"$writes" ;;
*) exit 1 ;;
esac
SH
chmod +x "$mock_bin/omarchy-hw-display" "$mock_bin/brightnessctl"

auto="$test_tmp/omarchy-brightness-auto"
sed -e "s|/sys/bus/iio/devices|$iio|g" "$ROOT/bin/omarchy-brightness-auto" >"$auto"
chmod +x "$auto"

run_auto() {
  PATH="$mock_bin:$PATH" XDG_RUNTIME_DIR="$runtime" "$auto" --once
}

# Fresh backlight, sensor and state for each case.
reset() {
  rm -rf "${iio:?}"/* "${runtime:?}"/* "$writes"
  echo "$1" >"$level_file"
}

sensor() {
  mkdir -p "$iio/iio:device$1"
  echo "$2" >"$iio/iio:device$1/in_illuminance_input"
}

level() {
  cat "$level_file"
}

reset 50
run_auto
[[ ! -e $writes ]] || fail "no light sensor leaves the backlight alone"
pass "no light sensor leaves the backlight alone"

reset 50
sensor 0 0
run_auto
[[ $(level) == "5" ]] || fail "a dark room dims the backlight to 5% (got $(level))"
reset 50
sensor 0 1000
run_auto
[[ $(level) == "100" ]] || fail "1000 lux sets the backlight to 100% (got $(level))"
reset 50
sensor 0 5000
run_auto
[[ $(level) == "100" ]] || fail "light past 1000 lux stays at 100% (got $(level))"
reset 50
sensor 0 12.5
run_auto
[[ $(level) == "41" ]] || fail "a fractional lux reading is used (got $(level))"
pass "the backlight follows the light from 5% in the dark to 100% at 1000 lux"

# A sensor that cannot be read, as a driver without calibration returns ENODATA.
reset 50
mkdir -p "$iio/iio:device0/in_illuminance_input"
run_auto
[[ ! -e $writes ]] || fail "an unreadable sensor leaves the backlight alone"
sensor 1 1000
run_auto
[[ $(level) == "100" ]] || fail "a readable second sensor is used after an unreadable one (got $(level))"
pass "an unreadable sensor leaves the backlight alone"

# 30 lux maps to 52%: a 2% difference is noise, not worth a visible step.
reset 50
sensor 0 30
echo "50 0" >"$runtime/omarchy-brightness-auto.state"
run_auto
[[ ! -e $writes ]] || fail "a small difference from the curve is not written (wrote $(cat "$writes"))"
pass "a small difference from the curve is not written"

# The user turned the backlight up to 70% at 30 lux: keep that choice, and
# carry it as an offset when the room goes dark (5% + 18).
reset 70
sensor 0 30
echo "50 0" >"$runtime/omarchy-brightness-auto.state"
run_auto
[[ ! -e $writes ]] || fail "a level the user just set is kept (wrote $(cat "$writes"))"
sensor 0 0
run_auto
[[ $(level) == "23" ]] || fail "the user's offset follows the light down (got $(level))"
pass "a level the user sets is kept as an offset from the curve"

# A corrupt state file counts as no state.
reset 50
sensor 0 0
echo "garbage" >"$runtime/omarchy-brightness-auto.state"
run_auto
[[ $(level) == "5" ]] || fail "a corrupt state file is ignored (got $(level))"
pass "a corrupt state file is ignored"
