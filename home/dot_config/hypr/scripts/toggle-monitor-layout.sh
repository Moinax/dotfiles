#!/bin/bash

# Path to the active monitor configuration file
ACTIVE_MONITOR_CONF="$HOME/.config/hypr/conf/monitor.conf"

# Directory containing your monitor layout template files
LAYOUTS_DIR="$HOME/.config/hypr/conf/monitor-layouts"

# Ensure the layouts directory exists
mkdir -p "$LAYOUTS_DIR"

# Ensure the active monitor conf file exists (it should, as hyprland sources it)
touch "$ACTIVE_MONITOR_CONF"

# --- Discover available layouts and their order ---
# Read all .conf files from the layouts directory into an array, sorted alphabetically.
# We'll store full paths for direct copying.
mapfile -t LAYOUT_FILES < <(find "$LAYOUTS_DIR" -maxdepth 1 -name "*.conf" | sort)

# Check if any layout files were found
if [ ${#LAYOUT_FILES[@]} -eq 0 ]; then
    notify-send -u critical "Hyprland Monitor Toggle Error" "No monitor layout files found in: $LAYOUTS_DIR/*.conf"
    echo "Error: No monitor layout files found in $LAYOUTS_DIR/*.conf" >&2
    exit 1
fi

# --- Prepare layout names for Rofi and map them to their full paths ---
declare -A layout_paths # Associative array to map display name to file path
layout_display_names=() # Array to store names for Rofi display

for layout_file_path in "${LAYOUT_FILES[@]}"; do
    # Extract the display name (e.g., "Three Monitors" from "1_three_monitors.conf")
    display_name=$(basename "$layout_file_path" | sed -E 's/^[0-9]+_//' | sed 's/\.conf$//' | sed 's/_/ /g' | sed 's/\b\(.\)/\U\1/g')

    layout_paths["$display_name"]="$layout_file_path"
    layout_display_names+=("$display_name")
done

# --- Use Rofi to select a layout ---
selected_display_name=$(printf "%s\n" "${layout_display_names[@]}" | rofi -dmenu -i -p "Select Monitor Layout:")

# Exit if nothing was selected (Rofi was closed or ESC pressed)
if [ -z "$selected_display_name" ]; then
    echo "No layout selected. Exiting."
    exit 0
fi

# --- Get the selected layout's file path ---
NEXT_LAYOUT_FILE="${layout_paths[$selected_display_name]}"

# Check if the selected file path is valid (should always be if from our map)
if [ -z "$NEXT_LAYOUT_FILE" ] || [ ! -f "$NEXT_LAYOUT_FILE" ]; then
    notify-send -u critical "Hyprland Monitor Toggle Error" "Invalid layout selected or file not found: $selected_display_name"
    echo "Error: Invalid layout selected or file not found: $selected_display_name" >&2
    exit 1
fi

# --- Copy the content of the selected layout to the active config file ---
echo "Switching to '$selected_display_name' layout..."
cp "$NEXT_LAYOUT_FILE" "$ACTIVE_MONITOR_CONF"

# Send notification
notify-send -u low "Hyprland" "Switched to: $selected_display_name Layout"
echo "Monitor layout switch complete. Hyprland will reload automatically."
