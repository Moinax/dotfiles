#!/usr/bin/env bash
# Toggle the active workspace between the `scrolling` (tape) layout and the
# host's baseline (dwindle on the desktop, scrolling on the laptop). State
# is persisted in $XDG_CACHE_HOME so the toggle survives reloads.
set -e

state_file="${XDG_CACHE_HOME:-$HOME/.cache}/hypr-ws-layout"
mkdir -p "$(dirname "$state_file")"
touch "$state_file"

ws_id=$(hyprctl activeworkspace -j | jq -r '.id')

# Baseline layout for any workspace — matches general.lua's `layout` field.
baseline_for() {
    printf 'dwindle'
}

current=$(awk -F= -v id="$ws_id" '$1 == id { print $2 }' "$state_file")
[[ -z "$current" ]] && current=$(baseline_for "$ws_id")

if [[ "$current" == "scrolling" ]]; then
    target=$(baseline_for "$ws_id")
else
    target="scrolling"
fi

# Hyprland 0.55: hyprctl keyword fails with "non-legacy parsers" on workspace
# rules. The runtime-equivalent is `hl.workspace_rule({...})` via `eval`.
hyprctl eval "hl.workspace_rule({ workspace = \"${ws_id}\", layout = \"${target}\" })" >/dev/null

# Persist by replacing any existing line for this workspace id.
tmp="${state_file}.tmp"
grep -v "^${ws_id}=" "$state_file" >"$tmp" 2>/dev/null || true
printf '%s=%s\n' "$ws_id" "$target" >>"$tmp"
mv "$tmp" "$state_file"

notify-send -t 1500 "Hyprland layout" "WS ${ws_id}: ${current} → ${target}"
