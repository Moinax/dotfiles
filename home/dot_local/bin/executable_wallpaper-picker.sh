#!/usr/bin/env bash
# wallpaper-picker — rofi-based wallpaper picker, applies via awww.
# Lists ~/Wallpapers/* (jpg/jpeg/png/webp) with thumbnails.
set -e

WALLPAPER_DIR="${WALLPAPER_DIR:-$HOME/Wallpapers}"

if [ ! -d "$WALLPAPER_DIR" ]; then
    notify-send -u critical "Wallpaper picker" "Directory not found: $WALLPAPER_DIR"
    exit 1
fi

# `\0icon\x1f<path>` is rofi's dmenu icon-row format; -show-icons turns it on.
chosen=$(
    find "$WALLPAPER_DIR" -maxdepth 1 -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) \
        | sort \
        | while IFS= read -r f; do
            printf '%s\0icon\x1f%s\n' "${f##*/}" "$f"
          done \
        | rofi -dmenu -i -p "Wallpaper" -show-icons \
            -theme "$HOME/.local/share/rofi/themes/wallpaper.rasi"
)

[ -z "$chosen" ] && exit 0
target="$WALLPAPER_DIR/$chosen"

# Apply onto the running daemon for a single clean transition. We do NOT
# restart a live daemon: a restart triggers awww's cache-restore, which
# flashes the previous wallpaper before the transition lands. Only
# cold-start the daemon if it isn't running at all.
if ! awww query >/dev/null 2>&1; then
    systemctl --user start awww-daemon.service 2>/dev/null || setsid -f awww-daemon
    ready=
    for _ in $(seq 1 50); do
        awww query >/dev/null 2>&1 && { ready=1; break; }
        sleep 0.1
    done
    if [ -z "$ready" ]; then
        notify-send -u critical "Wallpaper" "awww-daemon did not start"
        exit 1
    fi
fi

awww img --transition-type any --transition-fps 60 --transition-duration 1 "$target"
