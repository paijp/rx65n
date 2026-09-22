#!/bin/bash
# Run inside the VM, after attach.sh has claimed the E2 Lite.
# Programs an S-record onto the board.
#
#   bash flash.sh lcdtp.mot           # program and start it
#   NORUN=1 bash flash.sh lcdtp.mot   # program and leave it stopped
#
# rfp-cli's -run releases reset and the program starts; without it the
# default is -reset, which resets the device after disconnecting and does not
# release it.
#
# Which one to use depends on how the log is going to be read, and the two
# sinks want opposite things.
#
# The ring buffer (debuglog.h) is read out of a live target, so -run is what
# finishes the job there: the board runs, and the debugger comes along later
# to stop it and read the history.
#
# The debug console (dbgcon.h) wants NORUN. The emulator only drains the
# console while it holds execution control, so that path resets the target
# under the debugger anyway - and with -run the program has been running
# unobserved for the thirty-odd seconds the server takes to connect, doing
# whatever it does, possibly including crashing. NORUN removes that window:
# nothing executes until the debugger releases it with the socket already
# open, so the capture starts at the program's first byte.
set -euo pipefail

MOT="${1:?usage: flash.sh <file.mot>}"
RFP="${RFP:-/opt/rfp/rfp-cli}"
NORUN="${NORUN:-0}"

[ -f "$MOT" ] || { echo "no such file: $MOT" >&2; exit 1; }
head -c 2 "$MOT" | grep -q '^S0' || { echo "not an S-record: $MOT" >&2; exit 1; }

# -if uart, not -if fine. FINE is the obvious choice for an E2 Lite on RX and
# gets as far as connecting the emulator, then fails with E3000105 as though
# the target were dead. See ../README.md.
#
# The id is the blank-device default: an unlocked RX65N answers to all-FF.
if [ "$NORUN" = 1 ]; then
    set -- -reset
else
    set -- -run
fi

"$RFP" -d RX65x -t e2l -if uart \
    -auth id FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF \
    -p "$MOT" -v "$@"

if [ "$NORUN" = 1 ]; then
    echo "OK: $MOT programmed and verified, target left stopped"
else
    echo "OK: $MOT programmed, verified, and running"
fi

# Two things worth knowing before the next step:
#
# Re-attach the emulator over usbip before starting the GDB server. Left as
# rfp-cli leaves it, the server fails with "can not connect to the emulator"
# on hardware that is in perfect health; a detach and attach clears it.
#
# That is for the -run case. With NORUN=1 the server connected straight
# afterwards with no re-attach at all, first time of asking, where -run had
# needed the detach-and-attach every time. One observation, so not a rule
# yet - but if the "can not connect to the emulator" state turns out to be
# something -run leaves behind, this is where it will show.
#
# To put the board back to running *without* rewriting flash, rfp-cli with
# -run and no program operation is enough:
#
#   rfp-cli -d RX65x -t e2l -if uart -auth id FF...FF -run
#
# It prints "No operation" and returns, having connected and released the
# target: the program starts. That is the only way found to get the board
# running again after a GDB session, which resets it and does not let go.
