#!/bin/bash
set -e

# Restart swayidle after resume from sleep to reset idle timers.
# Without this, swayidle counts suspend time as idle time and
# immediately re-locks the session after the user unlocks.

CAFFEINE_STATE="${XDG_RUNTIME_DIR:-/tmp}/caffeine-state"

gdbus monitor --system \
    --dest org.freedesktop.login1 \
    --object-path /org/freedesktop/login1 2>/dev/null |
while read -r line; do
    if [[ "$line" == *"PrepareForSleep"*"false"* ]]; then
        # Wait for user to unlock before restarting
        while pidof swaylock hyprlock > /dev/null 2>&1; do
            sleep 1
        done
        # Preserve caffeine mode: when caffeine is on, toggle-caffeine.sh
        # owns swayidle's lifecycle (it's intentionally killed). Don't respawn.
        if [ "$(cat "$CAFFEINE_STATE" 2>/dev/null)" = "on" ]; then
            continue
        fi
        pkill -x swayidle 2>/dev/null || true
        for ((i=0; i<20; i++)); do
            pgrep -x swayidle >/dev/null || break
            sleep 0.1
        done
        swayidle -w &
    fi
done
