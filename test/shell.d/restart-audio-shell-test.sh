#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
require_command jq
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/state"

# One stub for every command the restart touches. The shell, the lock screen
# and the clocks keep their state in $STATE so a case can follow them through.
cat >"$work/bin/fixture" <<'STUB'
#!/bin/bash
name=${0##*/}
printf '%s %s\n' "$name" "$*" >>"$CALLS"
signal_script() {
  # Our parent is `timeout`; its parent is omarchy-restart-audio.
  kill "-$1" "$(awk '{ print $4 }' "/proc/$PPID/stat")"
}
case $name in
  quickshell)
    case $1 in
      list)
        [[ ${LIST_FAIL:-0} == 1 ]] && exit 1
        count=$(cat "$STATE/instances")
        if (( count == 0 )); then
          printf 'No running instances for "%s/shell/shell.qml"\nUse --all to list all instances.\n' "$OMARCHY_PATH"
        else
          jq -n --argjson count "$count" '[range($count) | {pid: .}]'
        fi ;;
      kill)
        [[ ${SHELL_STUCK:-0} == 1 ]] || echo 0 >"$STATE/instances" ;;
    esac ;;
  omarchy-restart-shell)
    [[ ${RESTART_SHELL_STATUS:-0} == 0 ]] || exit "$RESTART_SHELL_STATUS"
    echo 1 >"$STATE/instances" ;;
  omarchy-hyprland-session-locked) exit "${SESSION_LOCKED:-1}" ;;
  omarchy-shell)
    case $2 in
      status)
        [[ ${LOCK_STATUS:-} == "fail" ]] && exit 1
        free='{"secure":false,"requested":false}'
        if [[ -e $STATE/locked ]]; then
          echo '{"secure":true,"requested":false}'
        else
          echo "${LOCK_STATUS:-$free}"
        fi ;;
      lock) touch "$STATE/locked" ;;
    esac ;;
  python3)
    # A suspend shows as CLOCK_BOOTTIME pulling ahead of CLOCK_MONOTONIC.
    if [[ ${SUSPEND:-0} == 1 && -e $STATE/offset ]]; then echo 65.25; else echo 5.25; fi
    touch "$STATE/offset" ;;
  systemctl)
    if [[ $2 == "restart" ]]; then
      [[ -n ${SIGNAL_DURING_RESTART:-} ]] && signal_script "$SIGNAL_DURING_RESTART"
      exit "${RESTART_STATUS:-0}"
    fi ;;
  wpctl) exit "${WPCTL_STATUS:-0}" ;;
  omarchy-hw-apple-silicon|omarchy-cmd-present) exit 1 ;;
esac
exit 0
STUB
chmod +x "$work/bin/fixture"
for name in quickshell omarchy-restart-shell omarchy-hyprland-session-locked omarchy-shell python3 systemctl wpctl sleep \
  omarchy-hw-apple-silicon omarchy-cmd-present; do
  ln -s fixture "$work/bin/$name"
done
export CALLS="$work/calls" STATE="$work/state" PATH="$work/bin:$PATH" OMARCHY_PATH=/usr/share/omarchy

