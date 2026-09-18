#!/bin/bash
# Keep the target's debug log flowing into a file, and read it back in pieces.
#
#   bash logd.sh start lcdtp.elf   # connect once, then follow in the background
#   bash logd.sh tail 40           # the last 40 lines
#   bash logd.sh since 4096        # everything from byte 4096 on
#   bash logd.sh status            # is it still alive, and how much is there
#   bash logd.sh stop
#
# The point of the detached form is that the connection is made *once*. Every
# reconnect risks the two failures that cost the most here - the emulator's
# semaphore and the target being halted on attach - so the fewer connections
# a debugging session makes, the better it behaves. Reading the file back
# costs nothing and can be done as often as you like.
#
# readlog.py already streams the ring buffer to stdout and keeps the target
# running; this only puts it in the background and gives its output an
# address.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-/tmp/target.log}"
PIDFILE="${PIDFILE:-/tmp/readlog.pid}"
READLOG="${READLOG:-/tmp/readlog.py}"
GDB="${GDB:-/opt/e2gdb/rx-elf-gdb}"

alive()
{
	[ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

case "${1:-status}" in
start)
	ELF="${2:?usage: logd.sh start <file.elf>}"

	if alive; then
		echo "already running (pid $(cat "$PIDFILE"))"
		exit 0
	fi

	bash "$HERE/gdbserver.sh"

	# Truncated, not appended: a log that silently carries the previous
	# run's output is the kind of thing that gets read as current.
	: > "$OUT"
	nohup python3 "$READLOG" "$ELF" --gdb "$GDB" >> "$OUT" 2>&1 &
	echo $! > "$PIDFILE"

	# readlog.py exits immediately on a bad magic or an unreadable target,
	# so a moment's wait is the difference between reporting success and
	# reporting the actual reason.
	sleep 3
	if ! alive; then
		echo "readlog exited:" >&2
		cat "$OUT" >&2
		rm -f "$PIDFILE"
		exit 1
	fi
	echo "OK: following into $OUT (pid $(cat "$PIDFILE"))"
	;;

tail)
	tail -n "${2:-40}" "$OUT"
	;;

since)
	# Byte offset, so successive reads do not repeat what was already read.
	# tail -c +N is 1-based; 0 and 1 both mean the beginning.
	tail -c "+$(( ${2:-0} + 1 ))" "$OUT"
	;;

status)
	if alive; then
		echo "readlog: running (pid $(cat "$PIDFILE"))"
	else
		echo "readlog: not running"
	fi
	if [ -f "$OUT" ]; then
		echo "$OUT: $(wc -c < "$OUT") bytes, $(wc -l < "$OUT") lines"
	else
		echo "$OUT: absent"
	fi
	;;

stop)
	if alive; then
		kill "$(cat "$PIDFILE")" 2>/dev/null || true
	fi
	rm -f "$PIDFILE"
	# The gdb client has to be gone before the server is, or the server is
	# killed with a client attached - which is exactly what leaves the
	# emulator's semaphore held.
	sleep 1
	bash "$HERE/gdbserver.sh" stop
	echo "OK: stopped"
	;;

*)
	echo "usage: logd.sh {start <elf>|tail [n]|since <byte>|status|stop}" >&2
	exit 1
	;;
esac
