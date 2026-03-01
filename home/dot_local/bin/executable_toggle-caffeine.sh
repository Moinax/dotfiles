#!/bin/bash
set -e

# Toggle caffeine mode: kill or restart the idle daemon
# Works with both Hyprland (hypridle) and Niri (swayidle)

if pgrep -x Hyprland &>/dev/null; then
    DAEMON="hypridle"
elif pgrep -x niri &>/dev/null; then
    DAEMON="swayidle"
else
    notify-send -u critical "Caffeine" "Unknown compositor"
    exit 1
fi

if pgrep -x "$DAEMON" &>/dev/null; then
    killall "$DAEMON"
    notify-send -u low "Caffeine" "ON — idle inhibited"
else
    nohup "$DAEMON" &>/dev/null & disown
    notify-send -u low "Caffeine" "OFF — idle resumed"
fi

pkill -RTMIN+10 waybar || true