# run_case <running shell instances> [VAR=value...]; sets $status.
run_case() {
  local instances=$1
  shift
  : >"$CALLS"
  rm -f "$STATE"/*
  echo "$instances" >"$STATE/instances"
  status=0
  env "$@" "$ROOT/bin/omarchy-restart-audio" >"$work/output" 2>&1 || status=$?
}

line_of() {
  grep -nFx -- "$1" "$CALLS" | head -n 1 | cut -d: -f1
}

count_of() {
  grep -cF -- "$1" "$CALLS" || true
}

restart_line='systemctl --user restart wireplumber.service pipewire.service pipewire-pulse.service'
kill_line='quickshell kill -p /usr/share/omarchy/shell --any-display'

run_case 0
(( status == 0 )) || fail 'audio restarts when no shell runs' "$(cat "$work/output")"
[[ -n $(line_of "$restart_line") ]] || fail 'audio services restart when no shell runs' "$(cat "$CALLS")"
(( $(count_of 'quickshell kill') == 0 && $(count_of 'omarchy-restart-shell') == 0 )) ||
  fail 'no shell is stopped or started when none was running' "$(cat "$CALLS")"
(( $(count_of 'omarchy-hyprland-session-locked') == 0 )) || fail 'the lock state only matters with a shell to stop'
pass 'without a running shell, audio restarts as before'

run_case 1
(( status == 0 )) || fail 'an unlocked restart succeeds' "$(cat "$work/output")"
kill_at=$(line_of "$kill_line")
restart_at=$(line_of "$restart_line")
status_at=$(grep -nFx 'wpctl status' "$CALLS" | tail -n 1 | cut -d: -f1)
start_at=$(line_of 'omarchy-restart-shell ')
[[ -n $kill_at && -n $restart_at && -n $status_at && -n $start_at ]] || fail 'every step of an unlocked restart runs' "$(cat "$CALLS")"
(( kill_at < restart_at && restart_at < status_at && status_at < start_at )) ||
  fail 'the shell stops before audio goes away and starts once audio answers' "$(cat "$CALLS")"
(( $(count_of 'quickshell kill') == 1 && $(count_of 'omarchy-restart-shell') == 1 )) || fail 'the shell stops and starts once' "$(cat "$CALLS")"
(( $(count_of 'omarchy-shell lock lock') == 0 )) || fail 'an unlocked restart without a suspend does not lock the screen'
pass 'audio restarts with the shell stopped, and the shell comes back once audio answers'

for setting in SESSION_LOCKED=0 SESSION_LOCKED=2 'LOCK_STATUS={"secure":true,"requested":false}' \
  'LOCK_STATUS={"secure":false,"requested":true}' 'LOCK_STATUS=garbage'; do
  run_case 1 "$setting"
  (( status == 1 )) || fail "a locked or unknown screen refuses the restart: $setting" "$(cat "$work/output")"
  (( $(count_of 'systemctl') == 0 && $(count_of 'quickshell kill') == 0 && $(count_of 'omarchy-restart-shell') == 0 )) ||
    fail "nothing is touched while the screen may be locked: $setting" "$(cat "$CALLS")"
  grep -Eq 'Not restarting audio while the (screen is locked|lock state is unknown)' "$work/output" ||
    fail "the refusal says why: $setting" "$(cat "$work/output")"
done
pass 'a locked, locking or unknown screen is never left to a crashing shell'

run_case 1 LOCK_STATUS=fail
(( status == 0 && $(count_of 'quickshell kill') == 1 )) || fail 'a shell that does not answer holds no lock to lose' "$(cat "$CALLS")"
pass 'a shell that answers no lock query holds no lock to lose'

run_case 1 LIST_FAIL=1
(( status == 1 && $(count_of 'systemctl') == 0 && $(count_of 'quickshell kill') == 0 )) ||
  fail 'an unknown shell state refuses the restart' "$(cat "$CALLS")"
pass 'audio does not restart when Quickshell cannot tell whether the shell runs'

run_case 1 SHELL_STUCK=1
(( status == 1 )) || fail 'a shell that will not stop refuses the restart'
(( $(count_of 'quickshell kill') == 10 && $(count_of 'systemctl') == 0 )) ||
  fail 'audio never restarts under a shell that would not stop' "$(cat "$CALLS")"
(( $(count_of 'omarchy-restart-shell') == 1 )) || fail 'a half-stopped shell is brought back' "$(cat "$CALLS")"
pass 'audio never restarts under a shell that would not stop'

run_case 1 WPCTL_STATUS=1
(( status == 1 && $(count_of 'omarchy-restart-shell') == 1 )) || fail 'the shell comes back even when audio does not' "$(cat "$CALLS")"
pass 'the shell comes back even when audio does not'

run_case 1 RESTART_SHELL_STATUS=1
(( $(count_of 'omarchy-restart-shell') == 3 )) || fail 'a failed shell start is retried a bounded number of times' "$(cat "$CALLS")"
pass 'a failed shell start is retried three times'

run_case 1 SUSPEND=1
lock_at=$(line_of 'omarchy-shell lock lock')
start_at=$(line_of 'omarchy-restart-shell ')
[[ -n $lock_at ]] && (( start_at < lock_at )) || fail 'a suspend while the shell was down locks the screen' "$(cat "$CALLS")"
pass 'a suspend while the shell was down locks the screen once it is back'

run_case 1 SIGNAL_DURING_RESTART=TERM
(( status == 143 && $(count_of 'omarchy-restart-shell') == 1 )) || fail 'an interrupted restart brings the shell back' "$status $(cat "$CALLS")"
run_case 1 SIGNAL_DURING_RESTART=HUP
(( status == 0 && $(count_of 'omarchy-restart-shell') == 1 )) || fail 'closing the terminal lets the restart finish' "$status $(cat "$CALLS")"
[[ -n $(line_of 'wpctl status') ]] || fail 'closing the terminal lets audio come back'
pass 'an interrupted or orphaned restart never leaves the desktop without its shell'
