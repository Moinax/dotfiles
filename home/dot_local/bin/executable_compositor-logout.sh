#!/bin/bash
set -e

# Stop the graphical session gracefully so the display manager re-spawns the
# greeter. Under uwsm, `uwsm stop` walks
# graphical-session.target down in dependency order (stops user services
# first, then the compositor) — no broken-pipe SIGABRTs, no drkonqi cascade.
. "$HOME/.local/lib/compositor.sh"

if is_hyprland && command -v uwsm >/dev/null && uwsm check is-active >/dev/null 2>&1; then
    uwsm stop
elif is_hyprland; then
    # Empty 2nd arg forces hyprctl's legacy parser, working on 0.55 (Lua) and <0.55.
    hyprctl dispatch exit ""
else
    loginctl terminate-session "${XDG_SESSION_ID}"
fi
