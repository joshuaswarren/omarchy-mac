#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
unset HYPRLAND_INSTANCE_SIGNATURE
require_command jq
require_command flock
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/state" "$work/home" "$work/runtime"

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
  omarchy-hyprland-session-locked)
    printf 'signature=%s\n' "${HYPRLAND_INSTANCE_SIGNATURE:-}" >>"$CALLS"
    exit "${SESSION_LOCKED:-1}" ;;
  omarchy-shell)
    printf 'omarchy-shell-path=%s\n' "$OMARCHY_PATH" >>"$CALLS"
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
    # A suspend shows as CLOCK_BOOTTIME pulling ahead of CLOCK_MONOTONIC by
    # the time slept.
    if [[ -e $STATE/offset ]]; then awk -v slept="${SUSPEND:-0}" 'BEGIN { print 5.25 + slept }'; else echo 5.25; fi
    touch "$STATE/offset" ;;
  systemd-inhibit)
    # logind lists a block once it holds it; the inhibitor keeps it while it runs.
    if [[ $1 == "--list" ]]; then
      [[ -e $STATE/inhibitor ]] || /usr/bin/sleep 0.05
      [[ -e $STATE/inhibitor ]] &&
        printf 'omarchy-restart-audio 1000 user %s systemd-inhibit sleep The Omarchy shell is stopped block\n' "$(cat "$STATE/inhibitor")"
      exit 0
    fi
    [[ ${INHIBIT_FAIL:-0} == 1 ]] && exit 1
    echo $$ >"$STATE/inhibitor"
    while [[ $1 == --* ]]; do shift; done
    exec "$@" ;;
  systemctl)
    if [[ $2 == "show-environment" && $3 == "--output=json" && -n ${SESSION_OMARCHY_PATH:-} ]]; then
      jq -cn --arg path "$SESSION_OMARCHY_PATH" '{OMARCHY_PATH: $path}'
    elif [[ $2 == "restart" ]]; then
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
  systemd-inhibit omarchy-hw-apple-silicon omarchy-cmd-present; do
  ln -s fixture "$work/bin/$name"
done
# Recovery that finds audio still down edits WirePlumber state under HOME.
export CALLS="$work/calls" STATE="$work/state" PATH="$work/bin:$PATH" OMARCHY_PATH=/usr/share/omarchy \
  HOME="$work/home" XDG_STATE_HOME="$work/home/.local/state" XDG_RUNTIME_DIR="$work/runtime"

