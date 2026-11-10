#!/usr/bin/env bash
# The patch verdict behind `dots update`'s patched packages step.
#
# The verdict decides what happens to the machine: "apply" rebuilds and pins,
# "upstream" unpins and reinstalls the repo build, "stale" keeps the old build
# pinned. Mixing up the last two drops the fix silently, so each case gets a
# tree of its own. The trees hold two source dirs, as xdph's PKGBUILD unpacks,
# and the patch targets the second one, so a matcher that only tries the first
# dir fails here.
#
# Run: bash tests/test_local_packages.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$DOTFILES_DIR/install/lib/common.sh"
source "$DOTFILES_DIR/install/lib/local-packages.sh"

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

mkdir -p "$DOTFILES_DIR/.scratch"
stage=$(mktemp -d "$DOTFILES_DIR/.scratch/local-packages.XXXXXX")
trap 'rm -rf "$stage"' EXIT

# One tree per case: src/protocols (decoy) and src/app (the patch's target).
make_tree() {
    mkdir -p "$stage/$1/src/protocols" "$stage/$1/src/app"
    printf 'decoy\n' >"$stage/$1/src/protocols/main.c"
    printf 'one\ntwo\nthree\n' >"$stage/$1/src/app/main.c"
}
for t in pristine fixed stale; do make_tree "$t"; done
printf 'one\ntwo\nfixed\nthree\n' >"$stage/fixed/src/app/main.c"
printf 'one\nTWO\nthree\n' >"$stage/stale/src/app/main.c"

mkdir -p "$stage/pkg"
cat >"$stage/pkg/fix.patch" <<'EOF'
--- a/main.c
+++ b/main.c
@@ -1,3 +1,4 @@
 one
 two
+fixed
 three
EOF

check "patch applies -> apply" apply "$(_local_pkg_patch_state "$stage/pristine/src" "$stage/pkg")"
check "patch already in -> upstream" upstream "$(_local_pkg_patch_state "$stage/fixed/src" "$stage/pkg")"
check "patch conflicts -> stale" stale "$(_local_pkg_patch_state "$stage/stale/src" "$stage/pkg")"

_local_pkg_apply_patches "$stage/pristine/src" "$stage/pkg"
check "apply lands in the dir it matched" "$(cat "$stage/fixed/src/app/main.c")" "$(cat "$stage/pristine/src/app/main.c")"
check "the decoy dir is untouched" decoy "$(cat "$stage/pristine/src/protocols/main.c")"

[ "$failures" -eq 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
