#!/usr/bin/env bash
# Which side of a diverged fork wins, and why counting cannot decide it.
#
# `t3fork update` takes origin in before rebasing, so that a branch rebased on
# one machine and force-pushed is picked up by the next. Judged on counts alone
# that rule is wrong half the time: "another machine rebased and pushed" and
# "this machine rebased and declined the push" produce the identical shape —
# origin holds patches we lack (the pre-rebase form of everything the replay
# re-resolved) and we hold patches it lacks.
#
# Answering "origin wins" to both reverted the newer rebase and every conflict
# resolution in it, then replayed the older form onto upstream. Nothing said so:
# the reset only moves a ref, so the loss went to the reflog and the next build
# shipped the old patch. It happened, on 2026-08-20, and the droplet served the
# superseded build for a day.
#
# So both directions get a scenario, and the assertion is on file CONTENT rather
# than on shas: what is at stake is a re-resolution, and content is the only
# thing that shows whether it survived.
#
# Run: bash tests/test_t3fork_sync.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T3FORK="$SCRIPT_DIR/../home/dot_local/bin/executable_t3fork"

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

export GIT_AUTHOR_NAME=t3fork-test GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t3fork-test GIT_COMMITTER_EMAIL=t@example.com

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

# upstream at U1..U2, a fork branch carrying one patch, published to origin.
# Returns with $1/work checked out on `fork`, origin holding the same.
seed() {
    local root="$1"
    mkdir -p "$root"
    git init -q --bare "$root/upstream.git"
    git init -q --bare "$root/origin.git"

    git clone -q "$root/upstream.git" "$root/seed" 2>/dev/null
    git -C "$root/seed" commit -q --allow-empty -m U1
    git -C "$root/seed" commit -q --allow-empty -m U2
    git -C "$root/seed" push -q origin HEAD:main

    git clone -q "$root/upstream.git" "$root/work" 2>/dev/null
    git -C "$root/work" remote rename origin upstream
    git -C "$root/work" remote add origin "$root/origin.git"
    git -C "$root/work" fetch -q upstream main
    git -C "$root/work" switch -q -c fork upstream/main
    echo "PATCH v1" > "$root/work/ours.txt"
    git -C "$root/work" add -A
    git -C "$root/work" commit -qm "feat: our patch"
    git -C "$root/work" push -q origin fork
}

advance_upstream() {
    git -C "$1/seed" commit -q --allow-empty -m U3
    git -C "$1/seed" push -q origin HEAD:main
}

# Rebase $2's `fork` onto the current upstream and re-resolve the patch to $3,
# the way a replay onto newer code makes a commit's content differ.
rebase_and_resolve() {
    local repo="$1" content="$2"
    git -C "$repo" fetch -q upstream main
    git -C "$repo" rebase -q upstream/main
    echo "$content" > "$repo/ours.txt"
    git -C "$repo" add -A
    git -C "$repo" commit -q --amend --no-edit
}

# `</dev/null` is not tidiness. Without it the run inherits this terminal, and
# `offer_push` asks two questions on a tty — one of which, answered `y`, force-
# pushes, and the next runs `dots droplet fork` against the real DigitalOcean
# host. With stdout swallowed the prompt is invisible, so the first symptom is a
# test that appears to hang. It exercises the non-tty branch, which is the one
# this test means to reach anyway.
run_update() {
    T3CODE_REPO="$1" T3CODE_FORK_BRANCH=fork bash "$T3FORK" update >/dev/null 2>&1 </dev/null
}

echo "this checkout rebased, push declined — its rebase must survive"
a="$stage/a"
seed "$a"
advance_upstream "$a"
rebase_and_resolve "$a/work" "PATCH v2 re-resolved here"
# origin is still U2 + v1; work is U3 + v2. Counting says origin holds a patch
# we lack, which is exactly what the old rule read as "origin wins".
check "the shape is the ambiguous one" "1	2" \
    "$(git -C "$a/work" rev-list --left-right --cherry-pick --count 'origin/fork...fork')"
run_update "$a/work"
check "the re-resolution survives" "PATCH v2 re-resolved here" "$(cat "$a/work/ours.txt")"
check "upstream is still taken in" "U3" \
    "$(git -C "$a/work" log --format=%s -1 'fork~1')"

echo "another machine rebased and pushed — origin must win"
b="$stage/b"
seed "$b"
advance_upstream "$b"
git clone -q "$b/origin.git" "$b/other" 2>/dev/null
git -C "$b/other" remote add upstream "$b/upstream.git"
git -C "$b/other" switch -q fork
rebase_and_resolve "$b/other" "PATCH v2 from the other machine"
git -C "$b/other" push -q --force origin fork
run_update "$b/work"
check "the other machine's work is taken in" "PATCH v2 from the other machine" \
    "$(cat "$b/work/ours.txt")"

echo "level with origin — nothing is taken, nothing is lost"
c="$stage/c"
seed "$c"
run_update "$c/work"
check "the patch is untouched" "PATCH v1" "$(cat "$c/work/ours.txt")"

echo
if [ "$failures" -eq 0 ]; then
    echo "all checks passed"
else
    echo "$failures check(s) failed"
fi
exit "$((failures > 0))"
