#!/bin/bash
set -e

# Directory containing your input layout template files
LAYOUTS_DIR="$HOME/.config/hypr/conf/input-layouts"

EXT="lua"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/hypr"
STATE_FILE="$STATE_DIR/keyboard-layout"

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
# script owns both listing and applying so they use the same kb_layout +
# kb_variant identity. The active values come from Hyprland itself; input.lua is
# now a stable loader and is never rewritten at runtime.
kb_id() { # $1: a lua input config → "<layout>/<variant>"
    sed -n 's/.*kb_layout  *= *"\([^"]*\)".*/\1/p' "$1" | head -1 | tr -d '\n'
    printf '/'
    sed -n 's/.*kb_variant  *= *"\([^"]*\)".*/\1/p' "$1" | head -1
}

active_kb_id() {
    local layout variant
    layout="$(hyprctl getoption input:kb_layout -j 2>/dev/null | jq -r '.str // empty')"
    variant="$(hyprctl getoption input:kb_variant -j 2>/dev/null | jq -r '.str // empty')"
    printf '%s/%s\n' "$layout" "$variant"
}

persist_layout() { # $1: layout template
    mkdir -p "$STATE_DIR"
    basename "$1" > "$STATE_FILE"
}

case "${1:-}" in
    list)
        active_id="$(active_kb_id)"
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

# Selecting the layout already in force needs no compositor call, but still
# repairs missing or stale persistence state.
active_id="$(active_kb_id)"
next_id="$(kb_id "$NEXT_LAYOUT_FILE")"
if [ "$next_id" = "$active_id" ]; then
    persist_layout "$NEXT_LAYOUT_FILE"
    exit 0
fi

# Apply the template directly in the running compositor. Unlike writing an
# imported config file, `hyprctl eval` changes only input state and therefore
# leaves runtime monitor settings (including HDR) untouched.
layout_lua="$(<"$NEXT_LAYOUT_FILE")"
if ! hyprctl eval $'do\n'"$layout_lua"$'\nend' 2>/dev/null | grep -qx ok; then
    notify-send -u critical "Hyprland Keyboard Layout Toggle Error" "Could not apply: $selected_display_name"
    echo "Error: Hyprland rejected layout: $selected_display_name" >&2
    exit 1
fi

# Persistence is deliberately outside ~/.config/hypr: input.lua reads this on
# startup or an unrelated future reload, but changing it triggers no reload.
persist_layout "$NEXT_LAYOUT_FILE"
