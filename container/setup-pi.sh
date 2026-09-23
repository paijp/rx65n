#!/bin/bash
# Run on the Raspberry Pi that has the E2 Lite plugged in.
# Exports the emulator over usbip so a remote machine can claim it.
#
#   ssh pi@raspberrypi 'bash -s' < setup-pi.sh
#
# Re-run after every reboot if the Pi's filesystem is volatile.
set -euo pipefail

VID_PID="${VID_PID:-045b:82a0}"   # Renesas E2 Lite

# Raspberry Pi OS ships the usbip modules in the stock kernel, but not the
# userspace tools. On bullseye the security pool has been pruned, so the
# version the index points at 404s; fall back to the version in the main
# archive. usbip lands in /usr/sbin, which is not on a non-login $PATH.
if ! [ -x /usr/sbin/usbip ]; then
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y usbip \
        || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
               --allow-downgrades usbip=2.0+5.10.223-1
fi

sudo modprobe usbip-host vhci-hcd
pgrep -x usbipd >/dev/null || sudo /usr/sbin/usbipd -D
sleep 1

BUSID=$(sudo /usr/sbin/usbip list -l | grep -B1 "$VID_PID" | grep -oP 'busid \K[0-9.-]+' | head -1)
if [ -z "$BUSID" ]; then
    echo "E2 Lite ($VID_PID) not found. Connected devices:" >&2
    lsusb >&2
    exit 1
fi

# A second run finds the device already bound from the first, and bind then
# fails - which is the state this script exists to produce, not an error.
# Treating it as one made run.sh report the Pi as unreachable on every run
# after the first.
if ! sudo /usr/sbin/usbip bind -b "$BUSID" 2>/tmp/usbip-bind.err; then
    grep -q "already bound" /tmp/usbip-bind.err || {
        cat /tmp/usbip-bind.err >&2
        exit 1
    }
fi
echo "exported busid=$BUSID"
sudo /usr/sbin/usbip list -r 127.0.0.1

# usbipd listens on 0.0.0.0:3240 with no authentication and no encryption.
# Do NOT expose 3240 to an untrusted network — reach it over an SSH tunnel:
#   (on the client host)  ssh -N -L 3240:127.0.0.1:3240 pi@raspberrypi
echo
echo "NOTE: port 3240 is unauthenticated. Tunnel it over SSH, do not expose it."
