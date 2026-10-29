#!/usr/bin/env bash
# Blur variant (Hyprland 0.57+), for the vicinae Blur Variant command (Mod+Alt+W).
#
#   list      "<variant>\t<active 0|1>", in Hyprland's own order (kawase first)
#   set NAME  apply NAME live and persist it for decoration.lua
#
# The names come from Hyprland's option map rather than a copy here, so a
# release that adds a variant shows up without touching this file. `set`
# checks the name against that map first: an unknown value passed to
# `hyprctl eval` is a config error, and that one paints the red error bar.
set -e

state_file="${XDG_STATE_HOME:-$HOME/.local/state}/hypr/blur-variant"

variants() {
    hyprctl -j descriptions | jq -r '
        .[] | select(.name == "decoration:blur:variant")
        | .map | map(to_entries[0]) | sort_by(.value)[] | "\(.value)\t\(.key)"'
}

case "${1-}" in
    list)
        active=$(hyprctl -j getoption decoration:blur:variant | jq -r '.int')
        variants | while IFS=$'\t' read -r id name; do
            printf '%s\t%d\n' "$name" "$((id == active))"
        done
        ;;
    set)
        name=${2-}
        variants | cut -f2 | grep -qxF -- "$name" || { echo "unknown blur variant: $name" >&2; exit 1; }
        hyprctl eval "hl.config({ decoration = { blur = { variant = \"$name\" } } })" >/dev/null
        mkdir -p "$(dirname "$state_file")"
        printf '%s\n' "$name" > "$state_file"
        ;;
    *)
        echo "usage: ${0##*/} list|set NAME" >&2
        exit 2
        ;;
esac
