#!/bin/bash
# Run inside the VM, after flash.sh has left the program running.
# Starts e2-server-gdb on the attached E2 Lite, ready for tools/readlog.py.
#
#   bash gdbserver.sh            # start, log to /tmp/e2gdb.log, print the port
#   bash gdbserver.sh stop       # stop it and clean up after it
#
# This exists because the argv below is not something anyone should be
# retyping. Every odd thing about it is load-bearing, and the one that costs
# the most to rediscover is the space after each `=`.
set -euo pipefail

SERVER="${SERVER:-/opt/e2gdb/e2-server-gdb}"
PORT="${PORT:-61234}"
AUXPORT="${AUXPORT:-61236}"
LOG="${LOG:-/tmp/e2gdb.log}"
PIDFILE="${PIDFILE:-/tmp/e2gdb.pid}"

# Hot plug: attach to the running program rather than resetting it. Both
# options exist in the binary; neither has yet been shown to keep the target
# running on this board, so they are off unless asked for.
#
#   HOTPLUG=1 bash gdbserver.sh
HOTPLUG="${HOTPLUG:-0}"


# A server that is killed while a GDB client is connected leaves the POSIX
# named semaphore libCommuni.so takes for the emulator held, and every later
# connection then fails with "can not connect to the emulator" - on hardware
# that is in perfect health, which is what makes it so expensive to diagnose.
#
# Nothing else on this machine uses these, and the VM is thrown away between
# runs anyway, so clearing them on the way in costs nothing and makes the
# start self-healing no matter how the previous session ended.
cleanup()
{
	if [ -f "$PIDFILE" ]; then
		kill "$(cat "$PIDFILE")" 2>/dev/null || true
		rm -f "$PIDFILE"
	fi
	pkill -f "$(basename "$SERVER")" 2>/dev/null || true
	sleep 1
	rm -f /dev/shm/sem.CommuniDLL_USB_Semaphore*
}

if [ "${1:-start}" = stop ]; then
	cleanup
	echo "OK: stopped"
	exit 0
fi

cleanup

# What e2 studio itself generates for this board, with three edits:
# -uAllowRRMDMM= 1, the work RAM moved off the startup bank, and _DUAL, which
# is the part on the Envision Kit.
#
# Each value is a separate argv element. Written the ordinary way,
# `-uUseFine=1` is an option with an *empty* value and is silently ignored;
# with every value attached that way the server reaches the emulator with
# almost no settings and dies at E20_set_clk() Failed, which reads like a
# clock problem and is not one.
args=(
	-g E2LITE -t R5F565NE_DUAL -p "$PORT" -d "$AUXPORT"
	-uConnectionTimeout= 30 -uClockSrcHoco= 1 -uPTimerClock= 120000000
	-uAllowClockSourceInternal= 1 -uUseFine= 0 -uJTagClockFreq= 6.00
	-w 0 -z 0 -uRegisterSetting= 0 -uModePin= 0
	-uChangeStartupBank= 0 -uStartupBank= 0 -uDebugMode= 0
	-uExecuteProgram= 0 -uIdCode= FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
	-uresetOnReload= 1 -n 0 -uWorkRamAddress= 8000
	-uverifyOnWritingMemory= 0 -uProgReWriteIRom= 0 -uProgReWriteDFlash= 0
	-uhookWorkRamAddr= 0x3fdd0 -uhookWorkRamSize= 0x230
	-uOSRestriction= 0 -l -uCore= 'SINGLE_CORE|enabled|1|main'
	-uSyncMode= async -uFirstGDB= main -uAllowRRMDMM= 1
)

if [ "$HOTPLUG" = 1 ]; then
	args+=(-uHotPlug= 1 -uResetBeginConnection= 0)
fi

"$SERVER" "${args[@]}" > "$LOG" 2>&1 &
echo $! > "$PIDFILE"

# The server prints its failure and exits; there is no point waiting for a
# port that a dead process will never open.
for i in $(seq 20); do
	sleep 1
	kill -0 "$(cat "$PIDFILE")" 2>/dev/null || {
		echo "server exited:" >&2
		tail -20 "$LOG" >&2
		rm -f "$PIDFILE"
		exit 1
	}
	if grep -q "$PORT" <(ss -ltn 2>/dev/null) 2>/dev/null; then
		echo "OK: listening on $PORT (log: $LOG)"
		exit 0
	fi
done

echo "server is up but never opened $PORT; see $LOG" >&2
exit 1
