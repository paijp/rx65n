#!/bin/bash
# Drive a bare gdb through a FIFO, with everything it says kept in a file.
#
#   bash gdbctl.sh start lcdtp.elf       # launch gdb; it connects to nothing yet
#   bash gdbctl.sh send '-gdb-version'   # one command
#   bash gdbctl.sh log                   # whatever it has said since the last read
#   bash gdbctl.sh log 0                 # from the beginning
#   bash gdbctl.sh stop
#
# No readlog.py here, deliberately. When a session misbehaves the question is
# always "gdb, the server, the target, or the script?", and this removes the
# last of those so the other three can be told apart. Once a sequence is known
# to work here, it can be moved into readlog.py knowing the sequence itself is
# not what is wrong.
#
# Everything gdb writes is kept. readlog.py currently reads gdb's replies and
# throws them away, which is why a client that died took its reason with it:
# the caller saw a broken pipe and nothing else.
#
# The sequence that works against e2-server-gdb, taken from what e2 studio's
# own gdb does and cut down to what this needs:
#
#   set non-stop on                          <- before connecting
#   target extended-remote <host>:61234      <- within ConnectionTimeout
#   monitor set_target,R5F565NE_DUAL
#
# `set non-stop on` is the one that matters. Without it gdb assumes the
# target is stopped, reads registers as part of attaching, gets E01 back
# because it is not, drops the thread and falls back to the `exec` target -
# after which load, continue, breakpoints and even `monitor` all fail, each
# looking like its own problem. With it, the thread survives and `monitor`
# works.
#
# RAM read off a *running* target is not to be trusted. It comes back as a
# short repeating pattern - 02000000 03000000 over and over - which is not
# what is in memory: the same addresses read correctly the moment the target
# is stopped, and the pattern's values change from run to run, so it reads
# like data and is not. This cost a day: it was taken for memory corruption,
# a theory was built on it, and the theory was wrong.
#
# So check before believing a snapshot. The log buffer's first word is
# 0x4c475044; if a read of it says anything else, the target was running and
# the whole read is to be discarded, not interpreted. Stopping it first is
# what makes a read mean something - a watchpoint on an address the program
# writes will do it, and gdb reports the stop even when it has otherwise
# gone quiet.
#
# Two more, only when the program should be run under the debugger:
#
#   monitor enable_stopped_notify_on_connect
#   monitor enable_execute_on_connect        <- this RESETS the target
#
# which leaves it stopped at PowerON_Reset with registers readable. There is
# no way found to read registers *without* that reset, so a target that has
# crashed can be examined through its RAM but not its registers.
#
# Never send -exec-continue: it starts the program, and this gdb then stops
# answering the FIFO, so the session is over either way.
set -euo pipefail

FIFO="${FIFO:-/tmp/gdb.ctl}"
LOG="${LOG:-/tmp/gdb.log}"
MARK="${MARK:-/tmp/gdb.mark}"		# how far `log` has read
PIDFILE="${PIDFILE:-/tmp/gdbctl.pid}"
GDB="${GDB:-/work/toolchain/bin/rx-elf-gdb}"

alive()
{
	[ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

case "${1:-status}" in
start)
	ELF="${2:-}"

	if alive; then
		echo "already running (pid $(cat "$PIDFILE"))"
		exit 0
	fi

	rm -f "$FIFO" "$LOG" "$MARK"
	mkfifo "$FIFO"

	# 0<> opens the FIFO read-write. That matters twice over: the open does
	# not block waiting for a writer, and gdb's own descriptor counts as a
	# write end, so the EOF that arrives when an `echo > fifo` closes never
	# reaches gdb and it does not exit. Without this a holder process would
	# have to keep the write end open for as long as the session lasts.
	setsid "$GDB" -q -nx --interpreter=mi2 ${ELF:+"$ELF"} \
		0<> "$FIFO" > "$LOG" 2>&1 &
	echo $! > "$PIDFILE"

	sleep 2
	if ! alive; then
		echo "gdb exited at once:" >&2
		cat "$LOG" >&2
		rm -f "$PIDFILE"
		exit 1
	fi
	echo "OK: gdb running (pid $(cat "$PIDFILE")), fifo $FIFO, log $LOG"
	;;

send)
	CMD="${2:?usage: gdbctl.sh send '<gdb/MI command>'}"
	alive || { echo "gdb is not running" >&2; exit 1; }
	# A plain redirect: this writer opens and closes every time, which is
	# exactly what the read-write open above makes safe.
	printf '%s\n' "$CMD" > "$FIFO"
	;;

log)
	# Default is "since last time", so repeated reads do not re-send what
	# has already been seen - the log is read far more often than it is
	# written, and each read crosses a slow hop.
	if [ $# -ge 2 ]; then
		off="$2"
	else
		off=$(cat "$MARK" 2>/dev/null || echo 0)
	fi
	[ -f "$LOG" ] || { echo "no log yet" >&2; exit 1; }
	tail -c "+$(( off + 1 ))" "$LOG"
	wc -c < "$LOG" > "$MARK"
	;;

status)
	if alive; then
		echo "gdb: running (pid $(cat "$PIDFILE"))"
	else
		echo "gdb: not running"
	fi
	if [ -f "$LOG" ]; then
		echo "$LOG: $(wc -c < "$LOG") bytes, read to $(cat "$MARK" 2>/dev/null || echo 0)"
	fi
	;;

stop)
	if alive; then
		kill "$(cat "$PIDFILE")" 2>/dev/null || true
	fi
	rm -f "$PIDFILE" "$FIFO"
	echo "OK: stopped (log kept at $LOG)"
	;;

*)
	echo "usage: gdbctl.sh {start [elf]|send '<cmd>'|log [offset]|status|stop}" >&2
	exit 1
	;;
esac
