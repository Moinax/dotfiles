#!/bin/bash

# Toggle speech-to-text dictation via hyprvoice
# Bound to Mod+D in both Hyprland and Niri

if ! command -v hyprvoice &>/dev/null; then
    notify-send -u critical "Dictation" "hyprvoice is not installed"
    exit 1
fi

# Ensure the daemon is running
if ! hyprvoice status &>/dev/null; then
    hyprvoice serve &
    disown
    sleep 0.5
fi

# Toggle recording on/off
hyprvoice toggle
