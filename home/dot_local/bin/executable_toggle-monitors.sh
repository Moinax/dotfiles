#!/bin/bash
# Read and toggle connected Hyprland outputs.
#   toggle-monitors.sh list          → <name>\t<enabled>\t<mode>\t<can_disable>\t<label>
#   toggle-monitors.sh toggle NAME   → enable or disable one output
#
# No menu of its own: the vicinae Monitors command (Mod+M) is the frontend. What
# lives here is the shape of an output, the refusal to disable the last active
# one, and the monitor.lua replay that restores mode/position/scale on re-enable.

notify() {
    notify-send -u low -h int:transient:1 "Monitors" "$1" 2>/dev/null || true
}

abort() {
    notify "$1"
    exit 1
}

. "$HOME/.local/lib/compositor.sh"

is_hyprland || abort "Unsupported compositor: ${XDG_CURRENT_DESKTOP:-unknown}"

# Emit tab-separated rows: <name>\t<enabled 0|1>\t<mode>\t<label>
# A disabled output reports no mode, so that column is empty for it.
# `label` stays last because it is the only field that can contain spaces.
query_outputs() {
    hyprctl -j monitors all | jq -r '
            sort_by(.name)
            | .[]
            | [
                .name,
                (if .disabled then "0" else "1" end),
                (if .disabled or (.width // 0) == 0 then ""
                 else ((.width|tostring) + "x" + (.height|tostring) + "@" + ((.refreshRate // 0)|round|tostring))
                 end),
                (((.make // "") + " " + (.model // "")) | ltrimstr(" ") | rtrimstr(" "))
              ]
            | @tsv
        '
}

mapfile -t rows < <(query_outputs)
if [[ ${#rows[@]} -eq 0 ]]; then
    abort "No connected outputs"
fi

declare -A state_of mode_of label_of
active_count=0
order=()
for row in "${rows[@]}"; do
    IFS=$'\t' read -r name enabled mode label <<< "$row"
    order+=("$name")
    state_of["$name"]="$enabled"
    mode_of["$name"]="$mode"
    label_of["$name"]="$label"
    [[ "$enabled" == "1" ]] && ((active_count++))
done

# One dispatch on the mode, after the outputs are known — re-testing $1
# further down was how the two branch lists drifted apart.
#
# `list` exists so that the shape of an output and the rule about disabling one
# stay in the same file. It used to be argued that listing was a plain read any
# caller could do, but query_outputs is not a plain read: it sorts, derives the
# label from make+model, inverts `disabled`, and formats the mode. The vicinae
# command re-implemented all four, and mirrored the last-active refusal on top —
# so the copy, not this file, was deciding when the action was allowed.
case "${1:-}" in
    list)
        for name in "${order[@]}"; do
            can_disable=1
            [[ "${state_of[$name]}" == "1" && $active_count -le 1 ]] && can_disable=0
            printf '%s\t%s\t%s\t%s\t%s\n' \
                "$name" "${state_of[$name]}" "${mode_of[$name]}" "$can_disable" "${label_of[$name]}"
        done
        exit 0
        ;;
    toggle)
        [[ -n "${2:-}" ]] || abort "toggle requires an output name"
        name="$2"
        ;;
    *) abort "unknown mode '${1:-<none>}' (expected: list | toggle NAME)" ;;
esac

if [[ -z "${state_of[$name]:-}" ]]; then
    abort "Unknown output: $name"
fi

if [[ "${state_of[$name]}" == "1" && $active_count -le 1 ]]; then
    abort "Refused — $name is the last active output"
fi

# conf/monitor.lua holds one hl.monitor() line per output; replay it verbatim
# through `hyprctl eval` to re-enable with the configured mode/position/scale.
hypr_lua_for() {
    local n="$1" lua
    lua=$(grep -F 'hl.monitor' "$HOME/.config/hypr/conf/monitor.lua" 2>/dev/null \
        | grep -F "output = \"${n}\"" | head -1)
    if [[ -z "$lua" ]]; then
        notify "No spec for $n in monitor.lua — enabling at defaults"
        lua="hl.monitor({ output = \"${n}\", mode = \"preferred\", position = \"auto\", scale = 1 })"
    fi
    printf '%s' "$lua"
}

if [[ "${state_of[$name]}" == "1" ]]; then
    hyprctl eval "hl.monitor({ output = \"${name}\", disabled = true })" 2>/dev/null | grep -qx ok \
        || abort "Failed to disable $name"
    notify "Disabled $name"
else
    # A monitor rule does not reliably clear an existing disabled state with
    # Hyprland's Lua parser. Re-enable the output explicitly before restoring
    # its configured mode, position, scale and transform.
    hyprctl eval "hl.monitor({ output = \"${name}\", disabled = false })" 2>/dev/null | grep -qx ok \
        || abort "Failed to enable $name"
    hyprctl eval "$(hypr_lua_for "$name")" 2>/dev/null | grep -qx ok \
        || abort "Failed to restore configuration for $name"
    notify "Enabled $name"
fi
