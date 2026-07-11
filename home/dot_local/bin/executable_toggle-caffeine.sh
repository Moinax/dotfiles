#!/bin/bash

# Toggle caffeine mode: prevent the session from going idle (lock/dpms/suspend).
#
# Hyprland: start a wl_surface-backed idle inhibitor; Hyprland honors it
# even when the surface is unmapped, so hypridle stops receiving idle events.

. "$HOME/.local/lib/compositor.sh"

STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/caffeine-state"
INHIBITOR="$HOME/.local/bin/wayland-idle-inhibitor.py"

turn_on() {
    echo on > "$STATE_FILE"
    notify-send -u low "Caffeine" "ON — idle inhibited" || true
}

turn_off() {
    echo off > "$STATE_FILE"
    notify-send -u low "Caffeine" "OFF — idle resumed" || true
}

if is_hyprland; then
    if pgrep -f "$INHIBITOR" &>/dev/null; then
        pkill -f "$INHIBITOR" || true
        turn_off
    else
        nohup "$INHIBITOR" &>/dev/null & disown
        turn_on
    fi
else
    notify-send -u critical "Caffeine" "Unsupported compositor: ${XDG_CURRENT_DESKTOP:-unknown}" || true
    exit 1
fi
