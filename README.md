# RX65N Envision Kit — writing firmware from Linux/ARM

Notes and tooling from working out how to flash an **RX65N Envision Kit** when
the machine holding the board is a **Raspberry Pi** and the only x86_64 Linux
available is a **Rocky Linux VPS**.

This works end to end: firmware built on the VPS has been erased, programmed
and verified onto the board across the whole chain. Everything below was
actually run; anything that was not is said to be.

---

## TL;DR

| Question | Answer |
|---|---|
| Can a Raspberry Pi flash the board? | Not directly — the tooling it would need is x86_64-only or Windows-only. |
| Can it build the firmware? | Yes. Prebuilt GNU RX is x86_64, but the toolchain builds from source for ARM. |
| Is there an open E2 Lite implementation? | **No.** Searched GitHub exhaustively; nothing exists. |
| So how does the Pi flash it? | Re-export the E2 Lite over **usbip** to an x86_64 machine running `rfp-cli`. **Done — firmware is on the board.** |
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

### 4. Install rfp-cli in the VM

`rfp-cli` is not redistributable — download `RFP_CLI_Linux_V*_x64.tgz` from
Renesas yourself (a myRenesas login is required), then:

```bash
podman cp RFP_CLI_Linux_V32400_x64.tgz rx65n-vm:/vm/rfp.tgz
podman exec rx65n-vm scp -i /vm/id_vm -P 2222 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    /vm/rfp.tgz ubuntu@127.0.0.1:/tmp/rfp.tgz
# inside the VM:
sudo bash install-rfp.sh
```

### 5. Claim the device, then flash

**Set SW1-1 on the board to ON (debug mode) before programming**, and back to
OFF (single chip mode) to run the firmware afterwards. The USB cable goes to
CN9.

```bash
sudo bash attach.sh

# Non-destructive first: signature, then the device's current checksum.
sudo /opt/rfp/rfp-cli -d RX65x -t e2l -if uart \
    -auth id FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF -sig

# Erase + program + verify, then release reset so it runs.
sudo /opt/rfp/rfp-cli -d RX65x -t e2l -if uart \
    -auth id FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF -a EnvisionDemo1.mot -run
```

Two arguments here were found the hard way and are not guessable:

**`-if uart`, not `-if fine`.** `rfp-cli -li` offers both, and FINE is the
single-wire debug interface the E2 Lite uses on RX, so it looks like the
obvious choice. It is not the one this board answers on. With `-if fine` the
emulator connects, reports its firmware version, and then fails at
`E3000105: The device is not responding` — which reads exactly like a dead or
unpowered target and sends you looking at switches and cables. `-if uart`
connects on the first try:

```
Connecting the target device
Main Clock: 16 MHz
Speed: 1,000,000 bps
```

**`-auth id FFFF…FF`.** Without it the tool stops at an interactive
`Enter ID Code (16 Bytes)?` prompt and, with no tty, cancels. All-FF is the
unprotected value; it is what an unlocked RX65N expects.

Before writing, check what the image puts in the Config Area:

```bash
grep -E '^S3[0-9A-F]{2}FE7F5D' your.mot
```

`FE7F5D40`–`FE7F5D4F` is the ID code. Writing a non-FF value there locks the
device to a code you had better know. Every byte of the EnvisionDemo images
is `FF`, which leaves the part unprotected — but this is worth one command to
confirm rather than discovering afterwards.

Note the argument spellings, which are not what you would guess:

* the device is **`RX65x`**, not `rx65n` (`rfp-cli -ld` lists the families)
* the interface is **`fine`** — the single-wire debug interface the E2 Lite
  uses on RX. `uart` (2-wire) is the other option
* `-lt` and `-ls` still require `-device`, so a bare `rfp-cli -lt` just errors

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

### The write itself

Firmware built on the VPS and flashed onto the board over the whole chain —
Pi USB, usbip, SSH tunnel, podman bridge, slirp, VM, rfp-cli, E2 Lite, RX65N:

