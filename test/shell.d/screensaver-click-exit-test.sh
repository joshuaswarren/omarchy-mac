#!/bin/bash

source "$(dirname "$0")/base-test.sh"

require_command python3
require_command jq

# Regression test for the mouse-click exit on the screensaver. Everything runs
# against stubs and a private PTY; no compositor or ttfx install is touched.

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

cat >"$WORK/bin/hyprctl" <<'STUB'
#!/bin/bash
case $1 in
  activewindow) printf '{"class":"org.omarchy.screensaver"}' ;;
  eval|keyword) exit 0 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/hyprctl"

# ttfx must keep running on the screensaver's controlling terminal under the
# name ttfx (the script polls `pgrep -t <tty> -x ttfx`), so rename the process
# and ignore the real tool's flags.
cat >"$WORK/bin/ttfx" <<'STUB'
#!/usr/bin/env python3
import ctypes, time
ctypes.CDLL(None).prctl(15, b"ttfx", 0, 0, 0)  # PR_SET_NAME
time.sleep(300)
STUB
chmod +x "$WORK/bin/ttfx"

# Contained pkill: the production script runs `pkill -x ttfx` and
# `pkill -f org.omarchy.screensaver`; never let that exact-name kill reach
# processes outside this test. Only candidates in the stub's own process
# group (the screensaver run's group) are killed; everything else is spared.
cat >"$WORK/bin/pkill" <<'STUB'
#!/bin/bash
mypgid=$(ps -o pgid= -p $$)
pids=$(pgrep "$@") || exit 0
for pid in $pids; do
  [[ $(ps -o pgid= -p "$pid") == "$mypgid" ]] && kill "$pid" 2>/dev/null
done
exit 0
STUB
chmod +x "$WORK/bin/pkill"

# Drive one screensaver run on a PTY. Reports the PTY bytes seen on stdout and
# exits 0 only when the run behaved: startup enabled mouse reporting when
# EXPECT_ENABLE is set, the given exit stimulus ended the process, and mouse
# reporting was turned back off before exit.
cat >"$WORK/pty-run.py" <<'STUB'
import os, pty, sys, select, signal, time, fcntl, termios, struct

mode, script = sys.argv[1], sys.argv[2]

pid, fd = pty.fork()
# pty.fork makes the child a session leader, so its process group == pid:
# every kill below is scoped to exactly the run we own, never by name.
if pid == 0:
    os.environ["PATH"] = os.environ["WORK"] + "/bin:" + os.environ["PATH"]
    os.execv(script, [script])
    os._exit(127)

def cleanup():
    # Only our own child and its group; success or any failure path.
    try:
        os.killpg(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        os.close(fd)
    except OSError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass

import atexit
atexit.register(cleanup)

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 60, 120, 0, 0))

seen = b""
def drain(timeout):
    global seen
    end = time.time() + timeout
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if fd in r:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                return False
            if not chunk:
                return False
            seen += chunk
    return True

def dead():
    return os.waitpid(pid, os.WNOHANG)[0] != 0

def wait_exit(timeout=10):
    end = time.time() + timeout
    while time.time() < end:
        drain(0.05)
        if dead():
            return True
    return False

drain(3)  # startup: background color, stty -echo, mouse enable
startup = seen

if mode == "mouse":
    if b"\x1b[?1000h" not in startup or b"\x1b[?1006h" not in startup:
        print(startup.decode("utf-8", "replace"))
        sys.exit(3)  # mouse reporting never enabled
    os.write(fd, b"\x1b[<0;10;10M")  # SGR mouse click press
elif mode == "key":
    os.write(fd, b"x")
elif mode == "signal":
    os.kill(pid, signal.SIGINT)
else:
    sys.exit(2)

if not wait_exit():
    sys.exit(4)  # stimulus did not end the screensaver
if b"\x1b[?1000l" not in seen or b"\x1b[?1006l" not in seen:
    print(seen.decode("utf-8", "replace"))
    sys.exit(5)  # mouse reporting never disabled on the way out
sys.exit(0)
STUB

run_mode() {
  WORK="$WORK" python3 "$WORK/pty-run.py" "$1" "$ROOT/bin/omarchy-screensaver" >/dev/null 2>&1
}

if run_mode mouse; then
  pass "a mouse click ends the screensaver and mouse reporting is enabled at startup and disabled at exit"
else
  fail "a mouse click ends the screensaver and mouse reporting is enabled at startup and disabled at exit"
fi
if run_mode key; then
  pass "a key press ends the screensaver and disables mouse reporting"
else
  fail "a key press ends the screensaver and disables mouse reporting"
fi
if run_mode signal; then
  pass "SIGINT ends the screensaver and disables mouse reporting"
else
  fail "SIGINT ends the screensaver and disables mouse reporting"
fi
