#!/usr/bin/env bash
# What `t3fork mobile` does about the phone, before it spends twenty minutes.
#
# The device check is the one piece of real logic in that subcommand, and the
# reason it is read first: an Android build here is twenty minutes of NDK work,
# while every way the device side can fail is something only somebody holding
# the phone can clear. Finding out at the end spends all of it to learn
# something that cost a second at the start.
#
# `unauthorized` is why this has a test at all. It is a device that `adb
# devices` lists, so anything checking "did adb print a line?" reads it as
# ready — and it actually means an "Allow USB debugging?" dialog is sitting on a
# locked screen, which no amount of retrying from this side will clear. The four
# states need four different sentences, and a regression here is silent: the
# build still runs, it just ends on adb's own message half an hour later.
#
# Everything is staged, so nothing here touches the real checkout, SDK or phone.
#
# Run: bash tests/test_t3fork_mobile.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T3FORK="$SCRIPT_DIR/../home/dot_local/bin/executable_t3fork"

failures=0
check() {
    local label="$1" expected="$2" output="$3"
    if grep -qF "$expected" <<<"$output"; then
        echo "  ok   $label"
    else
        echo "  FAIL $label: no '$expected' in:"
        sed 's/^/         /' <<<"$output"
        failures=$((failures + 1))
    fi
}

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

# A repo for the script to cd into: it asserts its fork config keys and refuses
# a rebase in progress before it looks at anything else.
export T3CODE_REPO="$stage/repo"
git init -q "$T3CODE_REPO"
git -C "$T3CODE_REPO" commit -q --allow-empty -m seed

# A JDK that is only a javac, which is all the guard tests for. Named rather
# than inherited so this passes on a machine with no JDK 17 — otherwise the run
# would stop on the JDK check and never reach the one being tested.
export T3CODE_JAVA_HOME="$stage/jdk"
mkdir -p "$T3CODE_JAVA_HOME/bin"
: >"$T3CODE_JAVA_HOME/bin/javac"
chmod +x "$T3CODE_JAVA_HOME/bin/javac"

# An SDK that is only an adb, which is all android_sdk tests for.
export ANDROID_HOME="$stage/sdk"
mkdir -p "$ANDROID_HOME/platform-tools"
adb="$ANDROID_HOME/platform-tools/adb"

# $stage/adb-state is the fake `adb devices` body — the lines after the header.
cat >"$adb" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  start-server) exit 0 ;;
  devices) echo "List of devices attached"; cat "$ADB_STATE"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$adb"
export ADB_STATE="$stage/adb-state"

# HOME is staged and PATH is bare so `vp` resolves nowhere. That is what gives
# the authorised case a positive assertion: the run has to get PAST the device
# check to reach the vp guard, and "vp not found" is the proof it did.
run_mobile() {
    env HOME="$stage/home" PATH=/usr/bin:/bin \
        T3CODE_REPO="$T3CODE_REPO" T3CODE_JAVA_HOME="$T3CODE_JAVA_HOME" \
        ANDROID_HOME="$ANDROID_HOME" ADB_STATE="$ADB_STATE" \
        bash "$T3FORK" mobile 2>&1
}
# The script sources it at top level for the restart paths, which `mobile` never
# takes — but a staged HOME has to carry whatever the script reads out of HOME,
# or every case below dies on the source line instead of on the check.
mkdir -p "$stage/home/.local/lib"
echo 'spawn_detached() { :; }' >"$stage/home/.local/lib/spawn.sh"

echo "t3fork mobile: the device check"

: >"$ADB_STATE"
check "nothing plugged in says to enable USB debugging" \
    "Settings > Developer options > USB debugging" "$(run_mobile)"

printf 'RFGYA0N090A\tunauthorized\n' >"$ADB_STATE"
check "unauthorized points at the dialog on the phone" \
    "has not authorised this computer" "$(run_mobile)"

printf 'RFGYA0N090A\toffline\n' >"$ADB_STATE"
check "any other state is named rather than guessed" \
    'reports "offline"' "$(run_mobile)"

printf 'RFGYA0N090A\tdevice\nRFGYA0N091B\tdevice\n' >"$ADB_STATE"
check "two phones refuses rather than picking one" \
    "more than one device attached" "$(run_mobile)"

# One authorised phone: the check must pass and the run must continue, which it
# can only prove by failing on the next guard along.
printf 'RFGYA0N090A\tdevice\n' >"$ADB_STATE"
check "one authorised phone gets past the check" \
    "vp not found" "$(run_mobile)"

echo
if [ "$failures" -eq 0 ]; then
    echo "all checks passed"
else
    echo "$failures check(s) failed"
fi
exit $((failures > 0))
