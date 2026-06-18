#!/bin/bash
# Waybar custom module: HDR/SDR status for the HDR-capable monitor (DP-3).
# Click toggles via toggle-hdr.sh; refreshed on RTMIN+9.

MON="${HDR_MONITOR:-DP-3}"

preset="$(hyprctl monitors -j 2>/dev/null \
    | jq -r --arg m "$MON" 'first(.[] | select(.name == $m) | .colorManagementPreset) // empty')"

case "$preset" in
    hdr)
        printf '{"text": "HDR", "class": "hdr", "tooltip": "HDR on (%s, 10-bit)"}\n' "$MON"
        ;;
    "")
        # Monitor not connected — emit empty so the module hides.
        printf '{"text": ""}\n'
        ;;
    *)
        printf '{"text": "SDR", "class": "sdr", "tooltip": "SDR (%s, 8-bit srgb)"}\n' "$MON"
        ;;
esac
