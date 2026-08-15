#!/bin/bash

# Toggle caffeine mode: prevent the session from going idle (lock/dpms/suspend).
#
# Hyprland: start a wl_surface-backed idle inhibitor; Hyprland honors it
# even when the surface is unmapped, so hypridle stops receiving idle events.

. "$HOME/.local/lib/compositor.sh"

STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/caffeine-state"
INHIBITOR="$HOME/.local/bin/wayland-idle-inhibitor.py"

# Success is silent — the waybar caffeine module watches the state file and
# flips instantly; only failures notify.
if is_hyprland; then
    if pgrep -f "$INHIBITOR" &>/dev/null; then
        pkill -f "$INHIBITOR" || true
        echo off > "$STATE_FILE"
    else
        nohup "$INHIBITOR" &>/dev/null & disown
        echo on > "$STATE_FILE"
    fi
else
    notify-send -u critical "Caffeine" "Unsupported compositor: ${XDG_CURRENT_DESKTOP:-unknown}" || true
    exit 1
fi
