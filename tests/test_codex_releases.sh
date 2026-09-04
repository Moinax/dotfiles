#!/usr/bin/env bash
# What `dots update` prunes under ~/.codex/packages/standalone, and what it
# must leave alone.
#
# `reconcile_codex_releases` keeps the release `current` points at plus the
# newest other one, and deletes the rest. Four ways that goes wrong:
#
#   - `sort -V` has to win over lexical order, or 0.11.0 outranks 0.152.1
#     and the wrong release becomes the rollback.
#   - a release a live codex runs from must survive, whatever its version.
#   - a `current` that points outside `releases/` must prune nothing: the
#     live install would not be in the list it protects.
#   - a second run, a lone release, or no install at all must be a no-op
#     and return 0 — the function sits under `set -e` in `do_sync`.
#
# Run: bash tests/test_codex_releases.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$SCRIPT_DIR/../tools/sync-machine.sh"

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

stage=$(mktemp -d)
trap 'rm -rf "$stage"; kill "${sleeper:-}" 2>/dev/null' EXIT

standalone="$stage/home/.codex/packages/standalone"
suffix="-x86_64-unknown-linux-musl"

lay_down() {
    rm -rf "$standalone"
    mkdir -p "$standalone/releases"
    local v
    for v in "$@"; do mkdir "$standalone/releases/$v$suffix"; done
}

point_current() {
    ln -sfn "$1" "$standalone/current"
}

prune() {
    HOME="$stage/home" bash -c '
        set -e
        print_info() { :; }
        print_warning() { :; }
        eval "$(sed -n "/^reconcile_codex_releases() {/,/^}/p" "$1")"
        reconcile_codex_releases
    ' _ "$SYNC"
}

survivors() {
    find "$standalone/releases" -mindepth 1 -maxdepth 1 -printf '%f\n' \
        | sed "s/$suffix\$//" | sort -V | tr '\n' ' '
}

echo "keeps current and the newest other release, version-sorted"
lay_down 0.9.0 0.10.0 0.11.0 0.152.1 0.153.2
point_current "$standalone/releases/0.153.2$suffix"
prune
check "exit status" 0 "$?"
check "survivors" "0.152.1 0.153.2 " "$(survivors)"

echo "second run is a no-op"
prune
check "exit status" 0 "$?"
check "survivors" "0.152.1 0.153.2 " "$(survivors)"

echo "a rollback older than current still wins over one that is merely newest lexically"
lay_down 0.9.0 0.11.0 0.153.2
point_current "$standalone/releases/0.9.0$suffix"
prune
check "survivors" "0.9.0 0.153.2 " "$(survivors)"

echo "a release a live codex runs from is left alone"
lay_down 0.8.0 0.9.0 0.10.0 0.11.0
mkdir -p "$standalone/releases/0.8.0$suffix/bin"
cp "$(command -v sleep)" "$standalone/releases/0.8.0$suffix/bin/codex"
"$standalone/releases/0.8.0$suffix/bin/codex" 60 &
sleeper=$!
point_current "$standalone/releases/0.11.0$suffix"
prune
check "survivors" "0.8.0 0.10.0 0.11.0 " "$(survivors)"
kill "$sleeper"; wait "$sleeper" 2>/dev/null

echo "a lone release is untouched"
lay_down 0.153.2
point_current "$standalone/releases/0.153.2$suffix"
prune
check "exit status" 0 "$?"
check "survivors" "0.153.2 " "$(survivors)"

echo "current pointing outside releases/ prunes nothing"
lay_down 0.9.0 0.10.0 0.11.0
mkdir -p "$stage/elsewhere"
point_current "$stage/elsewhere"
prune
check "exit status" 0 "$?"
check "survivors" "0.9.0 0.10.0 0.11.0 " "$(survivors)"

echo "no standalone install at all"
rm -rf "$standalone"
prune
check "exit status" 0 "$?"

echo ""
if [ "$failures" -eq 0 ]; then
    echo "All checks passed"
else
    echo "$failures check(s) failed"
    exit 1
fi
