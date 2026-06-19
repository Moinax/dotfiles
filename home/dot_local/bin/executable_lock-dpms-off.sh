#!/bin/bash
# Lock the session, then power the screen off — bound to Mod+Alt+M.
#
# "Screen off ⇒ locked": deliberately blanking the display means you're stepping
# away, so we lock first (same model as the idle timer in hypridle.conf, which
# locks at 5min then DPMS-offs at 5.5min). Waking with mouse/key turns the screen
# back on and you unlock normally.
#
# Safety: we only blank AFTER confirming swaylock is actually up. A failed lock
# must never leave a dark *unlocked* screen.
set -euo pipefail

# loginctl lock-session -> logind Lock signal -> hypridle lock_cmd (swaylock).
loginctl lock-session

screen_off() {
    # Niri uses its own action; everything else (Hyprland here) goes through the
    # shared hyprctl DPMS helper.
    if [ -n "${NIRI_SOCKET:-}" ]; then
        niri msg action power-off-monitors
    else
        "$HOME/.local/bin/toggle-dpms.sh" off
    fi
}

# Wait up to ~3s for the locker to appear before blanking.
for ((i = 0; i < 30; i++)); do
    if pidof swaylock >/dev/null 2>&1; then
        screen_off
        exit 0
    fi
    sleep 0.1
done

# Locker never came up — leave the screen ON rather than blank it unlocked.
notify-send "Lock failed — screen left on" "swaylock did not start" 2>/dev/null || true
exit 1
