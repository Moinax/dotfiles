#!/bin/bash
# Toggle 10-bit HDR on the HDR-capable monitor (desktop DP-3).
#
# The session defaults to SDR (8-bit, srgb) — see hypr/conf/monitor.{lua,conf}.
# This flips the monitor to 10-bit + HDR color management at runtime and back.
# A Hyprland reload reverts to the SDR default, so HDR is always opt-in per
# session. Most desktop content (browsers, SDR YouTube) renders correctly in
# SDR; enable HDR only for HDR games / HDR video.
set -euo pipefail

MON="${HDR_MONITOR:-DP-3}"

info="$(hyprctl monitors -j 2>/dev/null)" || exit 0

# Nothing to do if the HDR monitor isn't connected (e.g. laptop).
jq -e --arg m "$MON" 'any(.[]; .name == $m)' >/dev/null <<<"$info" || exit 0

# Rebuild the geometry from live state so we preserve resolution/refresh/pos/scale.
read -r preset mode pos scale <<<"$(jq -r --arg m "$MON" '
    .[] | select(.name == $m) |
    "\(.colorManagementPreset) \(.width)x\(.height)@\(.refreshRate) \(.x)x\(.y) \(.scale)"' <<<"$info")"

# Two parsers, two mechanisms (mirrors toggle-all-opacity.sh):
#   * Lua parser (Hyprland 0.55+): `hyprctl keyword` is rejected, so push the
#     monitor config through `hyprctl eval` running the same hl.monitor() Lua as
#     conf/monitor.lua. "ok" on stdout means it took effect.
#   * Legacy parser: `eval`/hl.monitor is absent, fall back to `hyprctl keyword`.
set_cm() { # $1 = bitdepth, $2 = cm preset
    if hyprctl eval \
        "hl.monitor({ output = '$MON', mode = '$mode', position = '$pos', scale = $scale, bitdepth = $1, cm = '$2' })" \
        2>/dev/null | grep -qx ok; then
        return
    fi
    hyprctl keyword monitor "$MON,$mode,$pos,$scale,bitdepth,$1,cm,$2" >/dev/null 2>&1
}

if [ "$preset" = "hdr" ]; then
    set_cm 8 srgb
else
    set_cm 10 hdr
fi

# Refresh the waybar HDR/SDR module.
pkill -RTMIN+9 waybar 2>/dev/null || true