# run_case <running shell instances> [VAR=value...]; sets $status.
run_case() {
  local instances=$1
  shift
  : >"$CALLS"
  rm -f "$STATE"/*
  echo "$instances" >"$STATE/instances"
  status=0
  # A subshell, so a killed case is not reported as a job.
  ( env "$@" "$ROOT/bin/omarchy-restart-audio" >"$work/output" 2>&1; exit $? ) 2>/dev/null || status=$?
}

audio_touched() {
  grep -cE '^systemctl --user (restart|kill|start|reset-failed|cancel)' "$CALLS" || true
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
start_at=$(line_of 'omarchy-restart-shell ')
status_at=$(grep -nFx 'wpctl status' "$CALLS" | tail -n 1 | cut -d: -f1)
[[ -n $kill_at && -n $restart_at && -n $status_at && -n $start_at ]] || fail 'every step of an unlocked restart runs' "$(cat "$CALLS")"
(( kill_at < restart_at && restart_at < start_at && start_at < status_at )) ||
  fail 'the shell is stopped only while the audio services restart' "$(cat "$CALLS")"
(( $(count_of 'quickshell kill') == 1 && $(count_of 'omarchy-restart-shell') == 1 )) || fail 'the shell stops and starts once' "$(cat "$CALLS")"
(( $(count_of 'omarchy-shell lock lock') == 0 )) || fail 'an unlocked restart without a suspend does not lock the screen'
inhibit_at=$(grep -nE '^systemd-inhibit --what=sleep --mode=block --who=omarchy-restart-audio --why=The Omarchy shell is stopped while audio restarts tail --pid=[0-9]+ -f /dev/null$' "$CALLS" | head -n 1 | cut -d: -f1)
listed_at=$(line_of 'systemd-inhibit --list --no-legend --no-pager')
[[ -n $inhibit_at && -n $listed_at ]] && (( inhibit_at < kill_at && listed_at < kill_at )) ||
  fail 'logind holds the sleep block before the shell stops' "$(cat "$CALLS")"
pass 'the shell is stopped only while the audio services restart'

for setting in SESSION_LOCKED=0 SESSION_LOCKED=2 'LOCK_STATUS={"secure":true,"requested":false}' \
  'LOCK_STATUS={"secure":false,"requested":true}' 'LOCK_STATUS=garbage' 'LOCK_STATUS={}' LOCK_STATUS=fail; do
  run_case 1 "$setting"
  (( status == 1 )) || fail "a locked or unknown screen refuses the restart: $setting" "$(cat "$work/output")"
  (( $(audio_touched) == 0 && $(count_of 'quickshell kill') == 0 && $(count_of 'omarchy-restart-shell') == 0 )) ||
    fail "nothing is touched while the screen may be locked: $setting" "$(cat "$CALLS")"
  grep -Eq 'Not restarting audio while the (screen is locked|lock state is unknown)' "$work/output" ||
    fail "the refusal says why: $setting" "$(cat "$work/output")"
done
pass 'a locked, locking or unknown screen is never left to a crashing shell'

exec {held}>>"$work/runtime/omarchy-audio-repair.lock"
flock "$held"
run_case 1
exec {held}>&-
(( status == 1 && $(audio_touched) == 0 && $(count_of 'quickshell kill') == 0 )) ||
  fail 'a repair already running holds audio and the shell' "$(cat "$CALLS")"
grep -Fq 'another audio repair is running' "$work/output" || fail 'the refusal names the running repair' "$(cat "$work/output")"
pass 'one audio repair at a time, shared with the Apple audio watchdog'

run_case 1 LIST_FAIL=1
(( status == 1 && $(audio_touched) == 0 && $(count_of 'quickshell kill') == 0 )) ||
  fail 'an unknown shell state refuses the restart' "$(cat "$CALLS")"
pass 'audio does not restart when Quickshell cannot tell whether the shell runs'

run_case 1 INHIBIT_FAIL=1
(( status == 1 && $(count_of 'quickshell kill') == 0 && $(audio_touched) == 0 && $(count_of 'omarchy-restart-shell') == 0 )) ||
  fail 'the shell is never stopped without sleep blocked' "$(cat "$CALLS")"
grep -Fq 'sleep could not be blocked' "$work/output" || fail 'the refusal says sleep could not be blocked' "$(cat "$work/output")"
pass 'the shell is never stopped unless logind holds the sleep block'

run_case 1 SHELL_STUCK=1
(( status == 1 )) || fail 'a shell that will not stop refuses the restart'
(( $(count_of 'quickshell kill') == 10 && $(audio_touched) == 0 )) ||
  fail 'audio never restarts under a shell that would not stop' "$(cat "$CALLS")"
(( $(count_of 'omarchy-restart-shell') == 1 )) || fail 'a half-stopped shell is brought back' "$(cat "$CALLS")"
pass 'audio never restarts under a shell that would not stop'

run_case 1 WPCTL_STATUS=1
(( status == 1 && $(count_of 'omarchy-restart-shell') == 1 )) || fail 'the shell comes back even when audio does not' "$(cat "$CALLS")"
pass 'the shell comes back even when audio does not'

run_case 1 RESTART_SHELL_STATUS=1
(( $(count_of 'omarchy-restart-shell') == 3 )) || fail 'a failed shell start is retried a bounded number of times' "$(cat "$CALLS")"
(( status == 1 )) && grep -Fq 'did not come back' "$work/output" || fail 'a shell that never came back fails the restart' "$status $(cat "$work/output")"
pass 'a failed shell start is retried three times, then reported'

for slept in 60 1; do
  run_case 1 SUSPEND=$slept
  lock_at=$(line_of 'omarchy-shell lock lock')
  start_at=$(line_of 'omarchy-restart-shell ')
  [[ -n $lock_at ]] && (( start_at < lock_at && status == 0 )) ||
    fail "a ${slept}s suspend while the shell was down locks the screen" "$(cat "$CALLS")"
done
pass 'any suspend while the shell was down locks the screen once it is back'

run_case 1 SIGNAL_DURING_RESTART=TERM
(( status == 143 && $(count_of 'omarchy-restart-shell') == 1 )) || fail 'an interrupted restart brings the shell back' "$status $(cat "$CALLS")"
run_case 1 SIGNAL_DURING_RESTART=HUP
(( status == 0 && $(count_of 'omarchy-restart-shell') == 1 )) || fail 'closing the terminal lets the restart finish' "$status $(cat "$CALLS")"
[[ -n $(line_of 'wpctl status') ]] || fail 'closing the terminal lets audio come back'
pass 'an interrupted or orphaned restart never leaves the desktop without its shell'

run_case 1 SIGNAL_DURING_RESTART=KILL
inhibitor=$(cat "$STATE/inhibitor")
for (( wait = 0; wait < 30; wait++ )); do
  kill -0 "$inhibitor" 2>/dev/null || break
  /usr/bin/sleep 0.2
done
! kill -0 "$inhibitor" 2>/dev/null || fail 'a killed restart does not leave sleep blocked'
pass 'the sleep block never outlives the restart, even a killed one'

run_case 1 'SESSION_OMARCHY_PATH=/session/dev checkout'
[[ -n $(line_of 'quickshell list -p /session/dev checkout/shell --any-display -j') ]] ||
  fail 'the running shell is found under the session path, spaces and all' "$(cat "$CALLS")"
! grep -Fq 'omarchy-shell-path=/usr/share/omarchy' "$CALLS" && grep -Fxq 'omarchy-shell-path=/session/dev checkout' "$CALLS" ||
  fail 'the lock state is asked of the session shell' "$(cat "$CALLS")"
pass 'a caller after a dev link or unlink still finds the session shell'

mkdir -p "$work/runtime/hypr/older" && /usr/bin/sleep 0.05 && mkdir -p "$work/runtime/hypr/newest"
run_case 1
grep -Fxq 'signature=newest' "$CALLS" || fail 'outside the session, the newest Hyprland instance is used' "$(cat "$CALLS")"
(( status == 0 )) || fail 'a restart over ssh runs once the lock state is readable' "$(cat "$work/output")"
pass 'outside the session, the lock state is read from the newest Hyprland instance'
