#!/bin/bash
# Print current keyboard layout code for waybar

. "$HOME/.local/lib/compositor.sh"

if is_hyprland; then
    keymap=$(hyprctl devices -j 2>/dev/null \
        | jq -r '([.keyboards[] | select(.main)][0] // .keyboards[0]).active_keymap // empty')
    case "$keymap" in
        English*) echo "EN" ;;
        French*)  echo "FR" ;;
        Belgian*) echo "BE" ;;
        *)         echo "??" ;;
    esac
else
    echo "??"
fi
