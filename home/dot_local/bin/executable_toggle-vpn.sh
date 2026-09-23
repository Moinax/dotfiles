#!/bin/bash
set -e

# Tailscale and NetBird, one at a time: the state reader and the switch, shared
# by the waybar module and the vicinae picker so the bar and the menu cannot
# disagree about what is up.
#
# Exclusivity is not a preference. The O27 NetBird account allocates
# 100.81.0.0/16, inside the same CGNAT block Tailscale hands its addresses out
# of, and NetBird's policy rule (priority 105) sits ahead of Tailscale's (5270).
# With both up, every Tailscale peer inside that /16 — t3code-host at
# 100.81.18.120 — routes into wt0 and blackholes, while the peers outside it keep
# answering. So the symptom is "that one host is down", not "my two VPNs are
# fighting", which is exactly the kind of failure worth making impossible rather
# than documenting.
#
#   list       one row per VPN: id<TAB>connected<TAB>label<TAB>detail
#   set <id>   connect <id>, disconnecting the other first
#   down <id>  disconnect <id>, leaving the other alone
#   off        disconnect both
#
# Failures are left to stderr and a non-zero exit: both callers can report one
# (vicinae as a Toast, a shell as itself), unlike the rofi menus this replaces.

ts_connected() { tailscale status &>/dev/null; }
nb_connected() { netbird status 2>/dev/null | grep -q '^Management: Connected'; }

ts_down() { if ts_connected; then tailscale down; fi; }
nb_down() { if nb_connected; then netbird down; fi; }

refresh_waybar() { pkill -RTMIN+11 waybar || true; }

do_list() {
    local detail=""
    if ts_connected; then
        detail=$(tailscale status 2>/dev/null | awk 'NR == 1 { print $2 " — " $1; exit }')
        printf 'tailscale\t1\tTailscale\t%s\n' "$detail"
    else
        printf 'tailscale\t0\tTailscale\t\n'
    fi

    detail=""
    if nb_connected; then
        # The IP comes with its prefix length, which is noise in a tooltip.
        detail=$(netbird status 2>/dev/null | awk -F': +' '
            /^FQDN:/ { fqdn = $2 }
            /^NetBird IP:/ { split($2, a, "/"); ip = a[1] }
            END { if (fqdn) print fqdn " — " ip }
        ')
        printf 'netbird\t1\tNetBird (O27)\t%s\n' "$detail"
    else
        printf 'netbird\t0\tNetBird (O27)\t\n'
    fi
}

do_down() {
    case "$1" in
        tailscale) ts_down ;;
        netbird) nb_down ;;
        *) echo "Unknown VPN: ${1:-(none)}" >&2; exit 1 ;;
    esac
    refresh_waybar
}

do_set() {
    case "$1" in
        tailscale)
            nb_down
            # No --accept-dns: a bare `up` keeps the stored pref, so this switch
            # asserts no DNS policy at all and a `tailscale set` made by hand
            # survives. MagicDNS is load-bearing — the remote T3 Code host's TLS
            # certificate is issued for its `*.ts.net` name — and `dots setup`
            # owns that decision once.
            tailscale up
            ;;
        netbird)
            ts_down
            # --disable-auto-connect is what keeps Tailscale the default at boot.
            # netbird@main is enabled so the CLI always has a daemon to talk to,
            # and a logged-in daemon otherwise dials the tunnel itself on start —
            # taking the 100.81/16 routes off Tailscale before the session is even
            # up. The flag is re-asserted on every connect because the daemon
            # rewrites it from each `up` message, so a bare `netbird up` run by
            # hand silently turns auto-connect back on.
            #
            # ponytail: it also drops NetBird's reconnect backoff to a single
            # shot, so a tunnel that dies stays down until you switch again.
            # Worth it against a VPN that steals routes at every boot; drop the
            # flag and mask the unit instead if the reconnects are missed.
            netbird up --disable-auto-connect
            ;;
        *)
            echo "Unknown VPN: ${1:-(none)}" >&2
            exit 1
            ;;
    esac
    refresh_waybar
}

# `off` must try both even when the first teardown fails, or a wedged tailscaled
# would leave NetBird up under a command that claims to have stopped everything.
do_off() {
    local status=0
    ts_down || status=1
    nb_down || status=1
    refresh_waybar
    return "$status"
}

case "${1:-}" in
    list) do_list ;;
    set)  do_set "${2:-}" ;;
    down) do_down "${2:-}" ;;
    off)  do_off ;;
    *)    echo "Usage: $(basename "$0") {list|set <id>|down <id>|off}  (id: tailscale|netbird)" >&2; exit 1 ;;
esac
