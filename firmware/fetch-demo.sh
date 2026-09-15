#!/bin/bash
# Fetch the GNU RX toolchain and one MiniWin EnvisionDemo's sources.
#
#   bash fetch-demo.sh                 # EnvisionDemo1 (display + touch)
#   bash fetch-demo.sh EnvisionDemo3   # both display buffers + GPIO interrupt
#
# Nothing here is vendored into this repository — the demo sources belong to
# miniwinwm/RenesasEnvisionGCC and are fetched at their upstream licence.
set -euo pipefail

DEMO="${1:-EnvisionDemo1}"
UPSTREAM="https://raw.githubusercontent.com/miniwinwm/RenesasEnvisionGCC/master"

# GCC 14.2.0 for rx-elf, prebuilt and downloadable without a Renesas account.
# Renesas' own GNU RX is behind a login; this one is not. It ships no newlib,
# which is why the build is freestanding — see shim/.
TC_URL="https://github.com/Bud-ro/gcc-rx-zig/releases/download/14.2.0-full/rx-elf-toolchain-linux-x86_64.tar.gz"

if [ ! -x toolchain/bin/rx-elf-gcc ]; then
    echo "fetching toolchain..."
    curl -fsSL -o /tmp/rx-tc.tar.gz "$TC_URL"
    mkdir -p toolchain
    tar xzf /tmp/rx-tc.tar.gz -C toolchain --strip-components=1
    rm -f /tmp/rx-tc.tar.gz
fi
toolchain/bin/rx-elf-gcc --version | head -1

echo "fetching $DEMO..."
mkdir -p "$DEMO/src" "$DEMO/generate"

# src/ differs per demo, so take whatever it actually contains.
curl -fsSL "https://api.github.com/repos/miniwinwm/RenesasEnvisionGCC/contents/$DEMO/src" \
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

echo "fetched:"
ls "$DEMO/src"
echo "now: make DEMO=$DEMO"
