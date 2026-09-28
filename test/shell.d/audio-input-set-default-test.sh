#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

cat >"$work/bin/wpctl" <<'SH'
#!/bin/bash
printf 'wpctl %s\n' "$*" >>"$CALLS"
SH
cat >"$work/bin/pactl" <<'SH'
#!/bin/bash
printf 'pactl %s\n' "$*" >>"$CALLS"
[[ $* == "list source-outputs" ]] && cat "$OUTPUTS"
exit 0
SH
chmod +x "$work/bin/wpctl" "$work/bin/pactl"

moved() {
  grep '^pactl move-source-output ' "$CALLS" | awk '{ print $3 }' | tr '\n' ' '
}

export CALLS="$work/calls" OUTPUTS="$work/outputs"

# Apple Silicon: asahi-audio's microphone DSP captures the raw array through its
# own source output. Choosing an input must not move it onto that input.
cat >"$OUTPUTS" <<'OUT'
Source Output #67
	Driver: PipeWire
	Properties:
		node.name = "audio_effect.j416-mic"
		media.name = "MacBook Pro J416 Microphone"
Source Output #90
	Driver: PipeWire
	Properties:
		application.name = "Firefox"
		node.name = "Firefox"
OUT
: >"$CALLS"
PATH="$work/bin:$PATH" "$ROOT/bin/omarchy-audio-input-set-default" 113 omarchy_asahi_mic
grep -qx 'wpctl set-default 113' "$CALLS" || fail 'input set-default selects the node'
grep -qx 'pactl set-default-source omarchy_asahi_mic' "$CALLS" || fail 'input set-default names the default source'
[[ $(moved) == "90 " ]] || fail 'input set-default moves apps but not the Apple microphone DSP capture' "$(moved)"
pass 'input set-default moves apps but not the Apple microphone DSP capture'

# Everywhere else every recording moves, as before, whatever its properties.
cat >"$OUTPUTS" <<'OUT'
Source Output #12
	Properties:
		application.name = "OBS"
Source Output #13
	Properties:
		node.name = "native-recorder"
Source Output #14
	Properties:
		node.name = "audio_effect.j416-mic-copy"
OUT
: >"$CALLS"
PATH="$work/bin:$PATH" "$ROOT/bin/omarchy-audio-input-set-default" 43 alsa_input.pci-0000_00_1f.3.analog-stereo
[[ $(moved) == "12 13 14 " ]] || fail 'input set-default still moves every other recording' "$(moved)"
pass 'input set-default still moves every other recording'
