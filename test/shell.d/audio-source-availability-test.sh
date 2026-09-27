#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

cat >"$work/bin/pactl" <<'SH'
#!/bin/bash
printf '%s %s\n' "${LC_ALL:-unset}" "$*" >>"$CALLS"
case $* in
  "list sources") cat "$SOURCES" ;;
  "list sinks") cat "$SINKS" ;;
esac
SH
cat >"$work/bin/omarchy-audio-tuning" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$work/bin/pactl" "$work/bin/omarchy-audio-tuning"
export CALLS="$work/calls" SOURCES="$work/sources" SINKS="$work/sinks"

# A Mac's headset jack input with nothing plugged in, the mic mapping (no
# ports) and a DSP source (one available port).
cat >"$SOURCES" <<'OUT'
Source #1074
	Name: alsa_input.platform-sound.HiFi__Headset__source
	Ports:
		[In] Headset: Headset Microphone (type: Headset, priority: 300, availability group: Headset Mic, not available)
	Active Port: [In] Headset
	Formats:
		pcm
Source #126
	Name: omarchy_asahi_mic
	Formats:
		pcm
Source #1102
	Name: effect_output.j416-mic
	Ports:
		[In] Mic: Microphone (type: Mic, priority: 100, availability unknown)
	Active Port: [In] Mic
OUT
cat >"$SINKS" <<'OUT'
Sink #57
	Name: alsa_output.platform-sound.HiFi__Headphones__sink
	Ports:
		[Out] Headphones: Headphones (type: Headphones, priority: 300, availability group: Headphone, not available)
	Active Port: [Out] Headphones
OUT

: >"$CALLS"
expected=$'alsa_input.platform-sound.HiFi__Headset__source\t0\nomarchy_asahi_mic\t1\neffect_output.j416-mic\t1'
actual=$(PATH="$work/bin:$PATH" "$ROOT/bin/omarchy-audio-sink-availability" sources)
[[ $actual == "$expected" ]] || fail 'source availability reports an empty jack input unavailable' "$actual"
grep -qx 'C list sources' "$CALLS" || fail 'source availability reads pactl in the C locale' "$(cat "$CALLS")"
pass 'source availability reports an empty jack input unavailable'

: >"$CALLS"
actual=$(LC_ALL= PATH="$work/bin:$PATH" "$ROOT/bin/omarchy-audio-sink-availability")
[[ $actual == $'alsa_output.platform-sound.HiFi__Headphones__sink\t0' ]] || fail 'sink availability is unchanged' "$actual"
grep -qx 'unset list sinks' "$CALLS" || fail 'sink availability keeps the caller locale' "$(cat "$CALLS")"
pass 'sink availability is unchanged'
