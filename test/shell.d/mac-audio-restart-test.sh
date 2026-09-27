#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat >"$work/bin/fixture" <<'STUB'
#!/bin/bash
name=${0##*/}
printf '%s %s\n' "$name" "$*" >>"$CALLS"
case $name in
  omarchy-hw-apple-silicon) [[ ${APPLE:-1} == 1 ]] ;;
  omarchy-cmd-present) [[ ${MAPPER_PRESENT:-1} == 1 ]] ;;
  omarchy-audio-asahi-mic-map) exit "${SAVE_STATUS:-0}" ;;
  systemctl)
    case $2 in
      restart) exit "${RESTART_STATUS:-0}" ;;
      *) exit 0 ;;
    esac ;;
  wpctl|sleep) exit 0 ;;
  quickshell) echo 'No running instances for "/usr/share/omarchy/shell/shell.qml"' ;;
esac
STUB
chmod +x "$work/bin/fixture"
for name in omarchy-cmd-present omarchy-hw-apple-silicon omarchy-audio-asahi-mic-map systemctl wpctl sleep quickshell; do
  ln -s fixture "$work/bin/$name"
done
export CALLS="$work/calls" PATH="$work/bin:$PATH" OMARCHY_PATH=/usr/share/omarchy
run_case() {
  : >"$CALLS"
  env "$@" "$ROOT/bin/omarchy-restart-audio" >"$work/output" 2>&1
}
run_case
python - "$CALLS" <<'PY'
import sys
calls=open(sys.argv[1]).read().splitlines()
save=calls.index('omarchy-audio-asahi-mic-map --save-state')
restart=calls.index('systemctl --user restart wireplumber.service pipewire.service pipewire-pulse.service')
assert save < restart,calls
assert calls.count('omarchy-audio-asahi-mic-map --save-state')==1
PY
pass 'Apple restart saves package-owned microphone state before daemon teardown'
for setting in MAPPER_PRESENT=0 APPLE=0; do
  run_case "$setting"
  ! grep -Fq 'omarchy-audio-asahi-mic-map ' "$CALLS" || fail 'unavailable or inapplicable mapper must not run'
  grep -Fxq 'systemctl --user restart wireplumber.service pipewire.service pipewire-pulse.service' "$CALLS" || fail 'optional mapping must not skip daemon recovery'
  ! grep -Eq 'command not found|Could not save microphone' "$work/output" || fail 'absent optional mapper must not warn'
done
pass 'other hardware and Apple installs without the add-on keep normal audio recovery'
run_case SAVE_STATUS=44
grep -Fq 'Could not save microphone mapping gain' "$work/output" || fail 'state-saving failure is reported'
grep -Fxq 'systemctl --user restart wireplumber.service pipewire.service pipewire-pulse.service' "$CALLS" || fail 'broken mapper must not block daemon recovery'
run_case RESTART_STATUS=42
grep -Fq 'systemctl --user kill ' "$CALLS" || fail 'existing forced recovery remains available'
grep -Fxq 'systemctl --user start pipewire.service pipewire-pulse.service wireplumber.service' "$CALLS" || fail 'forced recovery starts audio daemons again'
pass 'state-saving and restart failures retain the existing recovery path'
