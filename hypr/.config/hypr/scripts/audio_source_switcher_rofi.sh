#!/bin/bash

# Get list of audio sinks and their IDs from the Sinks section
sinks=$(wpctl status | sed -n '/Sinks:/,/Sources:/p' | grep -E '^[[:space:]]*│' | sed 's/^.*│ *\*\? *//')

# Use Rofi to select a sink
selected_sink=$(echo "$sinks" | sed 's/^[0-9]\+\. //;s/ \[vol: [0-9.]\+\]$//' | rofi -dmenu -i -p "Select Audio Output:")

# Exit if nothing was selected
if [ -z "$selected_sink" ]; then
    exit 0
fi

# Extract the ID from the original sink line
sink_id=$(echo "$sinks" | grep "$selected_sink" | awk '{print $1}' | sed 's/\.$//')

# Set as default
wpctl set-default "$sink_id"

# Notify user
notify-send "Audio Output Changed" "Switched to: $selected_sink"
