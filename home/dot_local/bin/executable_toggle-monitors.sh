#!/bin/bash
# Toggle connected monitors on/off via rofi (Hyprland).
# Bound to SUPER+M / Mod+M.
#
# Single-select: each invocation toggles exactly one monitor. The menu
# prefixes each row with ☑ (on) or ☐ (off) to show current state.
# Refuses to disable the last active output.

MARK_ON="☑"
MARK_OFF="☐"

notify() {
    notify-send -u low -h int:transient:1 "Monitors" "$1" 2>/dev/null || true
}

abort() {
    notify "$1"
    exit 1
}

. "$HOME/.local/lib/compositor.sh"

is_hyprland || abort "Unsupported compositor: ${XDG_CURRENT_DESKTOP:-unknown}"

command -v rofi >/dev/null || abort "rofi not found"

# Emit tab-separated rows: <name>\t<enabled 0|1>\t<label>
query_outputs() {
    hyprctl -j monitors all | jq -r '
            sort_by(.name)
            | .[]
            | [
                .name,
                (if .disabled then "0" else "1" end),
                (((.make // "") + " " + (.model // "")) | ltrimstr(" ") | rtrimstr(" "))
              ]
            | @tsv
        '
}

mapfile -t rows < <(query_outputs)
if [[ ${#rows[@]} -eq 0 ]]; then
    abort "No connected outputs"
fi

declare -A state_of
active_count=0
menu=""
for row in "${rows[@]}"; do
    IFS=$'\t' read -r name enabled label <<< "$row"
    state_of["$name"]="$enabled"
    if [[ "$enabled" == "1" ]]; then
        menu+="${MARK_ON} ${name}  ${label}"$'\n'
        ((active_count++))
    else
        menu+="${MARK_OFF} ${name}  ${label}"$'\n'
    fi
done

selection=$(printf '%s' "$menu" | rofi -dmenu -i -p "Toggle Monitors")
if [[ $? -ne 0 || -z "$selection" ]]; then
    exit 0
fi

read -r _ name _ <<< "$selection"
if [[ -z "${state_of[$name]:-}" ]]; then
    abort "Unknown output: $name"
fi

if [[ "${state_of[$name]}" == "1" && $active_count -le 1 ]]; then
    abort "Refused — $name is the last active output"
fi

hypr_spec_for() {
    local n="$1" spec
    spec=$(grep -E "^monitor=${n}," "$HOME/.config/hypr/conf/monitor.conf" 2>/dev/null | head -1)
    if [[ -z "$spec" ]]; then
        notify "No spec for $n in monitor.conf — enabling at defaults"
        echo "${n},preferred,auto,1"
    else
        echo "${spec#monitor=}"
    fi
}

if [[ "${state_of[$name]}" == "1" ]]; then
    hyprctl keyword monitor "${name},disable" >/dev/null || abort "Failed to disable $name"
    notify "Disabled $name"
else
    hyprctl keyword monitor "$(hypr_spec_for "$name")" >/dev/null || abort "Failed to enable $name"
    notify "Enabled $name"
fi
