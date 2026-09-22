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

if [ "$hits" != 0 ]; then
	echo "VERDICT: fault"
	bash "$HERE/gdbctl.sh" send '-data-list-register-values x 1 16 17' >/dev/null 2>&1
	sleep 3
	bash "$HERE/gdbctl.sh" send '-stack-list-frames' >/dev/null 2>&1
	sleep 4
	bash "$HERE/gdbctl.sh" log 0 | grep -E 'register-values|stack=' | tail -2
elif [ "$end" = 0 ]; then
	echo "VERDICT: no-start (nothing was ever printed)"
elif [ "$end" = "$half" ]; then
	echo "VERDICT: stalled (no output in the second half)"
else
	echo "VERDICT: running"
fi

echo "--- last of the capture"
tail -8 "$OUT" 2>/dev/null || true
