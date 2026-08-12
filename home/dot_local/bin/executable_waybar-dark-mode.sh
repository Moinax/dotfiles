#!/bin/bash

# Waybar custom module: dark/light mode status (continuous JSON output)
#
# Follows the portal's colour-scheme — the same source waybar's own stylesheet
# and vicinae read — so the icon tracks the system appearance itself and not
# the caller that happened to flip it (apply-dark-mode.sh has the history).
#
# Waybar runs this as a long-lived process (continuous exec mode); one gdbus
# monitor for the whole bar, woken only by the signal.

# For portal_mode()/scheme_mode(), and theme_mode() as their fallback.
. "$HOME/.local/lib/theme-copies.sh"

ICON_MOON=$(printf '\uf4ee') # Octicons moon
ICON_SUN=$(printf '\uf522')

# The portal announces the same color-scheme three times per flip (KDE emits it
# for the scheme change, the accent recompute and the kdeglobals mirror), so the
# mode already drawn is remembered rather than redrawn.
LAST_MODE=""

emit_status() {
    [ "$1" = "$LAST_MODE" ] && return
    LAST_MODE="$1"
    if [ "$1" = "light" ]; then
        printf '{"text": "%s", "class": "light", "tooltip": "Light mode (Catppuccin Latte)"}\n' "$ICON_SUN"
    else
        printf '{"text": "%s", "class": "dark", "tooltip": "Dark mode (Catppuccin Mocha)"}\n' "$ICON_MOON"
    fi
}

# Initial state. The portal is the source of truth, but a session without it
# still has the state file apply-dark-mode.sh writes.
emit_status "$(portal_mode || theme_mode)"

# Then re-emit on every appearance change. gdbus exiting (portal restart) ends
# the script, and waybar's restart-interval brings it back.
#
# Read through a process substitution rather than a pipe, for the trap: waybar
# terminates this script on every reload, and a piped gdbus would outlive it
# until its next write hit the closed pipe — one stray monitor per reload.
exec 3< <(gdbus monitor --session --dest org.freedesktop.portal.Desktop 2>/dev/null)
MONITOR_PID=$!
trap 'kill "$MONITOR_PID" 2>/dev/null' EXIT

# The guard has to stay: other settings carry a `uint32` payload too, and
# scheme_mode reads the payload alone.
while IFS= read -r line <&3; do
    [[ $line == *"SettingChanged ('org.freedesktop.appearance', 'color-scheme'"* ]] || continue
    mode=$(scheme_mode "$line") && emit_status "$mode"
done
