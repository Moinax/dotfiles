#!/bin/bash
# Print current keyboard layout code for waybar

. "$HOME/.local/lib/compositor.sh"

if is_hyprland; then
    # The toggle script copies a layout file onto input.lua at runtime.
    layout=$(grep -oP 'kb_layout\s*=\s*"?\K[a-z]+' \
        "$HOME/.config/hypr/conf/input.lua" 2>/dev/null | head -1)
    echo "${layout^^}"
else
    echo "??"
fi
