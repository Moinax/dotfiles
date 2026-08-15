#!/usr/bin/env bash
# wallpaper-picker — enumerate wallpapers and apply one via awww.
#   wallpaper-picker.sh list [DIR]     → print candidate image paths, one per line
#   wallpaper-picker.sh apply FILE     → apply FILE
#   wallpaper-picker.sh publish [FILE] → republish for the lock/login screens
#                                        (no FILE = whatever awww is showing)
#
# No menu of its own: the vicinae Wallpaper command (Mod+W) is the
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

    # The desktop is already set at this point, so a publish failure has been
    # notified and must not fail the pick.
    publish_wallpaper "$target" || true
}

# Republish for the two screens that are not the desktop: hyprlock and the Plasma
# login greeter both read this one file, so picking is the single act that changes
# all three. A copy and not a symlink, and the directory needs one privileged
# creation — the reasons are in CLAUDE.md, under the /var/lib/wallpaper entry.
PUBLISHED_DIR=/var/lib/wallpaper
PUBLISHED_WALLPAPER="$PUBLISHED_DIR/current"

# What the desktop is showing, for a publish with no file named.
current_wallpaper() {
    awww query 2>/dev/null | sed -n 's/.*currently displaying: image: //p' | head -n1
}

publish_wallpaper() { # $1: image to publish
    # Write beside the target and rename: hyprlock reads this file at lock time,
    # which can land in the middle of a pick, and a rename within one directory
    # is the only way it never sees a half-copied image.
    local tmp="$PUBLISHED_WALLPAPER.new"
    if [ -w "$PUBLISHED_DIR" ] &&
        cp -f "$1" "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$PUBLISHED_WALLPAPER"; then
        return 0
    fi

    # Say so rather than skip quietly. An unwritable directory means the machine
    # never ran the installer's setup_login_wallpaper, and picking a wallpaper is
    # the one moment the user is looking at wallpapers and can act on it.
    rm -f "$tmp"
    notify-send "Wallpaper" "Set on the desktop, but the lock and login screens keep the old one" || true
    return 1
}

if [ "${1:-}" = "apply" ]; then
    [ -n "${2:-}" ] || { echo "wallpaper-picker: apply requires a file" >&2; exit 1; }
    apply_wallpaper "$2"
    exit 0
fi

if [ "${1:-}" = "publish" ]; then
    # No file named: publish what the desktop already shows. That is what the
    # installer's seed wants, and it keeps the `awww query` parse in one place.
    published_target="${2:-$(current_wallpaper)}"
    if [ -z "$published_target" ]; then
        echo "wallpaper-picker: nothing to publish — no file given and awww shows none" >&2
        exit 1
    fi
    publish_wallpaper "$published_target"
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

echo "wallpaper-picker: unknown mode '${1:-<none>}' (expected: list [DIR] | apply FILE | publish [FILE])" >&2
exit 1
