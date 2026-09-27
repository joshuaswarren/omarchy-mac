#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
acpi_lid="$test_tmp/acpi/button/lid"
input_class="$test_tmp/input"
dmi_chassis="$test_tmp/chassis_type"
mkdir -p "$stub_bin" "$acpi_lid/LID0" "$input_class/input0" "$input_class/input1"

cat >"$stub_bin/busctl" <<'SH'
#!/bin/bash
printf '%s\n' "${OMARCHY_TEST_LID_STATE:-}"
SH
chmod +x "$stub_bin/busctl"

run_laptop() {
  OMARCHY_DMI_CHASSIS_TYPE_PATH="$dmi_chassis" \
    OMARCHY_ACPI_LID_PATH="$acpi_lid" \
    OMARCHY_INPUT_CLASS_PATH="$input_class" \
    PATH="$stub_bin:$PATH" \
    "$ROOT/bin/omarchy-hw-laptop"
}

run_lid_closed() {
  OMARCHY_ACPI_LID_PATH="$acpi_lid" \
    PATH="$stub_bin:$PATH" \
    OMARCHY_TEST_LID_STATE="$1" \
    "$ROOT/bin/omarchy-hw-laptop-closed"
}

# No ACPI lid, no evdev lid, desktop chassis: a Mac mini / Studio / PC tower.
: >"$acpi_lid/LID0/state"
rm -f "$acpi_lid/LID0/state"
printf '3\n' >"$dmi_chassis"
printf 'Power Button\n' >"$input_class/input0/name"
printf 'Apple SMC\n' >"$input_class/input1/name"
if run_laptop; then
  fail "a desktop without a lid is not classified as a laptop"
fi
pass "a desktop without a lid is not classified as a laptop"

# Apple Silicon MacBook: no ACPI, no DMI, but the SMC lid switch is present.
printf 'Apple SMC power/lid events\n' >"$input_class/input1/name"
run_laptop || fail "an Apple SMC lid switch is classified as a laptop"
pass "an Apple SMC lid switch is classified as a laptop"

printf 'Lid Switch\n' >"$input_class/input1/name"
run_laptop || fail "a generic evdev lid switch is classified as a laptop"
pass "a generic evdev lid switch is classified as a laptop"

# x86 laptop via DMI when ACPI and evdev lids are absent.
printf 'Power Button\n' >"$input_class/input1/name"
printf '9\n' >"$dmi_chassis"
run_laptop || fail "DMI laptop chassis is recognized when ACPI is absent"
pass "DMI laptop chassis is recognized when ACPI is absent"

printf '3\n' >"$dmi_chassis"
if run_laptop; then
  fail "a desktop DMI chassis is not classified as a laptop"
fi
pass "a desktop DMI chassis is not classified as a laptop"

printf 'closed\n' >"$acpi_lid/LID0/state"
run_laptop || fail "an ACPI lid is classified as a laptop"
pass "an ACPI lid is classified as a laptop"

run_lid_closed not-a-property ||
  fail "the ACPI fallback recognizes a closed lid"
pass "the ACPI fallback recognizes a closed lid"

printf 'open\n' >"$acpi_lid/LID0/state"
if run_lid_closed not-a-property; then
  fail "the ACPI fallback recognizes an open lid"
fi
pass "the ACPI fallback recognizes an open lid"

run_lid_closed 'b true' ||
  fail "logind recognizes a closed lid"
pass "logind recognizes a closed lid"

if run_lid_closed 'b false'; then
  fail "logind recognizes an open lid"
fi
pass "logind recognizes an open lid"

rm -f "$acpi_lid/LID0/state"
run_lid_closed 'b true' ||
  fail "logind remains authoritative when ACPI is absent"
pass "logind remains authoritative when ACPI is absent"

bindings="$ROOT/default/hypr/bindings/utilities.lua"
grep -F 'switch:on:Lid Switch' "$bindings" >/dev/null ||
  fail "lid-close still binds the generic lid switch"
grep -F 'switch:off:Lid Switch' "$bindings" >/dev/null ||
  fail "clamshell still binds the generic lid switch"
pass "Hyprland binds the generic lid switch (omarchy-mac binds the Apple SMC one; see apple-platform-hooks-test.sh)"
