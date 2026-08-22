#!/bin/bash

# Globally enable/disable window opacity in Hyprland.
#
# Toggles the named `GlobalOpacityRule` loaded by conf/windowrules.lua: first
# press enables its exact opacity of 1, second press disables it and therefore
# restores the configured defaults. Because this is a window rule, it applies
# both to existing windows and to windows created while the mode is enabled.
#
# Two parsers, two mechanisms (both global):
#   * New Lua parser (Hyprland 0.55+): toggle the persistent named rule handle.
#   * Legacy parser (older Hyprland, e.g. Fedora): `eval`/hl.config is absent, so
#     we fall back to `hyprctl keyword`, which only works on the legacy parser.

set -euo pipefail

STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/hypr-opacity-disabled"

# Keep in sync with conf/decoration.lua.
ACTIVE_DEFAULT=0.92
INACTIVE_DEFAULT=0.85

set_global_opacity() {
    local enabled="$1"
    local legacy_active="$2"
    local legacy_inactive="$3"

    # Prefer the Lua parser; "ok" on stdout means it took effect.
    if hyprctl eval "GlobalOpacityRule:set_enabled($enabled)" 2>/dev/null | grep -qx ok; then
        return
    fi
    # Legacy parser fallback.
    hyprctl keyword decoration:active_opacity "$legacy_active" >/dev/null 2>&1
    hyprctl keyword decoration:inactive_opacity "$legacy_inactive" >/dev/null 2>&1
}

if [[ -f "$STATE_FILE" ]]; then
    set_global_opacity false "$ACTIVE_DEFAULT" "$INACTIVE_DEFAULT"
    rm -f "$STATE_FILE"
    msg="Opacity ON"
    icon="view-visible-symbolic"
else
    set_global_opacity true 1 1
    touch "$STATE_FILE"
    msg="Opacity OFF"
    icon="view-hidden-symbolic"
fi

notify-send -u low -i "$icon" \
    -h int:transient:1 \
    -h string:x-canonical-private-synchronous:opacity \
    "$msg" || true
