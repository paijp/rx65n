#!/bin/bash
# Build one program from named commits, in a fresh directory, and record
# which commits it came from.
#
#   bash build.sh diag9                              # both repos at main
#   NAME=diag9s2 bash build.sh diag9 -DDIAG9_STEP=2  # extra flags after MAIN
#   RX_REF=1a2b3c UI_REF=4d5e6f bash build.sh diag9  # pinned
#
# Output lands in $OUT: <name>.mot, <name>.elf, and <name>.txt saying what
# produced them.
#
# Why this exists: builds used to happen in a long-lived directory that had
# been copied from this repository once and then patched by hand, so the
# binaries that were flashed and reported on could not be reproduced from
# anything committed. Everything here is fetched fresh from GitHub at a named
# commit - the build scripts and patches from this repository, the sources
# from smallest-touchpanel-ui - and "main" is resolved to a SHA before
# anything is fetched, so the record says exactly what was built even when
# the request was for a branch.
#
# The only thing not fetched is the toolchain, which is large, built once,
# and identified in the record by its version string.
set -euo pipefail

MAIN="${1:?usage: build.sh <program> [extra CFLAGS...]}"
shift
EXTRA="$*"

RX_REPO="${RX_REPO:-paijp/rx65n}"
UI_REPO="${UI_REPO:-paijp/smallest-touchpanel-ui}"
RX_REF="${RX_REF:-main}"
UI_REF="${UI_REF:-main}"
TC="${TC:-/work/toolchain}"
OUT="${OUT:-/work/out}"
NAME="${NAME:-$MAIN}"

# A branch name resolved once, here, so both the fetch and the record use
# the same commit even if someone pushes in between.
sha_of()
{
	# A full SHA is already resolved. A name goes through git ls-remote
	# rather than the REST API, whose 60 requests an hour ran out in the
	# middle of a batch of runs.
	if echo "$2" | grep -qE '^[0-9a-f]{40}$'; then
		echo "$2"
		return
	fi
	if command -v git > /dev/null; then
		git ls-remote "https://github.com/$1" "refs/heads/$2" | head -1 | cut -f1
		return
	fi
	curl -fsSL "https://api.github.com/repos/$1/commits/$2" \
		| python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])'
}

RX_SHA=$(sha_of "$RX_REPO" "$RX_REF")
UI_SHA=$(sha_of "$UI_REPO" "$UI_REF")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

curl -fsSL "https://codeload.github.com/$RX_REPO/tar.gz/$RX_SHA" \
	| tar xz -C "$work" --strip-components=2 --wildcards '*/firmware/*'

cd "$work"
ln -s "$TC" toolchain
UI_REPO="$UI_REPO" UI_REF="$UI_SHA" MAIN="$MAIN" bash fetch-lcdtp.sh > fetch.log
make DEMO=lcdtp EXTRA_CFLAGS="$EXTRA" > make.log 2>&1 || {
	cat make.log >&2
	exit 1
}

mkdir -p "$OUT"
cp lcdtp.mot "$OUT/$NAME.mot"
cp lcdtp.elf "$OUT/$NAME.elf"

{
	echo "program:   $MAIN"
	echo "flags:     ${EXTRA:-(none)}"
	echo "rx65n:     $RX_REPO@$RX_SHA"
	echo "ui:        $UI_REPO@$UI_SHA"
	echo "toolchain: $("$TC/bin/rx-elf-gcc" --version | head -1)"
	echo "mot md5:   $(md5sum < "$OUT/$NAME.mot" | cut -d' ' -f1)"
	echo "patches:"
	grep -E '^(linker_script|inthandler|vects|touch_driver)' fetch.log | sed 's/^/  /'
} > "$OUT/$NAME.txt"

cat "$OUT/$NAME.txt"
