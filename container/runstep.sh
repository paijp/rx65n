#!/bin/bash
# Program a build, run it for a while, and say what happened - without
# anyone looking at the board.
#
#   bash runstep.sh /tmp/diag9s1.mot /tmp/diag9s1.elf 120
#
# Run inside the VM. Prints a verdict and leaves the capture in $OUT.
#
# This is the piece that makes a test something a machine can run. Every
# other route to "did it keep going" has needed a person: the screen needs
# eyes, and the ring buffer needs the target halted, which ends the run the
# question is about. The debug console is neither - it arrives on a socket
# while the program runs, so the answer can be read from here.
#
# What it reports, and why each one:
#
#   fault      the fault handler's hardware breakpoint was hit, so an
#              exception happened and which vector is in r1
#   stalled    output stopped before the run did. diag9 prints at least
#              once a second, so a gap is the program stopping - this is
#              the case that used to need someone watching a screen
#   running    output was still arriving at the end
#   no-start   nothing ever arrived, which is a different failure from
#              stopping and usually means the chain, not the program
#
# It cannot see a program that stops while continuing to print, and it
# cannot see the screen. Neither has come up, but neither is covered.
set -euo pipefail

MOT="${1:?usage: runstep.sh <file.mot> <file.elf> [seconds]}"
ELF="${2:?usage: runstep.sh <file.mot> <file.elf> [seconds]}"
SECS="${3:-120}"

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-/tmp/dbgcon.log}"

BREAK="${BREAK:-rx65n_fault}" bash "$HERE/logrun.sh" "$MOT" "$ELF" > /tmp/runstep.log 2>&1 || {
	echo "VERDICT: no-start (the chain did not come up)"
	tail -5 /tmp/runstep.log
	exit 1
}

# Half way through, so a stall in the second half is still visible as one
# rather than as an end-of-run that happened to be quiet.
sleep $(( SECS / 2 ))
half=$(wc -c < "$OUT" 2>/dev/null || echo 0)
sleep $(( SECS - SECS / 2 ))
end=$(wc -c < "$OUT" 2>/dev/null || echo 0)

hits=$(bash "$HERE/gdbctl.sh" log 0 2>/dev/null \
       | grep -oE 'rx65n_fault",file[^}]*times="[0-9]+"' \
       | grep -oE '[0-9]+"$' | tr -d '"' | tail -1)
hits="${hits:-0}"

echo "bytes: $half at half time, $end at the end"
echo "fault handler hits: $hits"

# The target can also stop somewhere that is not the fault handler - a trap
# gdb reports as SIGTRAP at an ordinary address. Asking only "was the handler
# hit" called one of those "silent, no fault", on a board that had stopped in
# its first second.
other=$(bash "$HERE/gdbctl.sh" log 0 2>/dev/null \
	| grep '^\*stopped' | grep -v 'rx65n_fault' | grep -v 'PowerON_Reset' | tail -1 \
	|| true)

if [ "$hits" != 0 ]; then
	echo "VERDICT: fault"
	bash "$HERE/gdbctl.sh" send '-data-list-register-values x 1 16 17' >/dev/null 2>&1
	sleep 3
	bash "$HERE/gdbctl.sh" send '-stack-list-frames' >/dev/null 2>&1
	sleep 4
	bash "$HERE/gdbctl.sh" log 0 | grep -E 'register-values|stack=' | tail -2

	# The fault lands at an address nothing lives at, so gdb's backtrace
	# stops there. The user stack still holds the return addresses of the
	# calls that led to it, and those are the useful part: read it from
	# USP up to the top of the stack and name every word that points
	# into code.
	usp=$(bash "$HERE/gdbctl.sh" log 0 \
		| grep -oE '\{number="16",value="0x[0-9a-f]+"' | tail -1 \
		| grep -oE '0x[0-9a-f]+' || true)
	if [ -n "$usp" ]; then
		# Start 32 bytes below USP. A return that popped a bad address
		# leaves that address in the popped slot - memory is not cleared
		# on the way back up - and that slot is exactly the one a read
		# from USP upward would miss. Slots below USP are marked.
		base=$(( usp - 32 ))
		n=$(( 0x500 - base ))
		[ "$n" -gt 0 ] && [ "$n" -le 1024 ] || n=160
		bash "$HERE/gdbctl.sh" send "-data-read-memory-bytes $base $n" >/dev/null 2>&1
		sleep 4
		hex=$(bash "$HERE/gdbctl.sh" log 0 | grep -oE 'contents="[0-9a-f]+"' \
			| tail -1 | grep -oE '[0-9a-f]{8,}' || true)
		echo "--- stack from $(printf 0x%x $base) (USP $usp): every word, code named"
		i=0
		while [ $(( i * 8 )) -lt ${#hex} ]; do
			w=${hex:$(( i * 8 )):8}
			v="0x${w:6:2}${w:4:2}${w:2:2}${w:0:2}"
			a=$(( base + i * 4 ))
			mark=" "
			[ "$a" -lt $(( usp )) ] && mark="-"
			s=""
			if [ $(( v )) -ge $(( 0xfff00000 )) ]; then
				bash "$HERE/gdbctl.sh" send \
					"-interpreter-exec console \"info symbol $v\"" >/dev/null 2>&1
				sleep 1
				s=$(bash "$HERE/gdbctl.sh" log 0 | grep -oE '~"[^"]* in section [^"]*"' \
					| tail -1 | sed 's/^~"//; s/ in section.*//')
			fi
			printf ' %s[0x%x] %s  %s\n' "$mark" "$a" "$v" "$s"
			i=$(( i + 1 ))
		done
	fi
elif [ -n "$other" ]; then
	echo "VERDICT: stopped (not at the fault handler)"
	echo "$other" | grep -oE 'reason="[^"]*"|signal-name="[^"]*"|addr="[^"]*"|func="[^"]*"|line="[^"]*"' | tr '\n' ' '
	echo
elif [ "$end" = 0 ]; then
	# logrun.sh got as far as releasing the target, so the chain came up.
	# A build with the console switched off prints nothing by design, and
	# calling that no-start - as this did at first - reported a clean
	# two-minute run as a failure to boot. All that can be said here is
	# that no fault reached a handler; whether it kept running needs eyes.
	echo "VERDICT: silent (no console output; no fault in ${SECS}s)"
elif [ "$end" = "$half" ]; then
	echo "VERDICT: stalled (no output in the second half)"
else
	echo "VERDICT: running"
fi

echo "--- last of the capture"
tail -8 "$OUT" 2>/dev/null || true
