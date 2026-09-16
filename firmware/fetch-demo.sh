#!/bin/bash
# Fetch one MiniWin EnvisionDemo's sources.
#
#   bash fetch-demo.sh                 # EnvisionDemo1 (display + touch)
#   bash fetch-demo.sh EnvisionDemo3   # both display buffers + GPIO interrupt
#
# Sources are fetched rather than vendored, so they stay under their upstream
# licence at miniwinwm/RenesasEnvisionGCC.
#
# The toolchain is a separate step — see install-toolchain.sh.
set -euo pipefail

DEMO="${1:-EnvisionDemo1}"
UPSTREAM="https://raw.githubusercontent.com/miniwinwm/RenesasEnvisionGCC/master"
API="https://api.github.com/repos/miniwinwm/RenesasEnvisionGCC/contents"

mkdir -p "$DEMO/src" "$DEMO/generate"

# src/ differs per demo, so take whatever it actually contains.
curl -fsSL "$API/$DEMO/src" \
    | grep -oE '"name": "[^"]+\.[ch]"' | cut -d'"' -f4 \
    | while read -r f; do
          curl -fsSL -o "$DEMO/src/$f" "$UPSTREAM/$DEMO/src/$f"
      done

# generate/ is the e2 studio-produced startup: vectors, reset code, linker
# script. It is what makes a Makefile build possible at all.
for f in hwinit.c interrupt_handlers.h inthandler.c iodefine.h \
         linker_script.ld start.S typedefine.h vects.c; do
    curl -fsSL -o "$DEMO/generate/$f" "$UPSTREAM/$DEMO/generate/$f"
done

# Enlarge the user stack. Upstream's own README tells you to do this when
# setting a project up — "In .ustack Output Section change ... from 0x200 to
# 0x500 ... change .data to 0x504" — but the committed linker script still
# ships the 0x200 default.
#
# As committed, .ustack tops out at 0x200 and .istack at 0x100 sits directly
# below it, so the user stack is 256 bytes. EnvisionDemo1 survives one touch
# and then corrupts itself: the second reading comes back as 0,0 and the third
# hangs the board. 0x500 gives it 1KB, which is what the README's companion
# setting ("warn if stack size exceeds 1000") expects.
LD="$DEMO/generate/linker_script.ld"
if grep -q '\.ustack 0x200' "$LD"; then
    sed -i -e 's/^\(\s*\)\.ustack 0x200: AT(0x200)/\1.ustack 0x500: AT(0x500)/' \
           -e 's/^\(\s*\)\.data 0x204: AT(_mdata)/\1.data 0x504: AT(_mdata)/' "$LD"
    echo "patched $LD: user stack 0x200 -> 0x500"
fi

echo "fetched:"
ls "$DEMO/src"
echo "now: make DEMO=$DEMO"
