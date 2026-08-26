#!/bin/bash
set -e
set -o pipefail

# Directory containing your input layout template files
LAYOUTS_DIR="$HOME/.config/hypr/conf/input-layouts"

EXT="lua"
DEFAULT_LAYOUT="2_french.lua"

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

# --- Prepare display names and map them to their metadata files ---
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
# script owns both listing and applying so they use the same XKB group index.
# input.lua keeps fr,us,be loaded together; changing group never reloads the
# config and therefore cannot disturb runtime monitor state such as HDR.
layout_index() { # $1: a lua metadata file → zero-based XKB group index
    sed -n 's/^[[:space:]]*return[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$1" | head -1
}

active_layout_index() {
    hyprctl devices -j 2>/dev/null \
        | jq -r '([.keyboards[] | select(.main)][0] // .keyboards[0]).active_layout_index // empty'
}

persist_layout() { # $1: layout template
    mkdir -p "$STATE_DIR"
    basename "$1" > "$STATE_FILE"
}

watch_layout_events() {
    local socket event keyboard desired_file desired_index current_index
    socket="${XDG_RUNTIME_DIR:?}/hypr/${HYPRLAND_INSTANCE_SIGNATURE:?}/.socket2.sock"

    # A newly attached keyboard announces its initial group through
    # `activelayout`. It always starts at group 0, so bring that device to the
    # persisted group without touching keyboards that are already in sync.
    socat -u "UNIX-CONNECT:$socket" - | while IFS= read -r event; do
        case "$event" in
            activelayout\>\>*) ;;
            *) continue ;;
        esac

        keyboard="${event#activelayout>>}"
        keyboard="${keyboard%%,*}"
        desired_file="$LAYOUTS_DIR/$(sed -n '1p' "$STATE_FILE" 2>/dev/null || true)"
        [ -f "$desired_file" ] || desired_file="$LAYOUTS_DIR/$DEFAULT_LAYOUT"
        desired_index="$(layout_index "$desired_file")"
        [[ "$desired_index" =~ ^[0-9]+$ ]] || continue

        current_index="$(hyprctl devices -j 2>/dev/null | jq -r --arg keyboard "$keyboard" \
            '[.keyboards[] | select(.name == $keyboard)][0].active_layout_index // empty')"
        if [ -n "$current_index" ] && [ "$current_index" != "$desired_index" ]; then
            hyprctl switchxkblayout "$keyboard" "$desired_index" >/dev/null 2>&1 || true
        fi
    done
}

case "${1:-}" in
    watch)
        watch_layout_events
        exit 0
        ;;
    list)
        active_index="$(active_layout_index)"
        for display_name in "${layout_display_names[@]}"; do
            if [ "$(layout_index "${layout_paths[$display_name]}")" = "$active_index" ]; then
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

# Always apply the selected group to every keyboard. This also brings a keyboard
# hot-plugged since the previous switch into sync when the user reselects the
# layout already marked active.
next_index="$(layout_index "$NEXT_LAYOUT_FILE")"
if ! [[ "$next_index" =~ ^[0-9]+$ ]]; then
    notify-send -u critical "Hyprland Keyboard Layout Toggle Error" "Invalid layout index: $selected_display_name"
    echo "Error: Invalid layout index in $NEXT_LAYOUT_FILE" >&2
    exit 1
fi
# Persist first so the hot-plug watcher recognizes events caused by this
# intentional switch as the new desired state.
previous_layout="$(sed -n '1p' "$STATE_FILE" 2>/dev/null || true)"
persist_layout "$NEXT_LAYOUT_FILE"

# Switch every keyboard to the selected group in the shared keymap.
if ! hyprctl switchxkblayout all "$next_index" >/dev/null 2>&1; then
    if [ -n "$previous_layout" ]; then
        printf '%s\n' "$previous_layout" > "$STATE_FILE"
    else
        unlink "$STATE_FILE"
    fi
    notify-send -u critical "Hyprland Keyboard Layout Toggle Error" "Could not apply: $selected_display_name"
    echo "Error: Hyprland rejected layout: $selected_display_name" >&2
    exit 1
fi
