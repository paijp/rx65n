#!/bin/bash
# Build the diag9 ladder: one .mot per step, each differing from the one
# before it in a single property.
#
#   bash ladder.sh            # steps 1..4
#   bash ladder.sh 2 3        # just those
#
# Run them in order, lowest first. Step 1 is the known-good baseline; if it
# stops, nothing above it is worth running until that is understood.
#
# Why build all of them now rather than one at a time: the board is usually
# on the other end of a link that has to be set up, and the useful unit of
# work there is "flash, watch, flash the next", not "wait for a compiler".
#
# Each step's ELF is kept beside its .mot because logrun.sh wants both - the
# .mot to program and the .elf for symbols, and mixing a .mot from one step
# with the .elf from another gives a backtrace that is quietly wrong.
set -euo pipefail

STEPS="${*:-1 2 3 4}"
DEST="${DEST:-lcdtp}"
BASE="-mcpu=rx64m -O2 -g -std=gnu99 -nostartfiles"
BASE="$BASE -Wno-error=incompatible-pointer-types"
BASE="$BASE -ffunction-sections -fdata-sections"

MAIN=diag9 bash fetch-lcdtp.sh > /dev/null

for s in $STEPS; do
	# The Makefile has no dependency on CFLAGS, so a changed -D does not
	# make anything look out of date. Without this every step after the
	# first is a copy of the first, under a different name, and the
	# experiment says nothing.
	rm -f "$DEST.elf" "$DEST.mot"

	make DEMO="$DEST" \
	     CFLAGS="$BASE -DDIAG9_STEP=$s -I$DEST/generate -I$DEST/src" \
	     > /dev/null
	cp "$DEST.mot" "diag9s$s.mot"
	cp "$DEST.elf" "diag9s$s.elf"
	echo "step $s: diag9s$s.mot $(wc -c < "diag9s$s.mot") bytes"
done

# Distinct sizes are not proof, but identical checksums are proof of a
# mistake, and this is where that mistake would otherwise go unnoticed.
echo
md5sum diag9s*.mot
