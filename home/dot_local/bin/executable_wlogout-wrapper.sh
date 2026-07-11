#!/bin/bash

# Toggle wlogout — dismiss if already open, otherwise launch as centered vertical list
pkill -x wlogout && exit 0

. "$HOME/.local/lib/compositor.sh"

if is_hyprland; then
    read -r W H < <(hyprctl monitors -j | jq -r '.[] | select(.focused) | "\(.width / .scale | floor) \(.height / .scale | floor)"')
fi

W=${W:-2560}
H=${H:-1440}

LIST_W=420
LIST_H=400

LR=$(( (W - LIST_W) / 2 ))
TB=$(( (H - LIST_H) / 2 ))

# Force dark GTK theme — Breeze (light) overrides wlogout's dark CSS otherwise
exec env GTK_THEME=Breeze-Dark wlogout -b 1 -n -s \
    -L "$LR" -R "$LR" \
    -T "$TB" -B "$TB" \
    -r 8
