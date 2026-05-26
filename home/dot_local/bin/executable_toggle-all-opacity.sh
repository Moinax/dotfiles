#!/bin/bash

# Toggle every Hyprland window to opacity 1 and back.
#
# Tags every mapped window with `force_full_opacity`, which is matched by a
# windowrule in windowrules.lua that sets `opacity 1 override`. A second press
# removes the tag and restores the configured per-window opacity.
#
# Hyprland 0.55+ rejects `hyprctl keyword decoration:active_opacity` (non-legacy
# parser), so we can't toggle the global decoration values dynamically; tagging
# is the supported path.

set -euo pipefail

STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/hypr-all-opacity-state"
TAG="force_full_opacity"

# Capture in a single shell substitution so a failure in `hyprctl clients` or
# the parser propagates (process substitution would swallow it).
addrs_raw=$(hyprctl clients -j | python3 -c '
import json, sys
for c in json.load(sys.stdin):
    if c.get("mapped"):
        print(c["address"])
')

if [[ -z "$addrs_raw" ]]; then
    notify-send -u low "Opacity" "No mapped windows" || true
    exit 0
fi

mapfile -t ADDRS <<< "$addrs_raw"

if [[ -f "$STATE_FILE" ]]; then
    op="-"
    msg="Restored per-window opacity"
else
    op="+"
    msg="All windows → opacity 1"
fi

for addr in "${ADDRS[@]}"; do
    hyprctl dispatch "hl.dsp.window.tag({ tag = '${op}${TAG}', window = 'address:${addr}' })" >/dev/null
done

# Flip the state file only after the dispatch loop succeeds, so a mid-loop
# failure (e.g. a window closed between the clients query and the dispatch)
# leaves both the tags and the state file in their previous coherent state.
if [[ "$op" == "+" ]]; then
    touch "$STATE_FILE"
else
    rm -f "$STATE_FILE"
fi

notify-send -u low "Opacity" "$msg (${#ADDRS[@]} windows)" || true
