#!/bin/bash
# Build the throwaway VM image that will run rfp-cli (the usbip *client* side).
#
# Runs once. Under TCG this takes roughly 10 minutes, almost all of it
# apt unpacking linux-modules-extra and regenerating the initramfs.
#
# Ubuntu is used rather than Debian on purpose: the Ubuntu cloud image
# already runs the *generic* kernel flavour, so `linux-modules-extra-$(uname -r)`
# drops vhci-hcd straight in. The Debian cloud image runs a trimmed `-cloud`
# kernel with no usbip modules at all, and swapping it out means installing
# linux-image-amd64, purging linux-image-*cloud-amd64 (the metapackage alone
# is not enough — the versioned package keeps GRUB booting the cloud kernel)
# and re-running update-grub. See README.md.
set -euo pipefail

cd /vm

# Override if this mirror is slow or unreachable from your network.
IMG_URL="${IMG_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"

if [ ! -f disk.qcow2 ]; then
    curl -fsSL -o disk.raw "$IMG_URL"
    mv disk.raw disk.qcow2
fi
qemu-img resize disk.qcow2 8G >/dev/null

# Throwaway key, generated in the container. Never leaves this container.
[ -f id_vm ] || ssh-keygen -t ed25519 -N '' -f id_vm -q

cat > user-data <<EOF
#cloud-config
ssh_authorized_keys:
  - $(cat id_vm.pub)
runcmd:
  - [ bash, -c, "echo ===SETUP_START===; echo KVER=\$(uname -r)" ]
  - [ bash, -c, "DEBIAN_FRONTEND=noninteractive apt-get -qq update >/dev/null 2>&1; echo APT_UPDATE=\$?" ]
  - [ bash, -c, "DEBIAN_FRONTEND=noninteractive apt-get -qq install -y linux-modules-extra-\$(uname -r) >/dev/null 2>&1 && echo 'MODULES_EXTRA: OK' || echo 'MODULES_EXTRA: FAIL'" ]
  - [ bash, -c, "DEBIAN_FRONTEND=noninteractive apt-get -qq install -y usbutils linux-tools-common linux-tools-\$(uname -r) >/dev/null 2>&1 && echo 'TOOLS: OK' || echo 'TOOLS: FAIL'" ]
  - [ bash, -c, "echo 'USBIP_BIN:'; command -v usbip" ]
  - [ bash, -c, "echo 'MODULES:'; ls /lib/modules/\$(uname -r)/kernel/drivers/usb/usbip/ 2>&1" ]
  - [ bash, -c, "modprobe vhci-hcd && echo 'MODPROBE_VHCI: OK' || echo 'MODPROBE_VHCI: FAIL'" ]
  - [ bash, -c, "printf 'vhci-hcd\n' > /etc/modules-load.d/usbip.conf" ]
  - [ bash, -c, "echo ===SETUP_DONE===" ]
power_state:
  mode: poweroff
  timeout: 5
EOF

printf 'instance-id: setup1\nlocal-hostname: rx65n-vm\n' > meta-data
cloud-localds seed.iso user-data meta-data

qemu-system-x86_64 -accel tcg -machine q35 -m 768 -smp 2 -display none \
    -serial file:/vm/setup.log \
    -drive file=disk.qcow2,if=virtio,format=qcow2 \
    -drive file=seed.iso,if=virtio,format=raw \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0

grep -aE 'MODULES_EXTRA|TOOLS:|MODPROBE_VHCI|SETUP_DONE' /vm/setup.log
