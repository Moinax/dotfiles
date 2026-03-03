#!/bin/bash

# Toggle between dark and light mode

STATE_FILE="$HOME/.local/share/dark-light-mode"
CURRENT=$(cat "$STATE_FILE" 2>/dev/null || echo "dark")

if [ "$CURRENT" = "dark" ]; then
    ~/.local/bin/apply-dark-mode.sh light
else
    ~/.local/bin/apply-dark-mode.sh dark
fi
