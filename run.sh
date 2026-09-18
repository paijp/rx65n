#!/bin/bash
# Build, flash and read the log - the whole chain, from a Pi that was wiped
# since last time.
#
#   bash run.sh                  # sample1
#   MAIN=diag1 bash run.sh       # the touch bring-up display
#
# Run this on the VPS. It expects:
#   - PI      an ssh destination for the Raspberry Pi holding the board
#   - the VM image already built (container/build-vm.sh), rfp-cli installed
#     in it (container/install-rfp.sh)
#
# Each step is idempotent and each is also runnable on its own; this only
# puts them in the order that works, so that getting a log back is one
# command rather than a sequence anyone has to remember correctly.
set -euo pipefail

PI="${PI:?set PI to an ssh destination for the Raspberry Pi, e.g. pi@192.168.1.10}"
MAIN="${MAIN:-sample1}"
VM="${VM:-rx65n-vm}"
HERE="$(cd "$(dirname "$0")" && pwd)"

vmsh()
{
	podman exec -i "$VM" ssh -i /vm/id_vm -p 2222 \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		ubuntu@127.0.0.1 "$@"
}

echo "== 1/5 build"
podman run --rm -v "$HERE/firmware":/work:Z -w /work rx65n-fw \
	bash -c "MAIN=$MAIN bash fetch-lcdtp.sh && make DEMO=lcdtp"

echo "== 2/5 export the emulator from the Pi"
# The Pi is reinstalled between sessions, so this reinstalls usbip every
# time rather than assuming last session's state survived.
ssh "$PI" 'bash -s' < "$HERE/container/setup-pi.sh"

echo "== 3/5 attach it in the VM"
vmsh 'bash -s' < "$HERE/container/attach.sh"

echo "== 4/5 flash and run"
vmsh 'cat > /tmp/lcdtp.mot' < "$HERE/firmware/lcdtp.mot"
vmsh 'bash -s' -- /tmp/lcdtp.mot < "$HERE/container/flash.sh"

# At this point the board is running the new firmware. Everything below is
# the debug log, which is the part that is still not reliable: if it fails,
# the program on the board is unaffected and diag1 puts the same information
# on the screen.
echo "== 5/5 debug log"
# readlog.py resolves the log buffer's address out of the ELF, so the ELF has
# to travel with the S-record.
vmsh 'cat > /tmp/lcdtp.elf' < "$HERE/firmware/lcdtp.elf"
vmsh 'cat > /tmp/readlog.py' < "$HERE/firmware/lcdtp/tools/readlog.py"
vmsh 'bash -s' < "$HERE/container/gdbserver.sh" || {
	echo "gdb server did not come up; the board is running regardless" >&2
	exit 0
}
vmsh "python3 /tmp/readlog.py /tmp/lcdtp.elf --gdb /opt/e2gdb/rx-elf-gdb" || true
vmsh 'bash -s' -- stop < "$HERE/container/gdbserver.sh"
