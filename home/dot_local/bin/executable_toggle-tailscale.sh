#!/bin/bash
set -e

# Toggle Tailscale VPN: connect or disconnect

if tailscale status &>/dev/null; then
    tailscale down
    notify-send -u low "Tailscale" "Disconnected"
else
    # --accept-dns=false: never let Tailscale override our NetworkManager DNS
    # (1.1.1.1 / 8.8.8.8). Without it, tailscaled installs itself as the default
    # DNS route in systemd-resolved and a stale, server-less tailscale0 route is
    # left behind on `down`, breaking resolution.
    tailscale up --accept-dns=false
    notify-send -u low "Tailscale" "Connected"
fi

pkill -RTMIN+11 waybar || true
