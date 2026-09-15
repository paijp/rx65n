#!/bin/bash
# Install Renesas Flash Programmer CLI into the VM.
#
# rfp-cli is not redistributable: download RFP_CLI_Linux_V*_x64.tgz yourself
# from Renesas (a myRenesas account login is required) and copy it in.
#
#   podman cp RFP_CLI_Linux_V32400_x64.tgz rx65n-vm:/vm/rfp.tgz
#   podman exec rx65n-vm scp -i /vm/id_vm -P 2222 \
#       -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
#       /vm/rfp.tgz ubuntu@127.0.0.1:/tmp/rfp.tgz
#   (then run this script inside the VM)
set -euo pipefail

TGZ="${1:-/tmp/rfp.tgz}"
DEST="${DEST:-/opt/rfp}"

sudo mkdir -p "$DEST"
sudo tar xzf "$TGZ" -C "$DEST" --strip-components=1

# Lets a non-root user open the emulator; harmless when running under sudo.
sudo install -m 644 "$DEST/99-renesas-emu.rules" /etc/udev/rules.d/
sudo udevadm control --reload-rules || true

"$DEST/rfp-cli" -v 2>&1 | head -3
ldd "$DEST/rfp-cli" | grep -i 'not found' && { echo "missing libraries" >&2; exit 1; }
echo "OK: rfp-cli installed in $DEST"
