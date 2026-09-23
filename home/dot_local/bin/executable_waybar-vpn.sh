#!/bin/bash

# Waybar custom module: which VPN is up (JSON output).
#
# The state comes from toggle-vpn.sh rather than from a second pair of
# `tailscale status` / `netbird status` calls, so the bar and the vicinae picker
# read the same rows through the same parser.

# A shield makes the VPN state legible at a glance; the mark inside it says which
# tunnel, which is the one thing a glance has to answer now that there are two.
# `$'…'` rather than $(printf …): four command substitutions per run, on a module
# the bar re-runs forever, to materialise four constants.
ICON_TAILSCALE=$'\U000f0565' # shield-check
ICON_NETBIRD=$'\U000f099d'   # shield-lock
ICON_OFF=$'\U000f099e'       # shield-off
ICON_ALERT=$'\U000f0ecc'     # shield-alert

emit() { printf '{"text": "%s", "class": "%s", "tooltip": "%s"}\n' "$1" "$2" "$3"; }

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
