#!/bin/bash
# Program a board and watch its console from the program's first byte.
#
#   bash logrun.sh /tmp/lcdtp.mot /tmp/lcdtp.elf
#   bash logrun.sh /tmp/lcdtp.mot /tmp/lcdtp.elf 120   # watch for 120s
#
# Run inside the VM, after attach.sh has claimed the E2 Lite.
#
# This exists because the obvious order loses the beginning. flash.sh with
# -run starts the program immediately, and e2-server-gdb then takes about
# thirty-five seconds to connect - so by the time anything is listening, the
# program has been running unobserved for half a minute. Everything it said
# in that time is gone, and if it crashed in that time there is nothing to
# say so.
#
# The order here has no such window:
#
#   1. program with -reset, so nothing executes
#   2. bring the server up and connect gdb
#   3. set_simio_pipe + start_interface, and open the socket
#   4. enable_execute_on_connect, which resets and halts at PowerON_Reset
#   5. continue
#
# The program starts at step 5, with a listener already attached, so the
# capture begins at its first byte.
#
# Two things about step 4 and 5 that are not obvious and cost time to find:
#
# The emulator drains the console mailbox only while it holds execution
# control. Attached to a target already running, with both monitor commands
# accepted and the port listening, nothing comes out at all.
#
# After -exec-continue this gdb stops answering its FIFO. That is expected
# and does not matter here: the console is served by the server's own SimIO
# thread, not through gdb, and keeps delivering. It does mean the session
# cannot be driven any further, so anything needed from gdb must be sent
# before the continue.
set -euo pipefail

MOT="${1:?usage: logrun.sh <file.mot> <file.elf> [seconds]}"
ELF="${2:?usage: logrun.sh <file.mot> <file.elf> [seconds]}"
WATCH="${3:-0}"

HERE="$(cd "$(dirname "$0")" && pwd)"
PORT="${PORT:-5432}"
GDBPORT="${GDBPORT:-61234}"
OUT="${OUT:-/tmp/dbgcon.log}"
export GDB="${GDB:-/opt/e2gdb/rx-elf-gdb}"

G()
{
	bash "$HERE/gdbctl.sh" send "$1"
	sleep 1
}

echo "== 1/5 program, leaving the target stopped"
NORUN=1 bash "$HERE/flash.sh" "$MOT"

echo "== 2/5 gdb server"
pkill -f e2-server-gdb 2>/dev/null || true
bash "$HERE/gdbctl.sh" stop >/dev/null 2>&1 || true
pkill -f "nc localhost $PORT" 2>/dev/null || true
rm -f /dev/shm/sem.* "$OUT" 2>/dev/null || true
sleep 2

bash "$HERE/gdbctl.sh" start "$ELF"
nohup setsid bash "$HERE/gdbserver.sh" > /tmp/srv.out 2>&1 &

# Wait for the port, not for a fixed time: the connection takes about 35
# seconds, and the server's own client timeout does not start until the port
# is open, so there is nothing to be gained by guessing.
for i in $(seq 90); do
	sleep 1
	ss -lnt | grep -q "$GDBPORT" && break
done
ss -lnt | grep -q "$GDBPORT" || {
	echo "server never opened $GDBPORT; see /tmp/e2gdb.log" >&2
	tail -5 /tmp/e2gdb.log >&2
	exit 1
}
echo "   port open after ${i}s"

echo "== 3/5 connect"
G 'set non-stop on'
G "-target-select extended-remote localhost:$GDBPORT"
G '-interpreter-exec console "monitor set_target,R5F565NE_DUAL"'

echo "== 4/5 console"
G '-interpreter-exec console "monitor set_simio_pipe,telnet"'
G "-interpreter-exec console \"monitor start_interface,TELNET,telnet,$PORT\""
sleep 2
nohup setsid sh -c "nc localhost $PORT >> '$OUT' 2>&1" >/dev/null 2>&1 &
sleep 1

echo "== 5/5 release the target"
G '-interpreter-exec console "monitor enable_stopped_notify_on_connect"'
G '-interpreter-exec console "monitor enable_execute_on_connect"'
sleep 2
bash "$HERE/gdbctl.sh" send '-exec-continue'

echo "OK: running; console -> $OUT"
if [ "$WATCH" != 0 ]; then
	sleep "$WATCH"
	echo "--- $(wc -c < "$OUT") bytes"
	cat "$OUT"
fi
