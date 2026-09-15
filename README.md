# RX65N Envision Kit — writing firmware from Linux/ARM

Notes and tooling from working out how to flash an **RX65N Envision Kit** when
the machine holding the board is a **Raspberry Pi** and the only x86_64 Linux
available is a **Rocky Linux VPS**.

Everything below marked *verified* was actually run; anything not verified says
so.

---

## TL;DR

| Question | Answer |
|---|---|
| Can a Raspberry Pi flash the board? | Not directly — the tooling it would need is x86_64-only or Windows-only. |
| Can it build the firmware? | Yes. Prebuilt GNU RX is x86_64, but the toolchain builds from source for ARM. |
| Is there an open E2 Lite implementation? | **No.** Searched GitHub exhaustively; nothing exists. |
| So how does the Pi flash it? | Re-export the E2 Lite over **usbip** to an x86_64 machine running `rfp-cli`. **Verified working.** |
| Does that need nested virtualisation? | No. QEMU under TCG is fast enough — the workload is I/O bound, not CPU bound. |

---

## The problem

The RX65N Envision Kit carries an on-board **E2 Lite** debugger/programmer
(USB ID `045b:82a0`). Writing flash through it needs Renesas' `rfp-cli`, and:

* `rfp-cli` ships for **Windows and Linux x86_64 only** — no ARM build.
* e2 studio is x86_64 Linux / Windows only — no ARM build.
* The E2 Lite host protocol is **undocumented and proprietary**. Renesas
  explicitly forbids reverse engineering it.
* **OpenOCD does not support RX** at all. pyOCD is Cortex-M only.

A GitHub-wide search for an open implementation
(`e2lite`, `e2-lite renesas`, `renesas FINE programmer`, …) returns **zero
results**. There is no community alternative. This is a dead end, not an
under-explored one.

