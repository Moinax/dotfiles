#!/bin/bash
set -e

# Toggle Tailscale VPN: connect or disconnect.
# Success is silent — the waybar module already shows the state; only failures notify.

if tailscale status &>/dev/null; then
    output=$(tailscale down 2>&1) ||
        { notify-send -u critical "Tailscale" "Disconnect failed: $output"; exit 1; }
else
    # No --accept-dns here, deliberately: a bare `up` keeps whatever the stored
    # pref says, so this toggle asserts no DNS policy at all. `dots setup` owns
    # that decision once, and a `tailscale set` you make by hand survives.
    #
    # It used to force --accept-dns=false, on the belief that tailscaled would
    # install itself as the *default* DNS route and leave a stale, server-less
    # tailscale0 route behind on `down`. Measured on 1.102.2, neither half holds
    # here: the tailnet declares no global resolvers ("system default will be
    # used"), so tailscale0 only ever claims `taildade28.ts.net` and the 100.x
    # reverse zones as routing domains; and after `down` the leftover link has
    # `Current Scopes: none`, which resolved skips — lookups still answer in
    # ~10ms. Forcing it false is what broke MagicDNS, and MagicDNS is
    # load-bearing: the remote T3 Code host's TLS cert is issued for its
    # `*.ts.net` name, so an IP cannot replace it.
    output=$(tailscale up 2>&1) ||
        { notify-send -u critical "Tailscale" "Connect failed: $output"; exit 1; }
fi

pkill -RTMIN+11 waybar || true
