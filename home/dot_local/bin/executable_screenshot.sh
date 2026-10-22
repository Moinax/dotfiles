#!/bin/bash

# Screenshot wrapper around hyprshot.
#
# hyprshot's builtin notification carries no action, so clicking it does
# nothing. It also backgrounds the whole grab (`begin_grab & checkRunning`),
# returning before the PNG is fully written — notifying right after it exits
# raced the write, and swaync dropped the notification entirely when its image
# loader hit the truncated file. hyprshot's `-- command` hook runs only after
# the file is complete, so the grab leg has hyprshot call this script back
# with the finished file, and the callback leg sends the notification.
#
# The click itself is handled by swaync's scripts hook and notify-open (the
# x-open category), not by notify-send --action's exit status — that only
# works while the popup is on screen; see notify-open.

set -e

# grab leg: hyprshot calls us back ($0) with the saved file once written.
# `-m active` grabs the focused output/window straight away; the click-to-select
# of a bare `-m output`/`-m window` runs slurp, which takes the pointer and the
# keyboard, so whatever was hovered or focused in the captured window is gone
# before the shutter. Only region still selects, which is the point of it --
# and `-z` freezes the screen under that selection (it shells out to
# hyprpicker, which the hyprland group installs), so the region is carved out
# of the frame as it was when the key was pressed, hover and all.
case "${1-}" in
    output|window)
        exec hyprshot -m active -m "$1" -s -o ~/Pictures/Screenshots -- "$0"
        ;;
    region)
        exec hyprshot -m region -z -s -o ~/Pictures/Screenshots -- "$0"
        ;;
    pick)
        # One frozen grab that is all three at once. slurp keeps the smallest
        # box containing the cursor, so the window boxes win over the -o output
        # boxes wherever they overlap; and without -r a click still takes the
        # highlighted box while a drag stays a free region. Hover a window and
        # click to get it, drag to carve a region, click a gap or the wallpaper
        # to fall through to the whole output.
        #
        # Not hyprshot: it has no such mode, and its own -z dies the moment
        # slurp exits -- its reaper races grim, so what it writes is the live
        # screen. Here hyprpicker holds the frozen frame until grim has read it,
        # which is the whole point of freezing.
        hyprpicker -r -z &
        picker=$!
        # Nothing else clears a frozen screen, so never leave it up on an error.
        trap 'kill "$picker" 2>/dev/null || true' EXIT
        sleep 0.2

        active_ws=$(hyprctl -j monitors | jq -c '[.[].activeWorkspace.id]')
        boxes=$(hyprctl -j clients | jq -r --argjson ws "$active_ws" '
            .[]
            | select(.mapped and (.hidden | not))
            | select(.workspace.id as $id | $ws | index($id))
            | "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"')

        geometry=$(slurp -o <<< "$boxes") || exit 0  # Esc or right click

        path=~/Pictures/Screenshots/$(date +'%Y-%m-%d-%H%M%S_screenshot.png')
        grim -g "$geometry" "$path"
        kill "$picker" 2>/dev/null || true
        wl-copy --type image/png < "$path"

        # hand the file to the notification leg below
        set -- "$path"
        ;;
esac

# callback leg, invoked by hyprshot: $1 is the completed screenshot.
path="${1:?usage: screenshot.sh output|window|region}"
[ -f "$path" ] || exit 0

# -A default makes the notification clickable; -c x-open plus the hint route
# the click to notify-open. notify-send would wait for the popup to expire, so
# background it — the action outcome is swaync's business, not ours.
notify-send -a Hyprshot -i "$path" -t 8000 \
    -A default=Open \
    -c x-open \
    -h "string:x-open-path:$path" \
    "Screenshot saved" \
    "Image saved in <i>${path}</i> and copied to the clipboard." >/dev/null 2>&1 &
exit 0
