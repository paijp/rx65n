#!/bin/bash
# Assemble a buildable tree for the smallest-touchpanel-ui RX65N port.
#
#   bash install-toolchain.sh gcc-14.2.0.202607-GNURX-ELF-linux.tar.gz
#   bash fetch-lcdtp.sh
#   make DEMO=lcdtp                  # -> lcdtp.mot
#
# This is the replacement for fetch-demo.sh. That one builds a MiniWin
# EnvisionDemo, which only runs after patch-demo.py fixes two upstream bugs;
# this one builds paijp's own UI library, which is the sample we actually
# want on the board.
#
# Two upstreams, neither vendored here:
#
#   paijp/smallest-touchpanel-ui   the UI library and its RX65N port
#   miniwinwm/RenesasEnvisionGCC   generate/: vectors, startup, linker script
#                                  and iodefine.h
#
# generate/ is e2 studio's output for this chip. Nothing in it is specific to
# a demo, and reproducing it by hand - iodefine.h alone is tens of thousands
# of lines of register definitions - would be a large pile of code that could
# only be checked by running it.
set -euo pipefail

DEST="${DEST:-lcdtp}"
UI_REPO="${UI_REPO:-paijp/smallest-touchpanel-ui}"
UI_REF="${UI_REF:-main}"
GEN_UPSTREAM="https://raw.githubusercontent.com/miniwinwm/RenesasEnvisionGCC/master/EnvisionDemo1/generate"

rm -rf "$DEST"
mkdir -p "$DEST/src" "$DEST/generate"

# --- the port ---------------------------------------------------------------
# A whole-tree tarball rather than per-file curl: the file list is the port's
# to decide, so adding a file upstream should not mean editing this script.
# codeload rather than git, so the build container needs nothing but curl.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "https://codeload.github.com/$UI_REPO/tar.gz/refs/heads/$UI_REF" \
    | tar xz -C "$tmp"
ui=$(echo "$tmp"/*/rx65n)

cp "$ui"/*.c "$ui"/*.h "$DEST/src/"

# The port ships more than one program - sample1.c is the UI sample, the
# diagNs are bring-up - and they each define main(), so keep only the one
# being built.
#
#   MAIN=diag2 bash fetch-lcdtp.sh
#
# Found by looking for main() rather than by name, so a program added
# upstream does not also need a line here.
MAIN="${MAIN:-sample1}"
[ -f "$DEST/src/$MAIN.c" ] || { echo "no such program: $MAIN" >&2; exit 1; }
for f in "$DEST"/src/*.c; do
    [ "$f" = "$DEST/src/$MAIN.c" ] && continue
    grep -qE '^[a-zA-Z].*\bmain[[:space:]]*\(' "$f" && rm -f "$f"
done

# readlog.py is the host side of the debug log; keep it next to the build so
# it is to hand when the board is running.
mkdir -p "$DEST/tools"
# Files only: a stray directory in there (a __pycache__, say) would stop the
# script under set -e before generate/ had been fetched.
find "$ui/tools" -maxdepth 1 -type f -exec cp {} "$DEST/tools/" \;

# --- the startup ------------------------------------------------------------
for f in interrupt_handlers.h inthandler.c iodefine.h \
         linker_script.ld start.S typedefine.h vects.c hwinit.c; do
    curl -fsSL -o "$DEST/generate/$f" "$GEN_UPSTREAM/$f"
done

# The stack fix from patch-demo.py applies here too - it is a property of the
# linker script, not of the demo. The touch-driver patches do not: this port
# does not use that driver. patch-demo.py already skips them when
# src/touch_driver.c is absent, which it is.
python3 patch-demo.py "$DEST"

echo "sources:"
ls "$DEST/src"
echo "now: make DEMO=$DEST"
