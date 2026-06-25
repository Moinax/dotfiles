#!/bin/bash
# Lock the session, then power the screen off — bound to Mod+Alt+M.
#
# "Screen off ⇒ locked": deliberately blanking the display means you're stepping
# away, so we lock first (same model as the idle timer in hypridle.conf, which
# locks at 5min then DPMS-offs at 5.5min). Waking with mouse/key turns the screen
# back on and you unlock normally.
#
# Safety: we only blank AFTER confirming a locker is actually up. A failed lock
# must never leave a dark *unlocked* screen.
set -euo pipefail

# loginctl lock-session -> logind Lock signal -> the compositor idle daemon.
loginctl lock-session

screen_off() {
    # Niri uses its own action; Hyprland uses the documented DPMS dispatcher.
    if [ -n "${NIRI_SOCKET:-}" ]; then
        niri msg action power-off-monitors
    else
        hyprctl dispatch 'hl.dsp.dpms({ action = "disable" })'
    fi
}

# Settle delay before blanking — DO NOT remove.
#
# aquamarine drops a DPMS-off atomic commit that lands while a page-flip is still
# pending ("drm: Cannot commit when a page-flip is awaiting"), so blanking the
# instant the locker's PID appears races its first paint and silently no-ops —
# the screen stays lit and you only get a lock. hypridle dodges this with a 30s
# gap between lock (300s) and DPMS-off (330s); we wait for hyprlock to go static.
# See memory: project_dpms_off_dp_link_dead.
SETTLE_SECS=2

# Wait up to ~3s for the locker to appear, then let it finish painting before blanking.
for ((i = 0; i < 30; i++)); do
    if pidof hyprlock swaylock >/dev/null 2>&1; then
        sleep "$SETTLE_SECS"
        screen_off
        exit 0
    fi
    sleep 0.1
done

# Locker never came up — leave the screen ON rather than blank it unlocked.
notify-send "Lock failed — screen left on" "No session locker started" 2>/dev/null || true
exit 1
