#!/usr/bin/env bash
# What makes a machine count as needing hyprlock's own PAM stack, and that the
# stack we write carries no pam_faillock.
#
# `hyprlock_pam_needs_setup` gates a sudo prompt in `dots update`: a false
# positive asks for a password on every run, a false negative leaves the stock
# `include login` stack, where a few typos at the lock screen lock the account.
#
# Run: bash tests/test_hyprlock_pam.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../install/lib/hyprlock-pam.sh"

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
stage=$(mktemp -d "$SCRIPT_DIR/../.scratch/hyprlock-pam.XXXXXX")
trap 'rm -rf "$stage"' EXIT

needs_setup() {
    bash -c 'source "$1"; HYPRLOCK_PAM_FILE="$2"; hyprlock_pam_needs_setup && echo yes || echo no' _ "$LIB" "$1"
}

echo "no hyprlock, nothing to fix"
check "file absent" no "$(needs_setup "$stage/absent")"

echo "the stock stack and any drift trigger it"
printf '# PAM configuration file for hyprlock\nauth        include     login\n' > "$stage/stock"
check "stock include login" yes "$(needs_setup "$stage/stock")"

current="$stage/current"
bash -c 'source "$1"; hyprlock_pam_body' _ "$LIB" > "$current"
check "our body" no "$(needs_setup "$current")"

sed '$a auth required pam_faillock.so authfail' "$current" > "$stage/edited"
check "our header, hand-edited body" yes "$(needs_setup "$stage/edited")"

echo "the body is the stack it claims to be"
check "no faillock module" 0 "$(grep -v '^#' "$current" | grep -c pam_faillock)"
check "no fprintd module" 0 "$(grep -v '^#' "$current" | grep -c pam_fprintd)"
check "pam_unix is required" 1 "$(grep -cE '^auth +required +pam_unix\.so' "$current")"

echo ""
if [ "$failures" -eq 0 ]; then
    echo "All checks passed"
else
    echo "$failures check(s) failed"
fi
exit $((failures > 0))
