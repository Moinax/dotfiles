#!/usr/bin/env bash
# The two branches of phase_fork that fail silently in opposite directions.
#
# The dirty-tree guard has to let `pnpm-lock.yaml` through — `vp i` rewrites it
# on every install, so a guard without that exception refuses on the second run,
# forever, over a file the phase dirtied itself. And it has to keep refusing on
# anything else, because that is the whole reason it exists: this checkout is
# reset --hard on every run and an edit nobody meant to lose is exactly what a
# blanket exception would discard.
#
# The build sentinel is the other one. Too eager and every `dots droplet setup`
# pays three minutes reproducing byte-identical output; too lax and the unit is
# left pointing at a stale bin.mjs with no line of the report saying so.
#
# The pathspec and the comparison are tested against a real git repo rather than
# by reading the script: `:(exclude)` is git-side behaviour, not bash's.
#
# Run: bash tests/test_droplet_fork.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISION="$SCRIPT_DIR/../tools/provision-droplet.sh"

failures=0
check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ok   $label"
    else
        echo "  FAIL $label: expected '$expected', got '$actual'"
        failures=$((failures + 1))
    fi
}

# The guard as phase_fork spells it, lifted verbatim so a change there that this
# file does not follow shows up as a diff rather than as a passing stale test.
grep -q "git -C \"\$FORK_DIR\" diff --quiet -- . ':(exclude)pnpm-lock.yaml'" "$PROVISION" \
    || { echo "FAIL: the dirty guard in $PROVISION no longer matches this test"; exit 1; }

tree_is_clean() {
    git -C "$1" diff --quiet -- . ':(exclude)pnpm-lock.yaml' \
        && git -C "$1" diff --cached --quiet && echo clean || echo dirty
}

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

repo="$stage/t3code"
mkdir -p "$repo/apps/server/dist"
git -C "$repo" init -q
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name test
printf 'lock\n' > "$repo/pnpm-lock.yaml"
printf 'src\n'  > "$repo/file.ts"
git -C "$repo" add -A
git -C "$repo" commit -qm initial

echo "dirty-tree guard"
check "a pristine tree passes" clean "$(tree_is_clean "$repo")"

printf 'lock rewritten by vp i\n' > "$repo/pnpm-lock.yaml"
check "pnpm-lock.yaml alone passes" clean "$(tree_is_clean "$repo")"

printf 'edited\n' > "$repo/file.ts"
check "any other edit refuses" dirty "$(tree_is_clean "$repo")"

git -C "$repo" checkout -q -- file.ts
printf 'untracked\n' > "$repo/new.ts"
check "an untracked file passes" clean "$(tree_is_clean "$repo")"

# Staged changes are caught by the second half of the guard, which carries no
# exception: pnpm-lock.yaml is never deliberately staged in this checkout.
git -C "$repo" add pnpm-lock.yaml
check "a staged lockfile refuses" dirty "$(tree_is_clean "$repo")"
git -C "$repo" reset -q

echo "build sentinel"
sentinel="$repo/apps/server/dist/.built-from"
bin="$repo/apps/server/dist/bin.mjs"
head=$(git -C "$repo" rev-parse HEAD)

build_is_current() {
    if [ -f "$sentinel" ] && [ "$(cat "$sentinel")" = "$head" ] && [ -f "$bin" ]; then
        echo skip
    else
        echo build
    fi
}

check "no sentinel builds" build "$(build_is_current)"

printf '%s\n' "$head" > "$sentinel"
check "sentinel without bin.mjs builds" build "$(build_is_current)"

touch "$bin"
check "sentinel matching HEAD skips" skip "$(build_is_current)"

printf 'deadbeef\n' > "$sentinel"
check "sentinel from another commit builds" build "$(build_is_current)"

# The case that made this worth a test: `vp pack` has clean:true, so a rebuild
# wipes dist — sentinel included. A check that trusted the sentinel alone would
# skip the build that has to happen.
printf '%s\n' "$head" > "$sentinel"
rm -f "$bin"
check "a wiped dist builds" build "$(build_is_current)"

echo
if [ "$failures" -eq 0 ]; then
    echo "all checks passed"
else
    echo "$failures check(s) failed"
fi
exit "$((failures > 0))"
