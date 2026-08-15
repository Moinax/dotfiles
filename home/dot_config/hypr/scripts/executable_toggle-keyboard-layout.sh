#!/bin/bash
set -e

# Directory containing your input layout template files
LAYOUTS_DIR="$HOME/.config/hypr/conf/input-layouts"

EXT="lua"

# Path to the active input configuration file
ACTIVE_INPUT_CONF="$HOME/.config/hypr/conf/input.$EXT"

# --- Discover available layouts and their order ---
# We'll store full paths for direct copying.
mapfile -t LAYOUT_FILES < <(find "$LAYOUTS_DIR" -maxdepth 1 -name "*.$EXT" | sort)
if [ "${#LAYOUT_FILES[@]}" -eq 0 ]; then
    notify-send -u critical "Hyprland Keyboard Layout Toggle Error" "No .$EXT layout files found in: $LAYOUTS_DIR"
    echo "Error: No .$EXT layout files found in $LAYOUTS_DIR" >&2
    exit 1
fi

# --- Prepare layout names for Rofi and map them to their full paths ---
declare -A layout_paths # Associative array to map display name to file path
layout_display_names=() # Array to store names for Rofi display

for layout_file_path in "${LAYOUT_FILES[@]}"; do
    # Extract the display name (e.g., "English" from "1_english.lua")
    display_name=$(basename "$layout_file_path" | sed -E 's/^[0-9]+_//' | sed -E "s/\.$EXT$//" | sed 's/_/ /g' | sed 's/\b\(.\)/\U\1/g')

    layout_paths["$display_name"]="$layout_file_path"
    layout_display_names+=("$display_name")
done

# --- Non-interactive modes, for the vicinae Keyboard Layout command ---
# `list` prints "<display name>\t<active 0|1>", `set NAME` applies one. The
# copy-and-notify below is left as the single implementation of "switch layout";
# only the picking is done elsewhere.
#
# Active is decided on kb_layout + kb_variant, not by diffing the files. A
# whole-file compare looks tempting — input.lua is written by `cp` from one of
# these templates — but it is wrong the moment the two drift for any reason
# unrelated to the layout: input.lua starts life as chezmoi's create_input.lua
# seed, and today it matches 2_french.lua on kb_layout while lacking that
# template's touchpad block, so a compare reports *nothing* active. The layout
# keys are the only part that actually defines which layout is in force.
kb_id() { # $1: a lua input config → "<layout>/<variant>"
    sed -n 's/.*kb_layout  *= *"\([^"]*\)".*/\1/p' "$1" | head -1 | tr -d '\n'
    printf '/'
    sed -n 's/.*kb_variant  *= *"\([^"]*\)".*/\1/p' "$1" | head -1
}

case "${1:-}" in
    list)
        active_id="$(kb_id "$ACTIVE_INPUT_CONF")"
        for display_name in "${layout_display_names[@]}"; do
            if [ "$(kb_id "${layout_paths[$display_name]}")" = "$active_id" ]; then
                printf '%s\t1\n' "$display_name"
            else
                printf '%s\t0\n' "$display_name"
            fi
        done
        exit 0
        ;;
    set)
        [ -n "${2:-}" ] || { echo "toggle-keyboard-layout: set requires a layout name" >&2; exit 1; }
        selected_display_name="$2"
        ;;
    *)
        echo "toggle-keyboard-layout: unknown mode '${1:-<none>}' (expected: list | set NAME)" >&2
        exit 1
        ;;
esac

# --- Get the selected layout's file path ---
NEXT_LAYOUT_FILE="${layout_paths[$selected_display_name]}"

# Check if the selected file path is valid (should always be if from our map)
if [ -z "$NEXT_LAYOUT_FILE" ] || [ ! -f "$NEXT_LAYOUT_FILE" ]; then
    notify-send -u critical "Hyprland Keyboard Layout Toggle Error" "Invalid layout selected or file not found: $selected_display_name"
    echo "Error: Invalid layout selected or file not found: $selected_display_name" >&2
    exit 1
fi

# --- Copy the content of the selected layout to the active config file ---
# Success is silent — the waybar keyboard-layout module already shows the
# active layout, and the callers are headless (vicinae, waybar); only
# failures notify. Hyprland reloads the config on write.
cp "$NEXT_LAYOUT_FILE" "$ACTIVE_INPUT_CONF"