```
Connected to RX Group
Memory Info:
    FFE00000 - FFFFFFFF: Code Flash 1
    00100000 - 00107FFF: Data Flash 1
    FE7F5D00 - FE7F5D7F: Config Area 1

Erasing the target device     ... 100%
Writing data to the target device
  [Code Flash 1]   FFF00000 - FFF019FF   100%
  [Code Flash 1]   FFFFFF80 - FFFFFFFF   100%
  [Config Area 1]  FE7F5D00 - FE7F5D7F   100%
Verifying data on the target device      100%

Operation successful
```

Device checksum before `10675439`, after `1FD26D68`; a separate `-v` pass
against the file passes on its own.

An earlier sign that the path was sound: on first connection rfp-cli pushed a
firmware update into the emulator itself, `VF.FF.FF.FFF -> V3.05.00.000`, and
the next run reported the new version — a bulk write plus a read-back across
the tunnel, persisted.

Latency never became an issue. A full `lsusb -v` (dozens of control transfers)
takes 50–60 ms over the link, and flashing ran at 1,000,000 bps without a
single retry.

---

## A firmware to flash: the LCD demo

The Envision Kit's 4.3" 480x272 panel is driven by the RX65N's GLCDC
peripheral. For a first flash, the best payload is Renesas' own factory image
from [`renesas-rx/rx65n-envision-kit`](https://github.com/renesas-rx/rx65n-envision-kit):

```bash
bash container/fetch-firmware.sh fw.mot
```

It is the image the board ships with, so flashing it **restores** the kit
rather than overwriting the demo with something else — which makes it a
no-regrets way to prove the whole chain. Verified: rfp-cli loads it as
`Size=6390200, CRC=58700822`.

That repository's `initial_firmware/readme.txt` is also where the SW1-1 and CN9
requirements above come from.

## LCD demos you can edit and rebuild — `firmware/`

The factory image above is a binary. For something modifiable,
`firmware/` builds
[`miniwinwm/RenesasEnvisionGCC`](https://github.com/miniwinwm/RenesasEnvisionGCC)
from source with Renesas' GNU RX — **no e2 studio, no CC-RX**:

```bash
cd firmware
podman build -t rx65n-fw -f Containerfile .
podman run --rm -v "$PWD":/work:Z -w /work rx65n-fw bash -c '
    bash install-toolchain.sh gcc-14.2.0.202607-GNURX-ELF-linux.tar.gz
    bash fetch-demo.sh EnvisionDemo1
    make'
# -> EnvisionDemo1.mot
```

The toolchain tarball is a free download but needs an account — see
`install-toolchain.sh` and the provenance section below.

Verified from a clean container: `EnvisionDemo1` builds to 6,581 bytes of text
and a 20,280 byte `.mot`, reproducibly (sha256 `280ff837…`), and
`EnvisionDemo3` and `EnvisionDemo12` build unmodified with the same Makefile.

These are register-level C with no FIT or FSP dependency — `EnvisionDemo1` is
four files (`EnvisionDemo1.c`, `font.c`, `lcd_driver.c`, `touch_driver.c`),
and `main()` is about forty lines. The panel is 480x272 RGB565 and the demo
draws a labelled box wherever you touch it.

The LCD-related ones:

| Demo | What it shows |
|---|---|
| **1** | display + touch screen — **the one to start from** |
| **3** | both display buffers, plus a GPIO edge interrupt |
| 11 | MTU3 PWM driving the LCD backlight |
| 12 | DMA memory-to-memory, blitting a bitmap in RGB565 |

The other fourteen cover data flash, FreeRTOS, RTC, FatFS/SD, timers,
temperature sensor, watchdog, ELC, deep standby, QSPI flash, stdio redirection
and DTC.

### Two things worth knowing about this build

**Upstream is an e2 studio project, not a Makefile project.** What makes a
Makefile build possible is `generate/` — the IDE-generated `start.S`,
`vects.c` and `linker_script.ld`. `firmware/Makefile` uses those directly.
Section placement comes out correct: `.text` at `0xfff00000`, the reset vector
at `0xfffffffc` pointing back at it, and `.ofs1`/`.ofs2`/`.ofs3` in option
memory.

**newlib comes from the toolchain, so the build is ordinary.** Renesas' GNU RX
bundles newlib, so the demos link against a real libc and only the startup
files are replaced (`-nostartfiles`, because the demo brings its own
`start.S`). `itoa` — which the demos call and which is *not* ISO C — resolves
to newlib's `_itoa`.

This is worth stating because an earlier revision of this build was
freestanding with a hand-written `strlen`/`itoa` shim. That was not a design
choice; it was a workaround for an unofficial toolchain that shipped no
newlib, and it would have blocked the demos that use FatFS or stdio. The shim
is gone.

`-mcpu=rx64m` is the right switch for RX65N; `rx-elf-gcc -print-multi-directory`
confirms it selects the `rxv2` multilib.

### The official demo source, and why it is not used here

[`renesas-rx/rx65n-envision-kit`](https://github.com/renesas-rx/rx65n-envision-kit)
does ship the full C source of the factory demo under
`rx65n_envisionkit/standard/` (including the DRW2D 2D-engine driver). It is the
richer codebase, but its readme requires **e2 studio 7.2+ and CC-RX v3.00+**
— Renesas' proprietary compiler, not GCC — and the demo is deployed through a
secure-boot chain as an `.rsu` file loaded from a USB stick, not as a plain
`.mot`. Modifying it means adopting that whole toolchain.

[`hirakuni45/RX`](https://github.com/hirakuni45/RX) has the most impressive
Envision Kit LCD work (GUI toolkit, NES and Space Invaders emulators), but it
is C++, not C.

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

## Provenance of everything downloaded

Anything fetched here either runs on the host, compiles the firmware, or ends
up written to the board's flash, so it is worth being explicit about where it
came from.

| What | Source | Standing |
|---|---|---|
| Ubuntu cloud image | `cloud-images.ubuntu.com` | Official |
| `debian:13` container | Docker Hub official library | Official |
| `usbip` on the Pi | Debian archive | Official, apt-signed |
| `rfp-cli` | Renesas, via a myRenesas account | Official |
| **GNU RX toolchain** | **Renesas, via llvm-gcc-renesas.com** | **Official** |
| Factory firmware `.mot` | [`renesas-rx`](https://github.com/renesas-rx/rx65n-envision-kit) on GitHub | Renesas' RX MCU team; see below |
| EnvisionDemo sources | [`miniwinwm`](https://github.com/miniwinwm/RenesasEnvisionGCC) on GitHub | Individual, but **source, not binaries** |

**The factory image** comes from a GitHub org named "Renesas Electronics
Corporation: RX MCUs team" with a `@renesas.com` contact address, and the
`.mot`'s S0 header reads `Created by RFP3`, consistent with Renesas tooling.
Almost certainly genuine — but the org is not domain-verified on GitHub and no
checksum or signature is published, so that last step is not cryptographically
closed.

**The demo sources** are from an individual (John Blaiklock). That is a much
weaker provenance claim than the rest of this table, but what is fetched is
about 30KB of readable C rather than an opaque binary, so it can be audited
before it is trusted.

### A toolchain that was used and then dropped

An earlier revision of `firmware/` used
[`Bud-ro/gcc-rx-zig`](https://github.com/Bud-ro/gcc-rx-zig), a prebuilt GNU RX
downloadable without an account. It was replaced, and the reasoning is worth
recording.

In its favour: releases are built by GitHub Actions from public source, the
base tarballs come from `ftp.gnu.org` with hashes pinned by zig, and no
pre-patched trees are vendored.

Against it: **no release signature and no build provenance attestation**, so
nothing ties the published binary to that CI run. The RX-specific delta is two
patch files (578KB) checked into the repository, nominally derived from
Renesas' RX source release but never verified against it. The repository was
three months old with no stars, no forks and a single author.

The likelier harm was never malice but **miscompilation** — subtly wrong RX
patches produce firmware that misbehaves, and the time is lost chasing phantom
hardware faults. Switching to Renesas' own build removed that whole class of
doubt and brought newlib along with it.

If registering is not an option, build the toolchain from source instead
(see [`kkitayam/docker-rx-elf-gcc`](https://github.com/kkitayam/docker-rx-elf-gcc)
for a worked recipe); that is auditable end to end and needs no trust in a
binary. Using an unsigned third-party prebuilt is the option to avoid.

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