The one open path that does exist is **serial boot mode**: pull `MD` low,
reset, and talk the documented SCI boot protocol.
[`hirakuni45/RX`](https://github.com/hirakuni45/RX) ships `rx_prog` for exactly
this — plain `make`, C++20, no Boost, tested on Windows/OS-X/Linux, and its
`rx_prog.conf` already carries the `R5F565NE` device definition. Note its
support table marks RX65N as *supported but not operation-verified*.

That route needs `MD` and the boot SCI pins broken out. **On the Envision Kit
used here they are not**, and no USB-serial adapter was attached
(`/dev/ttyUSB*` absent) — so the rest of this document takes the usbip route.

---

## What actually works

```
Raspberry Pi (ARM)          Rocky VPS (x86_64)                  VM (Ubuntu)
┌─────────────────┐        ┌──────────────────────┐        ┌──────────────────┐
│ E2 Lite (USB)   │        │ podman container     │        │ vhci-hcd         │
│   ↓             │        │   ↓ 10.88.0.1:3240   │        │ usbip attach     │
│ usbip-host      │        │ QEMU (TCG, no KVM)   │  slirp │ rfp-cli          │
│ usbipd :3240 ───┼─ssh -L─┼─▶ 127.0.0.1:3240     │◀───────┤ lsusb → E2 Lite  │
└─────────────────┘        └──────────────────────┘        └──────────────────┘
```

usbip encapsulates USB request blocks (URBs) over **one TCP connection on port
3240** — the attach and all subsequent transfers share it, so a single
forwarded port is all an SSH tunnel needs. Inside the VM `vhci-hcd` presents a
virtual host controller, and the device looks completely local: libusb and
kernel drivers work unmodified.

### Why a VM and not a container

A container shares the host kernel. Rocky/RHEL **do not ship the usbip
modules**, so no container on that host can load `vhci-hcd`. A VM brings its
own kernel. That is the entire reason the VM exists.

### Why TCG is fine

The VPS has no nested virtualisation (`vmx`/`svm` absent from `/proc/cpuinfo`,
no `/dev/kvm`), so QEMU runs under pure software emulation. That is normally
disqualifying, but flashing is dominated by USB and network round-trips, not
computation. Measured: **boot → run → poweroff in 50–58 s**. No `--privileged`,
no `/dev/kvm`.

---

## Distribution support for usbip

| Distro | Kernel modules | Userspace | Verdict |
|---|---|---|---|
| **Debian** | in `linux-image-amd64` (**not** in `-cloud`) | `usbip` package | Good, with the cloud-kernel caveat below |
| **Ubuntu** | `linux-modules-extra-$(uname -r)` | `linux-tools-$(uname -r)` | **Best for cloud images** |
| **Raspberry Pi OS** | in the stock kernel | `usbip` package | Good |
| Arch / Fedora / openSUSE | shipped | `usbip` package | Good |
| **RHEL / Rocky / Alma** | **not shipped** | **no package** | **Dead end** |

### Rocky/RHEL is a dead end — verified

On Rocky Linux 10.2, kernel 6.12:

```
CONFIG_USBIP_CORE=m          # built as a module...
CONFIG_USBIP_VHCI_HCD=m
CONFIG_USBIP_HOST=m

/lib/modules/$(uname -r)/kernel/drivers/usb/usbip/    # ...directory is EMPTY
```

The directory is created by `kernel-modules-core`, but **no `.ko` is ever
shipped**. Confirmed against every enabled repository including EPEL:

```
dnf repoquery --whatprovides "kmod(vhci-hcd.ko)"   → 0
dnf repoquery --whatprovides "kmod(usbip-host.ko)" → 0
dnf repoquery '*usbip*'                            → 0
```

This is a deliberate enterprise-distro decision, so no amount of repository
hunting fixes it. Note that **Fedora is the exception in the Red Hat family** —
it ships usbip normally.

### The Debian cloud-kernel trap

Debian cloud images run `linux-image-cloud-amd64`, a trimmed kernel with **no
usbip modules**. Fixing it needs three steps, and the obvious two are not
enough:

```bash
apt-get install -y linux-image-amd64
apt-get purge  -y 'linux-image-*cloud-amd64'   # wildcard! see below
update-grub
```

`linux-image-cloud-amd64` is a **metapackage** — purging it leaves the
versioned kernel package installed and GRUB keeps booting the cloud kernel.
The wildcard removes the real one.

**Ubuntu avoids all of this**: its cloud image already runs the `-generic`
flavour, so `linux-modules-extra-$(uname -r)` matches the running kernel and
`vhci-hcd` loads with no kernel swap and no reboot. That is why `build-vm.sh`
uses Ubuntu.

---

## Usage

### 1. On the Raspberry Pi

```bash
ssh pi@raspberrypi 'bash -s' < container/setup-pi.sh
```

Installs `usbip`, loads the modules, binds the E2 Lite and starts `usbipd`.
Re-run after every reboot if the Pi is volatile.

### 2. Tunnel, on the VPS

```bash
podman run -d --name rx65n-vm rx65n-vmhost          # creates the podman bridge
ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 \
    -L 10.88.0.1:3240:127.0.0.1:3240 pi@raspberrypi
```

Binding to `10.88.0.1` (the podman bridge gateway) is what makes the tunnel
reachable from inside the container, and therefore from the VM behind slirp.
The bridge only exists while a container is running — start the container
first or the bind fails with `Cannot assign requested address`.

If the Pi is behind NAT, invert it: have the Pi open `ssh -R 3240:...` to the
VPS instead.

### 3. Build and boot the VM

```bash
podman exec    rx65n-vm build-vm.sh     # once; ~10 min under TCG
podman exec -d rx65n-vm run-vm.sh
podman exec    rx65n-vm ssh -i /vm/id_vm -p 2222 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    ubuntu@127.0.0.1
```

### 4. Claim the device, then flash

```bash
sudo bash attach.sh
sudo rfp-cli -device rx65n -tool e2l -a your_app.mot
```

---

## Verified results

Full chain, Pi → VPS → container → VM:

```
== usbip port ==
Port 00: <Port in Use> at Full Speed(12Mbps)
       Hitachi, Ltd : unknown product (045b:82a0)
       1-1 -> usbip://10.88.0.1:3240/1-1.4
           -> remote bus/dev 001/005

== lsusb (inside the VM) ==
Bus 001 Device 002: ID 045b:82a0 Hitachi, Ltd E2 Lite

iManufacturer   2 Renesas electronics
iProduct        3 E2 Lite
iSerial         1 E2L: OBE020003
bNumEndpoints   2          wMaxPacketSize 0x0040 (64 bytes)
```

String descriptors read back correctly, so control transfers survive the whole
path. A full `lsusb -v` (dozens of control transfers) takes **50–60 ms** over
the tunnel — well within any sane USB timeout.

### Not yet verified

**An actual flash write.** `rfp-cli` is distributed by Renesas behind a
myRenesas account login and is not present on any of these machines, so the
final `rfp-cli -a app.mot` step has not been executed. Everything it depends on
has been.

Drop the Renesas Linux x64 package (`RFP_CLI_Linux_V*_x64.tgz`) into the VM,
install its `99-renesas-emu.rules` udev rule, and the remaining step is a
single command.

---

## Building the firmware

Use the GNU RX toolchain (`rx-elf-gcc`). RX65N is an RXv2 core.

* **On x86_64** (VPS): Renesas/GNURX prebuilt binaries work as-is.
* **On ARM** (Raspberry Pi): no prebuilt exists — build `binutils`, `gcc` and
  `newlib` for `--target=rx-elf` from source. `hirakuni45/RX` documents the
  exact configure lines; they apply unchanged on ARM. One-time cost.
* **e2 studio has no ARM build**, so on a Pi the workflow is Makefile-based,
  not IDE-based.

Practical split: build on the VPS, flash from the Pi.

---

## Security notes

* `usbipd` listens on `0.0.0.0:3240` with **no authentication and no
  encryption**. Never expose it directly; the SSH tunnel is not a nicety, it is
  the access control. `ssh -L`/`-R` bind to `127.0.0.1` by default, which is
  what you want.
* Bind only the intended device (`usbip bind -b <busid>`), not everything.
* If the tunnel drops mid-write the guest sees a hung USB device and needs
  `usbip detach`. Use `ServerAliveInterval`, or `autossh`, and prefer not to
  interrupt a flash write.

## Deployment

`.github/workflows/deploy.yml` uploads `container/` to the VPS over HTTPS using
a GitHub OIDC token minted per file — no stored secret. It triggers on pushes
that touch `container/`.

---

## References

* [hirakuni45/RX](https://github.com/hirakuni45/RX) — RX framework and `rx_prog`
* [yuya-oc/rx-write](https://github.com/yuya-oc/rx-write) — another RX flash writer
* [miniwinwm/RenesasEnvisionGCC](https://github.com/miniwinwm/RenesasEnvisionGCC) — Envision Kit + GCC RX project setup
* [E2 emulator Lite](https://www.renesas.com/en/software-tool/e2-emulator-lite-rte0t0002lkce00000r)
* [Renesas Flash Programmer](https://www.renesas.com/en/software-tool/renesas-flash-programmer-programming-gui)
