#!/bin/bash

# Toggle speech-to-text dictation via hyprvoice
# Bound to Mod+D in Hyprland

if ! command -v hyprvoice &>/dev/null; then
    notify-send -u critical "Dictation" "hyprvoice is not installed"
    exit 1
fi

# Ensure the daemon is running (hyprvoice status always exits 0, check output instead)
if ! hyprvoice status 2>/dev/null | grep -q "status="; then
    hyprvoice serve &
    disown
    # Wait up to 5s for daemon to be ready
    for _ in $(seq 1 10); do
        sleep 0.5
        hyprvoice status 2>/dev/null | grep -q "status=" && break
    done
fi

# Toggle recording on/off
hyprvoice toggle
