#!/bin/bash
# Build the diag9 ladder: one .mot per step, each differing from the one
# before it in a single property, plus step 1 without the debug console.
#
#   bash ladder.sh            # steps 1..4 and 1nc
#   bash ladder.sh 2 3        # just those
#
# Run them in order, lowest first. Step 1 is the known-good baseline; if it
# stops, nothing above it is worth running until that is understood. 1nc is
# the same baseline without the console, and the pair of them answers
# whether the console is safe to leave on.
#
# Every step goes through build.sh, so every step is built fresh from the
# same two commits - resolved once, here, and passed down - and each .txt
# beside its .mot says which. Two steps built from different commits would
# not be one change apart, whatever the step numbers say.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STEPS="${*:-1 2 3 4 1nc}"

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

export RX_REF="$(sha_of "${RX_REPO:-paijp/rx65n}" "${RX_REF:-main}")"
export UI_REF="$(sha_of "${UI_REPO:-paijp/smallest-touchpanel-ui}" "${UI_REF:-main}")"
echo "rx65n $RX_REF"
echo "ui    $UI_REF"

for s in $STEPS; do
	case "$s" in
	*nc)	flags="-DDIAG9_STEP=${s%nc} -DDIAG9_CONSOLE=0" ;;
	*)	flags="-DDIAG9_STEP=$s" ;;
	esac
	echo
	NAME="diag9s$s" bash "$HERE/build.sh" diag9 $flags | grep -E '^(flags|mot md5)'
done

# Identical checksums between two steps are proof of a mistake.
echo
md5sum "${OUT:-/work/out}"/diag9s*.mot
