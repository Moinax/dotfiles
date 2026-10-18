#!/bin/bash

# Waybar custom module: which VPN is up (JSON output).
#
# The state comes from toggle-vpn.sh rather than from a second pair of
# `tailscale status` / `netbird status` calls, so the bar and the vicinae picker
# read the same rows through the same parser.

# A shield makes the VPN state legible at a glance; the mark inside it says which
# tunnel, which is the one thing a glance has to answer now that there are two.
# `$'…'` rather than $(printf …): four command substitutions per run, on a module
# the bar re-runs forever, to materialise five constants.
ICON_TAILSCALE=$'\U000f0565' # shield-check
ICON_NETBIRD=$'\U000f099d'   # shield-lock
ICON_OFF=$'\U000f099e'       # shield-off
ICON_ALERT=$'\U000f0ecc'     # shield-alert
ICON_SWITCHING=$'\U000f11a2' # shield-sync

emit() { printf '{"text": "%s", "class": "%s", "tooltip": "%s"}\n' "$1" "$2" "$3"; }

# A switch in flight, reported before any daemon is asked: the picker closes the
# moment a row is chosen, so this pill is the only progress indicator there is,
# and `netbird up` can sit on a browser login for as long as the login takes.
# The pid in the marker is what tells a running switch from one that was killed.
# `2>/dev/null` first: redirections are applied left to right, so with the input
# one leading, a missing marker prints its own error before stderr is silenced.
# The rest is the shape toggle-caffeine.sh's `find_inhibitors` already uses —
# numeric guard, liveness, then the cmdline — because a pid alone answers the
# wrong question: a switch killed outright runs no trap, and the pid it left
# behind belongs to whatever got it next.
if read -r switching_pid 2>/dev/null < "${XDG_RUNTIME_DIR:-/tmp}/vpn-switching" &&
    [[ "$switching_pid" =~ ^[0-9]+$ ]] &&
    kill -0 "$switching_pid" 2>/dev/null &&
    [[ "$(tr '\0' ' ' < "/proc/$switching_pid/cmdline" 2>/dev/null)" == *toggle-vpn.sh* ]]; then
    emit "$ICON_SWITCHING" switching "Switching VPN…"
    exit 0
fi

# Never `2>/dev/null` this: a reader that fails — toggle-vpn.sh not yet applied
# after the rename, a daemon socket gone — would otherwise yield zero rows, and
# the bar would assert "no VPN connected" about a tunnel it never managed to ask
# about. `unknown` shares the alert pill; a lie in the other direction is worse.
if ! rows=$("$HOME/.local/bin/toggle-vpn.sh" list 2>&1); then
    emit "$ICON_ALERT" unknown "VPN state unreadable: ${rows//\"/}"
    exit 0
fi

ids=()
labels=()
tooltips=()
while IFS=$'\t' read -r id connected label detail; do
    [ "$connected" = 1 ] || continue
    ids+=("$id")
    labels+=("$label")
    tooltips+=("$label: ${detail:-connected}")
done <<<"$rows"

case ${#ids[@]} in
    0) emit "$ICON_OFF" disconnected "No VPN connected" ;;
    1)
        case "${ids[0]}" in
            tailscale) emit "$ICON_TAILSCALE" tailscale "${tooltips[0]}" ;;
            netbird) emit "$ICON_NETBIRD" netbird "${tooltips[0]}" ;;
            *) emit "$ICON_OFF" disconnected "${tooltips[0]}" ;;
        esac
        ;;
    *)
        # Both tunnels up is the broken state toggle-vpn.sh exists to prevent —
        # reachable again the moment a bare `tailscale up` or `netbird up` is run
        # by hand. Reporting whichever row came last would hide it behind a
        # perfectly normal-looking shield, so it gets its own glyph.
        emit "$ICON_ALERT" conflict "${labels[*]} both up — routes overlap, disconnect one"
        ;;
esac
