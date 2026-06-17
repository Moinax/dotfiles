#!/bin/bash
# Control Hyprland DPMS for all monitors.
#
# Input wake is handled by Hyprland's misc:{mouse_move,key_press}_enables_dpms.
set -euo pipefail

mode="${1:-toggle}"

dpms_on() {
    exec hyprctl dispatch 'hl.dsp.dpms("on")'
}

dpms_off() {
    # Let the key/button event that launched the command finish before DPMS-off.
    # Otherwise Hyprland's native key/mouse DPMS wake can immediately turn the
    # outputs back on, which looks like a blink.
    sleep 0.35
    exec hyprctl dispatch 'hl.dsp.dpms("off")'
}

case "$mode" in
    on)
        dpms_on
        ;;
    off)
        dpms_off
        ;;
    toggle)
        if state="$(hyprctl monitors -j 2>/dev/null)" &&
            jq -e 'length > 0 and all(.[]; .dpmsStatus == false)' >/dev/null <<<"$state"; then
            dpms_on
        fi

        dpms_off
        ;;
    *)
        echo "Usage: ${0##*/} [toggle|on|off]" >&2
        exit 2
        ;;
esac
