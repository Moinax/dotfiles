#!/bin/bash

# Globally enable/disable window opacity in Hyprland.
#
# Flips the decoration opacity values for the whole session: first press sets
# active/inactive opacity to 1 (transparency off), second press restores the
# configured defaults. Unlike per-window tagging, this affects every window —
# including ones opened while opacity is disabled.
#
# Two parsers, two mechanisms (both global):
#   * New Lua parser (Hyprland 0.55+): `hyprctl keyword` is rejected, so we push
#     the values through `hyprctl eval` running the same hl.config() Lua as
#     conf/decoration.lua.
#   * Legacy parser (older Hyprland, e.g. Fedora): `eval`/hl.config is absent, so
#     we fall back to `hyprctl keyword`, which only works on the legacy parser.

set -euo pipefail

STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/hypr-opacity-disabled"

# Keep in sync with conf/decoration.lua.
ACTIVE_DEFAULT=0.92
INACTIVE_DEFAULT=0.85

set_opacity() { # $1 = active, $2 = inactive
    # Prefer the Lua parser; "ok" on stdout means it took effect.
    if hyprctl eval \
        "hl.config({ decoration = { active_opacity = $1, inactive_opacity = $2 } })" \
        2>/dev/null | grep -qx ok; then
        return
    fi
    # Legacy parser fallback.
    hyprctl keyword decoration:active_opacity "$1" >/dev/null 2>&1
    hyprctl keyword decoration:inactive_opacity "$2" >/dev/null 2>&1
}

if [[ -f "$STATE_FILE" ]]; then
    set_opacity "$ACTIVE_DEFAULT" "$INACTIVE_DEFAULT"
    rm -f "$STATE_FILE"
    msg="Opacity on (${ACTIVE_DEFAULT}/${INACTIVE_DEFAULT})"
else
    set_opacity 1 1
    touch "$STATE_FILE"
    msg="Opacity off (all windows solid)"
fi

notify-send -u low -h int:transient:1 "Opacity" "$msg" || true
