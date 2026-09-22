#!/bin/bash
# Open the target's Debug Virtual Console and keep everything it says.
#
#   bash gdbctl.sh start lcdtp.elf
#   ... connect and set_target as usual ...
#   bash console.sh open                 # two monitor commands, then listen
#   bash console.sh tail                 # what the target has printed since last read
#   bash console.sh close
#
# What this is for: the ring buffer in the target's RAM can only be read with
# the target stopped - a read of a running one comes back fabricated - so it
# is history after a freeze, not a view during a run. This is the other half.
# The target writes bytes to a mailbox in the debug SFR space and the emulator
# drains them while it runs; nothing halts. See dbgcon.h in the port for the
# target side and where the register layout comes from.
#
# The reason it is worth the trouble: this stream is not carried by the gdb
# session. e2-server-gdb serves it from its own thread on a plain TCP port, so
# reading it is a socket anyone can open. When the MI session wedges - and it
# does - the log keeps arriving. That is the whole point.
#
# Order matters, and one step is easy to miss. The target must be connected
# (monitor set_target done) before start_interface, and the socket only
# carries what is written after it is opened - anything printed before that is
# gone, which is what the ring buffer is still there for.
#
# The missable step: the emulator only drains the mailbox while it holds
# execution control. Attached to a target already running from a flash, with
# both monitor commands accepted and the port listening, nothing comes out at
# all. It starts the moment the target has been reset and released under the
# debugger:
#
#   monitor enable_stopped_notify_on_connect
#   monitor enable_execute_on_connect      <- resets the target
#   -exec-continue
#
# So turning the console on costs a reset. What it buys is a stream that
# outlives the gdb session: this was still delivering after -exec-continue had
# left the MI channel unresponsive, because the server serves it from its own
# SimIO thread rather than through gdb.
set -euo pipefail

PORT="${PORT:-5432}"
OUT="${OUT:-/tmp/dbgcon.log}"
MARK="${MARK:-/tmp/dbgcon.mark}"
PIDFILE="${PIDFILE:-/tmp/dbgcon.pid}"
HOST="${HOST:-localhost}"

alive()
{
	[ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

case "${1:-status}" in
open)
	if alive; then
		echo "already listening (pid $(cat "$PIDFILE"))"
		exit 0
	fi

	# set_simio_pipe says where simulated I/O goes; start_interface opens it.
	# Both are in e2-server-gdb's monitor table - checked in the binary
	# alongside get_interface_port, which can be asked for the port it chose
	# if these are ever driven without naming one.
	bash "$(dirname "$0")/gdbctl.sh" send '-interpreter-exec console "monitor set_simio_pipe,telnet"'
	sleep 1
	bash "$(dirname "$0")/gdbctl.sh" send \
		"-interpreter-exec console \"monitor start_interface,TELNET,telnet,$PORT\""
	sleep 2

	: > "$OUT"
	: > "$MARK"
	# nc, not telnet: this wants the bytes, not a terminal negotiation.
	setsid nc "$HOST" "$PORT" >> "$OUT" 2>&1 < /dev/null &
	echo $! > "$PIDFILE"

	sleep 1
	alive || { echo "could not connect to $HOST:$PORT" >&2; rm -f "$PIDFILE"; exit 1; }
	echo "OK: console on $HOST:$PORT -> $OUT (pid $(cat "$PIDFILE"))"
	;;

tail)
	# Since last read by default, like gdbctl.sh log, and for the same
	# reason: each read crosses a slow hop and the log is read often.
	if [ $# -ge 2 ]; then
		off="$2"
	else
		off=$(cat "$MARK" 2>/dev/null || echo 0)
	fi
	[ -f "$OUT" ] || { echo "no console log yet" >&2; exit 1; }
	tail -c "+$(( off + 1 ))" "$OUT"
	wc -c < "$OUT" > "$MARK"
	;;

status)
	if alive; then
		echo "console: listening on $HOST:$PORT (pid $(cat "$PIDFILE"))"
	else
		echo "console: not listening"
	fi
	[ -f "$OUT" ] && echo "$OUT: $(wc -c < "$OUT") bytes, read to $(cat "$MARK" 2>/dev/null || echo 0)"
	;;

close)
	alive && kill "$(cat "$PIDFILE")" 2>/dev/null || true
	rm -f "$PIDFILE"
	echo "OK: closed (log kept at $OUT)"
	;;

*)
	echo "usage: console.sh {open|tail [offset]|status|close}" >&2
	exit 1
	;;
esac
