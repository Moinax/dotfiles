#!/bin/bash
set -e

# Toggle between dark and light mode

# Prevent overlapping runs when key is pressed rapidly
LOCK_FILE="/tmp/toggle-dark-mode.lock"
if [ -f "$LOCK_FILE" ]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if kill -0 "$LOCK_PID" 2>/dev/null; then
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# What the desktop is showing, not what this repo last wrote: the waybar icon
# reads the portal too, so a scheme flipped from outside — Plasma's settings,
# another tool — leaves the icon right and this the only thing left inverting
# the wrong value. The state file stays as the fallback for a portal-less
# session, and apply-dark-mode.sh keeps writing it.
. "$HOME/.local/lib/theme-copies.sh"
CURRENT=$(portal_mode || theme_mode)

if [ "$CURRENT" = "dark" ]; then
    ~/.local/bin/apply-dark-mode.sh light
else
    ~/.local/bin/apply-dark-mode.sh dark
fi
