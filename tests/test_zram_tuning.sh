#!/usr/bin/env bash
# What makes a machine count as needing the reclaim override, and the two
# properties of the rule file that decide whether it does anything at all.
#
# `zram_tuning_needs_setup` gates a sudo prompt in `dots update`, so it has to be
# exact in both directions: a false positive asks for a password on every run of
# a machine that is already done, and a false negative leaves a machine on
# CachyOS's swappiness of 150 forever, since setup is never re-run.
#
# The filename assertion is the load-bearing one. The override works by sorting
# *after* /usr/lib/udev/rules.d/30-zram.rules so udev applies its assignment
# last — rename it to anything sorting earlier and the vendor rule wins again,
# silently, on a file that still looks right. The reasoning is in
# .claude/rules/zram-tuning.md.
#
# Run: bash tests/test_zram_tuning.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../install/lib/zram-tuning.sh"

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

mkdir -p "$SCRIPT_DIR/../.scratch"
stage=$(mktemp -d "$SCRIPT_DIR/../.scratch/zram-tuning.XXXXXX")
trap 'rm -rf "$stage"' EXIT

# Two facts decide it: whether a zram device exists, and the content of the
# override. Each stub answers one, so a case can move exactly one of them.
needs_setup() {
    local supported="$1" rule="$2"
    bash -c '
        source "$1"
        answer_supported="$2" ZRAM_TUNING_UDEV_RULE="$3"
        zram_tuning_supported() { [ "$answer_supported" = yes ]; }
        zram_tuning_needs_setup && echo yes || echo no
    ' _ "$LIB" "$supported" "$rule"
}

echo "a machine with no zram device is not a machine that needs tuning"
check "unsupported, override absent" no "$(needs_setup no "$stage/absent.rules")"

echo "each missing piece triggers on its own"
check "override never written" yes "$(needs_setup yes "$stage/absent.rules")"

current="$stage/current.rules"
bash -c 'source "$1"; zram_tuning_udev_body' _ "$LIB" > "$current"
check "override matches what we would write" no "$(needs_setup yes "$current")"

drifted="$stage/drifted.rules"
sed 's/vm.swappiness}="60"/vm.swappiness}="150"/' "$current" > "$drifted"
check "override carries a stale value" yes "$(needs_setup yes "$drifted")"

truncated="$stage/truncated.rules"
head -3 "$current" > "$truncated"
check "override truncated to its comment header" yes "$(needs_setup yes "$truncated")"

echo "the rule has to outrank the vendor's, or it changes nothing"
rule_name=$(bash -c 'source "$1"; basename "$ZRAM_TUNING_UDEV_RULE"' _ "$LIB")
later=$(printf '30-zram.rules\n%s\n' "$rule_name" | sort | tail -1)
check "our filename sorts after 30-zram.rules" "$rule_name" "$later"
check "and is not the vendor filename itself" "" "$(echo "$rule_name" | grep -x '30-zram.rules')"

echo "the generated rule carries the configured value and parses"
body=$(bash -c 'source "$1"; zram_tuning_udev_body' _ "$LIB")
value=$(bash -c 'source "$1"; echo "$ZRAM_TUNING_SWAPPINESS"' _ "$LIB")
check "body assigns the knob's value" 1 \
    "$(printf '%s\n' "$body" | grep -c "SYSCTL{vm.swappiness}=\"$value\"")"
if command -v udevadm >/dev/null 2>&1; then
    printf '%s\n' "$body" > "$stage/verify.rules"
    udevadm verify "$stage/verify.rules" >/dev/null 2>&1
    check "udevadm accepts the rule" 0 "$?"
else
    echo "  skip udevadm not installed"
fi

echo "a failed write is reported as a warning, not as success"
result=$(bash -c '
    set -e
    source "$1"
    ZRAM_TUNING_UDEV_RULE="$2"
    zram_tuning_supported() { return 0; }
    print_info() { :; }
    print_success() { echo unexpected-success; }
    track_warning() { echo warning; }
    # Never execute sudo: fail the install, and fail loudly if anything else
    # privileged is reached after it.
    sudo() { [ "$1" = install ] && return 1; echo unexpected-sudo-"$1"; }
    apply_zram_tuning && echo status=0 || echo status=$?
' _ "$LIB" "$stage/unwritable.rules")
check "write failure warns and stops" $'warning\nstatus=1' "$result"

echo ""
if [ "$failures" -eq 0 ]; then
    echo "All checks passed"
else
    echo "$failures check(s) failed"
fi
exit $((failures > 0))
