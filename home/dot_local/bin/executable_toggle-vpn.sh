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
# Failures are left to stderr and a non-zero exit, and a notification on top
# when stderr has no terminal to print to — see `finish` below.

ts_connected() { tailscale status &>/dev/null; }
nb_connected() { netbird status 2>/dev/null | grep -q '^Management: Connected'; }

ts_down() { if ts_connected; then tailscale down; fi; }
nb_down() { if nb_connected; then netbird down; fi; }

refresh_waybar() { pkill -RTMIN+11 waybar || true; }

# A switch is not instant, and `netbird up` is the worst of it: an expired token
# sends it to the browser for an SSO round trip that only ends when the user
# finishes logging in. So the vicinae picker fires this script detached and
# closes immediately — it used to hold its window up over the very browser page
# the login needed — and the bar is the only surface left to say "in progress".
#
# The marker carries the pid rather than just existing: killed with -9, this
# script runs no trap, and a bare marker would leave the shield claiming a
# switch that nobody is running any more. The reader checks the pid is alive.
BUSY="${XDG_RUNTIME_DIR:-/tmp}/vpn-switching"
# Per-pid, unlike the marker: two overlapping switches must not write each
# other's diagnostics.
BUSY_ERR="$BUSY.$$.err"

busy() {
    ACTION="$*"
    echo $$ > "$BUSY"
    # Detached, stderr has no reader at all, and the notification below would
    # otherwise name the action without the reason — which is the one thing the
    # vicinae failure Toast used to carry. Keep it; a terminal reads it itself.
    if [ ! -t 2 ]; then exec 2>"$BUSY_ERR"; fi
    trap finish EXIT
    refresh_waybar
}

finish() {
    local status=$?
    # Only when the marker is still ours. Now that the picker closes on the
    # first choice, a second switch can start while this one is still waiting on
    # a browser login; it owns the marker, and clearing it here would settle the
    # shield over a switch that is still running.
    #
    # ponytail: it only keeps the *reader* honest — the two runs still race on
    # the daemons. Serialise with a lock if that ever bites, but not flock on a
    # long-lived child: netbird's daemon would inherit the descriptor.
    if [ "$(cat "$BUSY" 2>/dev/null)" = "$$" ]; then
        rm -f "$BUSY"
    fi
    refresh_waybar
    # stderr was only redirected when there was no terminal to print it to, so
    # the file existing is also what says nobody has seen this error yet.
    if [ "$status" -ne 0 ] && [ -f "$BUSY_ERR" ]; then
        notify-send -u critical "VPN: $ACTION failed" "$(tail -2 "$BUSY_ERR")" || true
    fi
    rm -f "$BUSY_ERR"
}

# Validated before `busy`, not in the dispatch below: a bad id used to be one
# stderr line and nothing else, and through the marker it would paint the bar as
# switching and pop a critical notification for what is a usage error.
require_vpn() {
    case "${1:-}" in
        tailscale | netbird) ;;
        *) echo "Unknown VPN: ${1:-(none)}" >&2; exit 1 ;;
    esac
}

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
    require_vpn "$1"
    busy "Disconnecting $1"
    case "$1" in
        tailscale) ts_down ;;
        netbird) nb_down ;;
    esac
}

do_set() {
    require_vpn "$1"
    busy "Connecting $1"
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
    esac
}

# `off` must try both even when the first teardown fails, or a wedged tailscaled
# would leave NetBird up under a command that claims to have stopped everything.
do_off() {
    local status=0
    busy "Disconnecting"
    ts_down || status=1
    nb_down || status=1
    return "$status"
}

case "${1:-}" in
    list) do_list ;;
    set)  do_set "${2:-}" ;;
    down) do_down "${2:-}" ;;
    off)  do_off ;;
    *)    echo "Usage: $(basename "$0") {list|set <id>|down <id>|off}  (id: tailscale|netbird)" >&2; exit 1 ;;
esac
