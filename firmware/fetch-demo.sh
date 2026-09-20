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
shift || true
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

# --bitbang swaps the demo's SCI6 simple-IIC for the port's bit-banged I2C,
# which needs the port's i2c.h beside the demo's sources. Fetched, not
# vendored, like everything else here; it is Apache 2.0 and the demo is MIT,
# and nothing assembled here is redistributed.
case " $* " in
*" --bitbang "*)
    UI="https://raw.githubusercontent.com/paijp/smallest-touchpanel-ui/main/rx65n"
    for f in i2c.h basic.h; do
        curl -fsSL -o "$DEMO/src/$f" "$UI/$f"
    done
    ;;
esac

# The sources do not run as shipped — see patch-demo.py for what and why.
# Pass --status-on-lcd to also print the touch driver's state to the screen.
python3 patch-demo.py "$DEMO" "$@"

echo "fetched:"
ls "$DEMO/src"
echo "now: make DEMO=$DEMO"
