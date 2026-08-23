#!/bin/bash
# Print current keyboard layout code for waybar

. "$HOME/.local/lib/compositor.sh"

if is_hyprland; then
    layout=$(hyprctl getoption input:kb_layout -j 2>/dev/null | jq -r '.str // empty')
    echo "${layout^^}"
else
    echo "??"
fi
