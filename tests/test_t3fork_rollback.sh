#!/usr/bin/env bash
# What `t3fork rollback` has to be able to do: put the previous build back when
# the installed one will not start.
#
# That premise is the whole design. There is no window to click, so the in-app
# button cannot serve it, and nothing built from the checkout can be relied on
# either — so this path is shell, touches only files, and is tested as files.
#
# The second case is the one that made the backup worth testing at all: updates
# now chain without a restart in between, so `<AppImage>.previous` must keep
# naming the build that actually ran. Overwriting it on every install would,
# after two preparations, offer a rollback onto a build nobody ever started.
#
# Run: bash tests/test_t3fork_rollback.sh

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

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

# The script cd's into the checkout at load, so give it one that exists.
export T3CODE_REPO="$stage/repo"
git init -q "$T3CODE_REPO"

home="$stage/home"
apps="$home/.local/share/AppImages"
state="$home/.local/state/t3fork"
target="$apps/t3-code.AppImage"
mkdir -p "$apps" "$state" "$home/.local/lib"
# The script sources the shared launcher lib at load; -n never calls into it.
echo 'spawn_detached() { :; }' >"$home/.local/lib/spawn.sh"

run_rollback() {
    HOME="$home" bash "$T3FORK" rollback -n 2>&1
}

echo "== nothing to roll back to =="
out=$(run_rollback); status=$?
check "refuses without a backup" "1" "$status"
check "says where it looked" "yes" "$(grep -qF "no previous build at $target.previous" <<<"$out" && echo yes || echo no)"

echo
echo "== a rollback restores the named build =="
printf 'broken\n' >"$target"
printf 'working\n' >"$target.previous"
printf '{"version":"0.1.0-moinax.abc1234"}\n' >"$target.previous.json"
printf '{"stage":"ready"}\n' >"$state/status.json"
printf '{"stage":"ready"}\n' >"$state/prepared.json"
out=$(run_rollback); status=$?
check "succeeds" "0" "$status"
check "the working build is installed" "working" "$(cat "$target")"
check "names the version it restored" "yes" \
    "$(grep -qF "rolled back to 0.1.0-moinax.abc1234" <<<"$out" && echo yes || echo no)"
check "the backup is consumed" "absent" \
    "$([ -e "$target.previous" ] && echo present || echo absent)"
# Both describe a file that is no longer installed. Left behind, the sidebar
# reports the build that replaced it as needing attention.
check "the prepared record is cleared" "absent" \
    "$([ -e "$state/prepared.json" ] && echo present || echo absent)"
check "the run record is cleared" "absent" \
    "$([ -e "$state/status.json" ] && echo present || echo absent)"

echo
echo "== an unnamed backup is still restorable =="
printf 'broken\n' >"$target"
printf 'older\n' >"$target.previous"
out=$(run_rollback); status=$?
check "succeeds without the name file" "0" "$status"
check "restores it anyway" "older" "$(cat "$target")"
check "says so without a version" "yes" \
    "$(grep -qF "rolled back to the previous build" <<<"$out" && echo yes || echo no)"

echo
if [ "$failures" -eq 0 ]; then
    echo "All rollback checks passed."
else
    echo "$failures check(s) failed."
    exit 1
fi
