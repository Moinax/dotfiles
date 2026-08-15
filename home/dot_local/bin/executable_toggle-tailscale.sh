#!/bin/bash
set -e

# Toggle Tailscale VPN: connect or disconnect.
# Success is silent — the waybar module already shows the state; only failures notify.

if tailscale status &>/dev/null; then
    output=$(tailscale down 2>&1) ||
        { notify-send -u critical "Tailscale" "Disconnect failed: $output"; exit 1; }
else
    # --accept-dns=false: never let Tailscale override our NetworkManager DNS
    # (1.1.1.1 / 8.8.8.8). Without it, tailscaled installs itself as the default
    # DNS route in systemd-resolved and a stale, server-less tailscale0 route is
    # left behind on `down`, breaking resolution.
    output=$(tailscale up --accept-dns=false 2>&1) ||
        { notify-send -u critical "Tailscale" "Connect failed: $output"; exit 1; }
fi

pkill -RTMIN+11 waybar || true
