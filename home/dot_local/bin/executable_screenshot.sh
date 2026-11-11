#!/bin/bash

# Screenshots. Every mode here is grim over a geometry; the only question is
# where that geometry comes from.
#
#   pick    let the pointer answer -- click a window, drag a region, click
#           the bar or a gap for the whole screen. --freeze freezes the screen
#           first, for a state that would change while you aim. The shot is
#           then cropped from a grab taken before the freeze, never grabbed
#           off hyprpicker's overlay: that overlay redraws the screen with
#           lifted blacks and drained colour, and grim faithfully saved it
#           that way.
#   output  the focused screen, no freeze, no click, shutter on the keypress.
#
# Prefixed with `geometry`, either mode prints the box instead of shooting it;
# screen-record.sh selects what to record that way.
#
# hyprshot used to do the grabbing and is gone: it has no mode like `pick`, its
# own freeze is killed by a reaper that races its grim, and it computes a
# monitor's box from the mode rather than the logical size, which is wrong on a
# rotated screen. What is left of it here is two calls to grim.
#
# The notification is clickable, and that click is handled by swaync's scripts
# hook and notify-open (the x-open category), not by notify-send --action's
# exit status -- that only works while the popup is on screen; see notify-open.

set -e

shot_dir=~/Pictures/Screenshots

# Logical boxes of the monitors "$1" selects. An odd transform is a 90/270
# rotation, which swaps the two dimensions of the mode.
monitor_boxes() {
    hyprctl -j monitors | jq -r "$1"'
        | (if (.transform % 2) == 1 then [.height, .width] else [.width, .height] end) as $m
        | "\(.x),\(.y) \(($m[0] / .scale) | round)x\(($m[1] / .scale) | round)"'
}

# Everything on screen: the windows, then the screens themselves. slurp keeps
# the smallest box containing the cursor, so a window wins wherever it covers
# one, and the bar and the gaps fall through to the whole screen.
visible_boxes() {
    local shown
    # a special workspace draws over the active one, so its windows are on
    # screen too; specialWorkspace.id is 0 when none is up
    shown=$(hyprctl -j monitors | jq -c '[.[].activeWorkspace.id] + [.[].specialWorkspace.id]')
    # a fullscreen or maximised window hides the rest of its workspace, whose
    # smaller boxes would otherwise win under the cursor
    hyprctl -j clients | jq -r --argjson shown "$shown" '
        map(select(.mapped and (.hidden | not)))
        | map(select(.workspace.id as $id | $shown | index($id)))
        | group_by(.workspace.id)[]
        | (map(select(.fullscreen > 0)) | if length > 0 then . else empty end) // .
        | .[]
        | "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"'
    monitor_boxes '.[]'
}

# slurp's own rule, for the times we have to answer in its place.
smallest_box_at() {
    awk -v x="$1" -v y="$2" '
        { split($1, o, ","); split($2, s, "x")
          if (x >= o[1] && x < o[1] + s[1] && y >= o[2] && y < o[2] + s[2]) {
              area = s[1] * s[2]
              if (best == "" || area < best) { best = area; sel = $1 " " $2 }
          } }
        END { print sel }'
}

print_only=
if [ "${1-}" = geometry ]; then
    print_only=1
    shift
fi

case "${1-}" in
    pick)
        if [ "${2-}" = --freeze ]; then
            # PPM: a scratch file magick reads straight back, so skip the PNG
            # encode that sits between the keypress and the freeze.
            frozen=$(mktemp --suffix=.ppm)
            # -s 1: logical pixels, so slurp's boxes crop it as they are.
            grim -s 1 -t ppm "$frozen"
            hyprpicker -r -z >/dev/null 2>&1 &
            picker=$!
            # Nothing but this clears a frozen screen, so never leave one up.
            trap 'kill "$picker" 2>/dev/null || true; rm -f "$frozen"' EXIT
        fi

        boxes=$(visible_boxes)
        # ponytail: fixed wait for hyprpicker to map before slurp does, or the
        # click lands on the freeze; hyprctl may list a layer before it is drawn,
        # so polling it is no better. Raise it if a frozen click gets eaten.
        [ -z "${frozen-}" ] || sleep 0.2

        # Its overlay is a translucent white wash; the `slurp-no-animation`
        # layer rule (hypr windowrules) drops its fade-out, or grim catches it.
        geometry=$(slurp <<< "$boxes") || exit 0  # Esc, or a right click
        # A click that drifts a single pixel while the button is down comes
        # back as a 1x1 region -- one near-black pixel, saved as a screenshot
        # of nothing. Below a few pixels it was meant as a click, so resolve it
        # the way slurp would have had it not been dragged.
        read -r origin size <<< "$geometry"
        if [ "${size%x*}" -lt 8 ] || [ "${size#*x}" -lt 8 ]; then
            box=$(smallest_box_at "${origin%,*}" "${origin#*,}" <<< "$boxes")
            geometry=${box:-$geometry}  # nothing under it: keep slurp's own
        fi
        ;;
    output)
        geometry=$(monitor_boxes 'first(.[] | select(.focused))')
        ;;
    *)
        echo "usage: ${0##*/} [geometry] pick [--freeze]|output" >&2
        exit 2
        ;;
esac

if [ -n "$print_only" ]; then
    echo "$geometry"
    exit 0
fi

mkdir -p "$shot_dir"
path="$shot_dir/$(date +'%Y-%m-%d-%H%M%S_screenshot.png')"
if [ -n "${frozen-}" ]; then
    # The grab spans every screen, so its origin is the layout's top-left.
    read -r origin size <<< "$geometry"
    read -r ox oy < <(hyprctl -j monitors | jq -r '"\(map(.x) | min) \(map(.y) | min)"')
    magick "$frozen" -crop "${size}+$(( ${origin%,*} - ox ))+$(( ${origin#*,} - oy ))" +repage "$path"
else
    grim -g "$geometry" "$path"
fi
wl-copy --type image/png < "$path"

# -A default makes the notification clickable; -c x-open plus the hint route
# the click to notify-open. notify-send would wait for the popup to expire, so
# background it -- the action outcome is swaync's business, not ours.
notify-send -a Screenshot -i "$path" -t 8000 \
    -A default=Open \
    -c x-open \
    -h "string:x-open-path:$path" \
    "Screenshot saved" \
    "Image saved in <i>${path}</i> and copied to the clipboard." >/dev/null 2>&1 &
exit 0
