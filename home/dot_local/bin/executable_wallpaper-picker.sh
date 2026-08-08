#!/usr/bin/env bash
# wallpaper-picker — enumerate wallpapers and apply one via awww.
#   wallpaper-picker.sh list [DIR]   → print candidate image paths, one per line
#   wallpaper-picker.sh apply FILE   → apply FILE
#
# No menu of its own: the vicinae Wallpaper command (Mod+Shift+W) is the
# frontend, and it renders a real grid rather than the one-line rows with tiny
# icons that rofi could draw. `apply` covers the daemon handling — the only
# tricky part here, easy to get subtly wrong, see the comment about not
# restarting a live daemon — and `list` covers what counts as a wallpaper, so
# the two front doors cannot disagree about what is on offer.
set -e

WALLPAPER_DIR="${WALLPAPER_DIR:-$HOME/Wallpapers}"

# One definition of "an image we can set".
list_wallpapers() { # $1: directory
    find "$1" -maxdepth 1 -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) \
        | sort
}

apply_wallpaper() {
    local target="$1"
    [ -f "$target" ] || { notify-send -u critical "Wallpaper" "No such file: $target"; exit 1; }

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
}

if [ "${1:-}" = "apply" ]; then
    [ -n "${2:-}" ] || { echo "wallpaper-picker: apply requires a file" >&2; exit 1; }
    apply_wallpaper "$2"
    exit 0
fi

if [ "${1:-}" = "list" ]; then
    # An explicit directory overrides $WALLPAPER_DIR so the vicinae preference
    # has somewhere to go — without it the launcher would enumerate for itself.
    [ -n "${2:-}" ] && WALLPAPER_DIR="$2"
    if [ ! -d "$WALLPAPER_DIR" ]; then
        echo "wallpaper-picker: directory not found: $WALLPAPER_DIR" >&2
        exit 1
    fi
    list_wallpapers "$WALLPAPER_DIR"
    exit 0
fi

echo "wallpaper-picker: unknown mode '${1:-<none>}' (expected: list [DIR] | apply FILE)" >&2
exit 1
