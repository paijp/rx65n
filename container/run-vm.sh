#!/bin/bash
# Boot the VM built by build-vm.sh.
#
# The guest's SSH is forwarded to 127.0.0.1:2222 *inside this container*:
#
#   podman exec rx65n-vm ssh -i /vm/id_vm -p 2222 \
#       -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
#       ubuntu@127.0.0.1
#
# The guest reaches the usbip server through slirp: outbound traffic is
# NAT'd out of the container, so the podman bridge gateway (10.88.0.1 by
# default) is the address to hand to `usbip attach -r`.
set -euo pipefail

cd /vm

exec qemu-system-x86_64 -accel tcg -machine q35 -m 768 -smp 2 -display none \
    -serial file:/vm/console.log \
    -drive file=disk.qcow2,if=virtio,format=qcow2 \
    -drive file=seed.iso,if=virtio,format=raw \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 \
    -device virtio-net-pci,netdev=n0
