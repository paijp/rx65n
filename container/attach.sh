#!/bin/bash
# Run inside the VM (see run-vm.sh for how to get a shell there).
# Claims the E2 Lite that setup-pi.sh exported and proves it enumerated.
set -euo pipefail

SERVER="${SERVER:-10.88.0.1}"     # podman bridge gateway = where the SSH tunnel listens
BUSID="${BUSID:-}"
VID_PID="${VID_PID:-045b:82a0}"

sudo modprobe vhci-hcd

if [ -z "$BUSID" ]; then
    BUSID=$(sudo usbip list -r "$SERVER" | grep -oP '^\s+\K[0-9.-]+(?=:)' | head -1)
fi
[ -n "$BUSID" ] || { echo "no exportable device on $SERVER" >&2; exit 1; }

sudo usbip attach -r "$SERVER" -b "$BUSID"
sleep 3

echo "== usbip port =="
sudo usbip port
echo "== lsusb =="
lsusb
lsusb -d "$VID_PID" >/dev/null || { echo "device did not enumerate" >&2; exit 1; }
echo "OK: $VID_PID is present in this VM"

# Detach with:  sudo usbip detach -p 0
