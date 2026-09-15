#!/bin/bash
# Unpack Renesas' GNU RX toolchain into ./toolchain.
#
#   bash install-toolchain.sh gcc-14.2.0.202607-GNURX-ELF-linux.tar.gz
#
# The tarball is not downloadable unattended: it sits behind a free account on
# https://llvm-gcc-renesas.com/rx/rx-download-toolchains/ and the download URL
# redirects to a login form. Register, fetch it yourself, and pass the path.
#
# Pick the "Linux Toolchain Portable (ELF)" .tar.gz. At the time of writing
# only revision 14.2.0.202607 offers a Linux tar.gz; the older 14.2.0 revisions
# are .run installers.
#
# Why not an unofficial prebuilt: see the provenance section in ../README.md.
# Renesas' build also bundles newlib, which unofficial ones tend not to.
set -euo pipefail

TARBALL="${1:-}"
if [ -z "$TARBALL" ] || [ ! -f "$TARBALL" ]; then
    echo "usage: $0 <gcc-*-GNURX-ELF-linux.tar.gz>" >&2
    exit 1
fi

rm -rf toolchain
mkdir -p toolchain
# Entries are "./gcc-for-renesas-rx-linux/bin/...", so the leading "./" counts
# as a path component and two have to come off, not one.
tar xzf "$TARBALL" -C toolchain --strip-components=2

toolchain/bin/rx-elf-gcc --version | head -1
echo "multilib for rx64m: $(toolchain/bin/rx-elf-gcc -mcpu=rx64m -print-multi-directory)"

# newlib is what lets the demos link without a hand-rolled libc subset.
if ! find toolchain -name libc.a -print -quit | grep -q .; then
    echo "warning: no libc.a found — this build has no newlib" >&2
fi
