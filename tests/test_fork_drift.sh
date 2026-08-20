#!/usr/bin/env bash
# What `dots update` says about a fork, and the three ways it lied.
#
# `fork_drift` answers two questions per fork — how far behind upstream, and
# whether the branch is published — and emits one tab-separated row when either
# has something to say. Both answers have a wrong version that looks right:
#
#   - a rebased-but-published fork must report `no`. Its shas differ from
#     origin's by construction, so anything comparing shas warns forever.
#   - a detached HEAD must report nothing. `$tip` falls back to the literal
#     `HEAD`, and `origin/HEAD` resolves in any normal clone — to origin's
#     default branch, a ref nobody here maintains.
#   - a fork with no `origin` at all must not error under `set -e`.
#
# The row shape is a contract with `report_fork_drift`, which reads five fields;
# a row with four shifts `cmd` into `unpushed`. So the field count is asserted
# too.
#
# Run: bash tests/test_fork_drift.sh

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

export GIT_AUTHOR_NAME=drift-test GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=drift-test GIT_COMMITTER_EMAIL=t@example.com

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

# fork_drift walks `dev-projects root`, so the test points that at the stage and
# runs the function alone rather than the whole sync — everything else in
# `do_sync` touches the real machine.
mkdir -p "$stage/bin"
cat > "$stage/bin/dev-projects" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = root ] && printf '%s\n' "$stage/projects"
EOF
chmod +x "$stage/bin/dev-projects"
mkdir -p "$stage/projects"

drift() {
    PATH="$stage/bin:$PATH" bash -c '
        set -e
        eval "$(sed -n "/^fork_drift() {/,/^}/p" "$1")"
        fork_drift
    ' _ "$SYNC" 2>/dev/null
}

# A fork: upstream with two commits, our patch on top, published to origin.
make_fork() {
    # Two statements: bash expands every word of a `local` before it runs, so
    # `local name=$1 root=.../$name` reads $name before it exists, and `set -u`
    # kills the run.
    local name="$1"
    local root="$stage/projects/$name"
    git init -q --bare "$stage/$name-up.git"
    git init -q --bare "$stage/$name-origin.git"
    git clone -q "$stage/$name-up.git" "$stage/$name-seed" 2>/dev/null
    git -C "$stage/$name-seed" commit -q --allow-empty -m U1
    git -C "$stage/$name-seed" commit -q --allow-empty -m U2
    git -C "$stage/$name-seed" push -q origin HEAD:main
    git clone -q "$stage/$name-up.git" "$root" 2>/dev/null
    git -C "$root" remote rename origin upstream
    git -C "$root" remote add origin "$stage/$name-origin.git"
    git -C "$root" fetch -q upstream main
    git -C "$root" switch -q -c fork upstream/main
    git -C "$root" commit -q --allow-empty -m "feat: our patch"
    git -C "$root" config dotfiles.forkBranch fork
    git -C "$root" push -q origin fork
}

echo "a published fork says nothing"
make_fork published
check "no row" "" "$(drift)"

echo "a rebased-but-published fork still says nothing"
git -C "$stage/projects/published-seed" >/dev/null 2>&1 || true
git -C "$stage/published-seed" commit -q --allow-empty -m U3
git -C "$stage/published-seed" push -q origin HEAD:main
git -C "$stage/projects/published" fetch -q upstream main
git -C "$stage/projects/published" rebase -q upstream/main
git -C "$stage/projects/published" push -q --force origin fork
# Every sha on the branch changed; only an ancestry test gets this right.
check "rebase alone is not unpublished" "" "$(drift)"

echo "a checkout BEHIND origin says nothing"
# The discriminator between an ancestry test and a sha comparison, and the false
# positive angles 1 and 4 of the review both named: another machine pushed ahead,
# this one has not fetched. The shas differ, but nothing here is unpublished —
# warning would send the reader to publish work they do not have.
git clone -q "$stage/published-origin.git" "$stage/other" 2>/dev/null
git -C "$stage/other" switch -q fork
git -C "$stage/other" commit -q --allow-empty -m "from the other machine"
git -C "$stage/other" push -q origin fork
git -C "$stage/projects/published" fetch -q origin fork
check "behind origin is not unpublished" "" "$(drift)"
git -C "$stage/projects/published" reset -q --hard origin/fork

echo "an unpublished commit is reported, with five fields"
git -C "$stage/projects/published" commit -q --allow-empty -m "feat: unpushed"
row="$(drift)"
check "one row" 1 "$(printf '%s\n' "$row" | grep -c .)"
check "five fields" 5 "$(printf '%s' "$row" | awk -F'\t' '{print NF}')"
check "branch" "fork" "$(printf '%s' "$row" | cut -f2)"
check "behind is zero" "0" "$(printf '%s' "$row" | cut -f3)"
check "unpushed is yes" "yes" "$(printf '%s' "$row" | cut -f4)"

echo "behind upstream is reported alongside"
git -C "$stage/published-seed" commit -q --allow-empty -m U4
git -C "$stage/published-seed" push -q origin HEAD:main
row="$(drift)"
check "behind is one" "1" "$(printf '%s' "$row" | cut -f3)"
check "still unpushed" "yes" "$(printf '%s' "$row" | cut -f4)"

echo "a detached HEAD is not compared against origin/HEAD"
make_fork detached
git -C "$stage/projects/detached" config --unset dotfiles.forkBranch
# origin/HEAD is what makes this scenario real rather than vacuous: without it
# the guard is never reached and the assertion passes whether or not the guard
# exists — verified, it did. A bare repo pushed to still points HEAD at a branch
# that was never created, so `set-head -a` fails until the remote has one.
git -C "$stage/detached-origin.git" symbolic-ref HEAD refs/heads/fork
git -C "$stage/projects/detached" remote set-head origin -a >/dev/null
git -C "$stage/projects/detached" rev-parse --verify --quiet origin/HEAD >/dev/null \
    || { echo "  FAIL fixture: origin/HEAD absent, the detached case is vacuous"; failures=$((failures + 1)); }
git -C "$stage/projects/detached" commit -q --allow-empty -m "only here"
git -C "$stage/projects/detached" checkout -q --detach HEAD
check "no row for a detached checkout" "" "$(drift | grep detached || true)"

echo "a fork with no origin does not error"
make_fork noorigin
git -C "$stage/projects/noorigin" remote remove origin
git -C "$stage/projects/noorigin" commit -q --allow-empty -m "local only"
drift >/dev/null 2>&1
check "fork_drift still exits clean" 0 "$?"

echo
if [ "$failures" -eq 0 ]; then
    echo "all checks passed"
else
    echo "$failures check(s) failed"
fi
exit "$((failures > 0))"
