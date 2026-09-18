#!/bin/bash
# Run inside the VM, after attach.sh has claimed the E2 Lite.
# Programs an S-record onto the board and leaves the program running.
#
#   bash flash.sh lcdtp.mot
#
# Leaving it running is the point: the debug log is read out of a *live*
# target, so a flash that halts the board has not finished the job. rfp-cli's
# -run does the reset-and-go, and it is the last thing that touches the
# emulator before e2-server-gdb wants it.
set -euo pipefail

MOT="${1:?usage: flash.sh <file.mot>}"
RFP="${RFP:-/opt/rfp/rfp-cli}"

[ -f "$MOT" ] || { echo "no such file: $MOT" >&2; exit 1; }
head -c 2 "$MOT" | grep -q '^S0' || { echo "not an S-record: $MOT" >&2; exit 1; }

# -if uart, not -if fine. FINE is the obvious choice for an E2 Lite on RX and
# gets as far as connecting the emulator, then fails with E3000105 as though
# the target were dead. See ../README.md.
#
# The id is the blank-device default: an unlocked RX65N answers to all-FF.
"$RFP" -d RX65x -t e2l -if uart \
    -auth id FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF \
    -p "$MOT" -v -run

echo "OK: $MOT programmed, verified, and running"
