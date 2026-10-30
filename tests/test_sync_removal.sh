#!/usr/bin/env bash
# `dots update` removing a dropped package must not take a declared one with it.
#
# `pacman -Rs` cascades to every dependency nothing else needs, judged by
# install reason alone. Dropping hyprshot took grim and slurp that way, though
# the yaml declared both by then. `remove_dropped_packages` marks the declared
# packages the cascade would take as explicit first — those, and no others —
# and removes nothing if it cannot.
#
# Run: bash tests/test_sync_removal.sh

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

eval "$(sed -n "/^remove_dropped_packages() {/,/^}/p" "$SYNC")"

export BASE_COMMIT=0123456789
print_header() { :; }
print_info() { :; }
print_warning() { :; }
warn_custom_uninstall() { :; }
confirm_or_abort() { return 0; }
plan_removal() { printf '%s\n' hyprshot grim slurp libfoo; }
calls=""
sudo() { calls+="sudo $*;"; return "$sudo_status"; }
remove_packages() { calls+="remove $*;"; }

sudo_status=0
remove_dropped_packages $'hyprshot\t\n' $'grim\nslurp\nzsh\n' >/dev/null
check "marks only the declared packages in the cascade, then removes" \
    "sudo pacman -D --asexplicit grim slurp;remove hyprshot;" "$calls"

calls=""
remove_dropped_packages $'hyprshot\t\n' $'zsh\n' >/dev/null
check "no declared package in the cascade: no sudo" "remove hyprshot;" "$calls"

calls=""
sudo_status=1
remove_dropped_packages $'hyprshot\t\n' $'grim\n' >/dev/null
check "marking fails: nothing removed" "sudo pacman -D --asexplicit grim;" "$calls"

[ "$failures" -eq 0 ] && echo "all passed" || exit 1
