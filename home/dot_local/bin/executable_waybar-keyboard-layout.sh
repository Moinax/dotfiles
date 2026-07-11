#!/bin/bash
# Print current keyboard layout code for waybar

. "$HOME/.local/lib/compositor.sh"

if is_hyprland; then
    # The active input file matches the deployed flavor (lua or conf); the
    # toggle script copies a layout file onto input.$EXT at runtime.
    for f in "$HOME/.config/hypr/conf/input.lua" \
             "$HOME/.config/hypr/conf/input.conf"; do
        [ -f "$f" ] && input_file="$f" && break
    done
    layout=$(grep -oP 'kb_layout\s*=\s*"?\K[a-z]+' \
        "${input_file:-/dev/null}" 2>/dev/null | head -1)
    echo "${layout^^}"
else
    echo "??"
fi
