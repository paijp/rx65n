#!/bin/bash
# Fetch the RX65N Envision Kit factory firmware (drives the on-board LCD).
#
# This is Renesas' own initial firmware image for the kit, so flashing it
# restores the board to how it shipped rather than replacing the demo with
# something else — a good first payload when you want to prove the toolchain
# end to end without losing anything.
#
# Verified: rfp-cli parses it as Size=6390200, CRC=58700822.
set -euo pipefail

REPO="https://raw.githubusercontent.com/renesas-rx/rx65n-envision-kit/master"
SRC="$REPO/initial_firmware/02_rx65n_envisionkit_test/bin/rx65n_envisionkit_initial_firmware.mot"
OUT="${1:-fw.mot}"

curl -fsSL --max-time 180 -o "$OUT" "$SRC"

# S0 header, S3 data records, S7 terminator.
head -c 2 "$OUT" | grep -q '^S0' || { echo "not an S-record: $OUT" >&2; exit 1; }
echo "$OUT: $(wc -c < "$OUT") bytes, $(wc -l < "$OUT") records"
sha256sum "$OUT"
