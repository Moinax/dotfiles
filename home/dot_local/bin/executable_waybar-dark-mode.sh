#!/bin/bash

# Waybar custom module: dark/light mode status (JSON output)

STATE_FILE="$HOME/.local/share/dark-light-mode"
MODE=$(cat "$STATE_FILE" 2>/dev/null || echo "dark")

ICON_MOON=$(printf '\uf186')
ICON_SUN=$(printf '\uf185')

if [ "$MODE" = "light" ]; then
    printf '{"text": "%s", "class": "light", "tooltip": "Light mode (Catppuccin Latte)"}\n' "$ICON_SUN"
else
    printf '{"text": "%s", "class": "dark", "tooltip": "Dark mode (Catppuccin Mocha)"}\n' "$ICON_MOON"
fi
