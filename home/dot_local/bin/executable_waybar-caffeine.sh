#!/bin/bash

# Waybar custom module: caffeine status (JSON output)
# Icons match the existing idle_inhibitor module

if pgrep -x Hyprland &>/dev/null; then
    DAEMON="hypridle"
elif pgrep -x niri &>/dev/null; then
    DAEMON="swayidle"
else
    printf '{"text": "%s", "class": "deactivated", "tooltip": "Unknown compositor"}\n' "$(printf '\uf186')"
    exit 0
fi

ICON_MOON=$(printf '\uf186')
ICON_COFFEE=$(printf '\uf0f4')

if pgrep -x "$DAEMON" &>/dev/null; then
    printf '{"text": "%s", "class": "deactivated", "tooltip": "Caffeine OFF (idle active)"}\n' "$ICON_MOON"
else
    printf '{"text": "%s", "class": "activated", "tooltip": "Caffeine ON (idle inhibited)"}\n' "$ICON_COFFEE"
fi
