#!/bin/bash
# Build a program, put it on the board, run it, and say what happened - from
# named commits, with nobody at the board.
#
#   bash run.sh diag9 -DDIAG9_STEP=1
#   SECS=300 NAME=s2 bash run.sh diag9 -DDIAG9_STEP=2
#   RX_REF=2bc8981 UI_REF=1da3779 bash run.sh diag9
#   BREAK='rx65n_fault *0' bash run.sh diag9     # also stop on a jump to 0
#
# Run on the VPS. Everything after the program name is passed to the
# compiler. Results go to $RESULTS/<timestamp>-<name>/:
#
#   build.txt   which commits, flags, toolchain and patches made the binary
#   verdict.txt runstep.sh's report: fault / stalled / running / no-start
#   console.log everything the program printed on the debug console
#   gdb.log     the gdb session, including the fault backtrace if there was one
#
# The point of the whole thing is that nothing in it is a copy. The firmware
# scripts and patches, the host-side scripts, and the program sources are
# all fetched fresh at commits resolved once at the top, and those commits
# are written into the result. A result that cannot be traced back to a
# commit cannot be compared with the next one, and comparing runs is the
# only thing these results are for.
#
# Needs, and does not set up: the rx65n-fw and rx65n-vm containers (see
# firmware/Containerfile and container/build-vm.sh), the VM running
# (container/run-vm.sh), and an ssh destination for the Raspberry Pi in $PI
# with the board plugged into it. The Pi being connected is the one step
# that needs a person.
set -euo pipefail

MAIN="${1:?usage: run.sh <program> [extra CFLAGS...]}"
shift
EXTRA="$*"

PI="${PI:-ras}"
SECS="${SECS:-120}"
NAME="${NAME:-$MAIN}"
FW="${FW:-rx65n-fw}"
VM="${VM:-rx65n-vm}"
RESULTS="${RESULTS:-/tmp/rx65n-results}"
RX_REPO="${RX_REPO:-paijp/rx65n}"
UI_REPO="${UI_REPO:-paijp/smallest-touchpanel-ui}"

# Every ssh to the Pi has a bound on how long it may wait. Without one,
# "the Pi is not connected" does not fail: localhost resolved to ::1, the SYN
# went unanswered, and the run sat there until TCP gave up minutes later,
# looking exactly like a slow step. BatchMode stops a missing key from
# turning into a password prompt nobody will answer.
PISSH=(ssh -o ConnectTimeout=10 -o BatchMode=yes
       -o ServerAliveInterval=5 -o ServerAliveCountMax=3)

sha_of()
{
	curl -fsSL "https://api.github.com/repos/$1/commits/$2" \
		| python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])'
}

vmsh()
{
	podman exec -i "$VM" ssh -i /vm/id_vm -p 2222 \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o LogLevel=ERROR ubuntu@127.0.0.1 "$@"
}

RX_SHA=$(sha_of "$RX_REPO" "${RX_REF:-main}")
UI_SHA=$(sha_of "$UI_REPO" "${UI_REF:-main}")
dir="$RESULTS/$(date +%Y%m%d-%H%M%S)-$NAME"
mkdir -p "$dir"
echo "rx65n $RX_SHA"
echo "ui    $UI_SHA"
echo "->    $dir"

echo "== 1/5 build"
podman exec "$FW" sh -c "
	set -e
	rm -rf /tmp/run && mkdir /tmp/run && cd /tmp/run
	curl -fsSL https://codeload.github.com/$RX_REPO/tar.gz/$RX_SHA \
		| tar xz --strip-components=2 --wildcards '*/firmware/build.sh'
	RX_REF=$RX_SHA UI_REF=$UI_SHA NAME=run bash build.sh $MAIN $EXTRA
" > "$dir/build.txt"
cat "$dir/build.txt"
podman cp "$FW:/work/out/run.mot" "$dir/prog.mot"
podman cp "$FW:/work/out/run.elf" "$dir/prog.elf"

echo "== 2/5 host scripts into the VM, from the same commit"
vmsh "rm -rf /tmp/c && mkdir -p /tmp/c && curl -fsSL \
	https://codeload.github.com/$RX_REPO/tar.gz/$RX_SHA \
	| tar xz -C /tmp/c --strip-components=2 --wildcards '*/container/*'"
vmsh 'cat > /tmp/prog.mot' < "$dir/prog.mot"
vmsh 'cat > /tmp/prog.elf' < "$dir/prog.elf"

echo "== 3/5 the emulator: export from the Pi, tunnel, attach"
# The Pi is reinstalled between sessions, so usbip is set up every time
# rather than trusting that last session's state survived.
# Two different failures, reported as two different things: the Pi not
# answering at all needs a person, setup failing on a Pi that did answer
# needs a look at pi.log.
"${PISSH[@]}" "$PI" true > /dev/null 2>&1 || {
	echo "no-start: the Pi did not answer on '$PI' - is it connected?" | tee "$dir/verdict.txt"
	exit 1
}
"${PISSH[@]}" "$PI" 'bash -s' < <(vmsh 'cat /tmp/c/setup-pi.sh') > "$dir/pi.log" 2>&1 || {
	echo "no-start: setup on the Pi failed, see pi.log" | tee "$dir/verdict.txt"
	tail -5 "$dir/pi.log"
	exit 1
}
if ! ss -lnt | grep -q '10.88.0.1:3240'; then
	"${PISSH[@]}" -f -N -L 10.88.0.1:3240:127.0.0.1:3240 "$PI"
	sleep 2
fi
# A device left attached from the last run, or a bind that usbipd did not
# pick up, both look like "no exportable devices". Unbinding and binding
# again on the Pi clears the second; detaching in the VM clears the first.
busid=$(grep -oE 'busid=[0-9.-]+' "$dir/pi.log" | head -1 | cut -d= -f2)
vmsh 'sudo usbip detach -p 00 >/dev/null 2>&1 || true'
if [ -n "$busid" ]; then
	"${PISSH[@]}" "$PI" "sudo usbip unbind -b $busid >/dev/null 2>&1; sleep 1;
		sudo usbip bind -b $busid >/dev/null 2>&1" > /dev/null 2>&1 || true
fi
vmsh 'bash /tmp/c/attach.sh' > "$dir/attach.log" 2>&1 || {
	echo "no-start: the emulator did not attach in the VM" | tee "$dir/verdict.txt"
	tail -5 "$dir/attach.log"
	exit 1
}

echo "== 4/5 flash, run for ${SECS}s, judge"
vmsh "cd /tmp/c && BREAK='${BREAK:-rx65n_fault}' bash runstep.sh /tmp/prog.mot /tmp/prog.elf $SECS" \
	> "$dir/verdict.txt" 2>&1 || true

echo "== 5/5 collect"
vmsh 'cat /tmp/dbgcon.log 2>/dev/null' > "$dir/console.log" || true
vmsh 'bash /tmp/c/gdbctl.sh log 0 2>/dev/null' > "$dir/gdb.log" || true

echo
cat "$dir/verdict.txt"
