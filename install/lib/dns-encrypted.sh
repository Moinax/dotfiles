#!/bin/bash
# Encrypted DNS, and the one flag that makes it reachable at all.
#
# systemd-resolved does not keep *a* list of name servers, it keeps one per link
# and picks the link from the name being asked for. A link is eligible for the
# names that match none of the other links' domains only when its "default route"
# flag is set — and NetworkManager sets that flag on whichever link carries the
# default gateway. So the DHCP resolver of whatever network you plugged into wins
# every lookup, and a global `DNS=` in resolved.conf is never consulted: it is
# only read when *no* link has a server at all.
#
# That is not a theoretical loss of control. Measured on the Proximus line this
# was written for, the ISP resolver answers `libgen.is` and `sci-hub.se` with the
# same address — one of its own mail hosts — and hands `thepiratebay.org` a Belnet
# notice page. Court-ordered and entirely legal, but it means the answers are not
# DNS answers. The same resolver was also 4x slower than Cloudflare at the median
# and 2x at the p90, so nothing is being traded away for the integrity.
#
# Two files, and deliberately not one more:
#
#   - a resolved drop-in naming two operators (not two Cloudflare addresses —
#     1.1.1.1 and 1.0.0.1 are one anycast network and fall over together, as they
#     did in July 2024) with DNSOverTLS.
#   - an NM dispatcher script that clears the default-route flag on each link as
#     it comes up. It names no interface, no connection and no domain, so it is
#     the same script on this desktop, on a laptop in a hotel, and on a machine
#     that does not exist yet.
#
# What the dispatcher deliberately does NOT do is strip the link's servers or its
# search domain. The link keeps both, so `Samsung` and `moinax-laptop.home` still
# resolve through the box — it has simply stopped being asked about github.com.
# `ipv4.ignore-auto-dns` would have been the blunt version of this and costs the
# local names on every network.
#
# opportunistic rather than strict TLS is a choice about captive portals: a hotel
# or airport network authenticates you by hijacking DNS, so strict mode means the
# login page never appears and the machine cannot get online at all. Opportunistic
# falls back to cleartext exactly there and negotiates TLS everywhere else —
# verified with an established connection to 1.1.1.1:853, not merely configured.
#
# Requires common.sh (print helpers, track_warning, command_exists) to be sourced.

ENCRYPTED_DNS_RESOLVED_CONF=/etc/systemd/resolved.conf.d/dot.conf
ENCRYPTED_DNS_DISPATCHER=/etc/NetworkManager/dispatcher.d/50-dns-no-default-route

# The two file bodies live in functions rather than in heredocs at the call site
# so the writer and the drift check below read the same bytes. login-wallpaper.sh
# shares its greeter group path between its reader and its writer for the same
# reason: a detection that can disagree with the write is a step that reports
# success while changing nothing.
encrypted_dns_resolved_body() {
    cat <<'EOF'
# Written by install/lib/dns-encrypted.sh — edits here are replaced on the next
# `dots setup` or `dots update`, which is also where the reasoning lives.
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net
FallbackDNS=1.0.0.1#cloudflare-dns.com 149.112.112.112#dns.quad9.net
DNSOverTLS=opportunistic
EOF
}

encrypted_dns_dispatcher_body() {
    cat <<'EOF'
#!/bin/sh
# Written by install/lib/dns-encrypted.sh — edits here are replaced on the next
# `dots setup` or `dots update`, which is also where the reasoning lives.
#
# The link keeps its DHCP servers and its search domain, so local names still
# resolve through the router; it just stops being the default route.
[ "$2" = "up" ] || exit 0

# A link that routes `~.` is claiming every name on purpose — that is what
# tailscaled sets when an exit node or a tailnet-wide resolver is meant to handle
# all DNS. Clearing its default route there would break the very thing the user
# switched on, and this script cannot tell that apart from a DHCP router except
# by asking. Matched as a whole token: the reverse zones tailscale also installs
# read `~0.e.1.a...`, which is not `~.`.
if /usr/bin/resolvectl domain "$1" 2>/dev/null | grep -qE '(^| )~\.( |$)'; then
    exit 0
fi

/usr/bin/resolvectl default-route "$1" no 2>/dev/null
exit 0
EOF
}

# Whether this machine has the two pieces the setup drives. A server install with
# neither is not a machine that silently keeps the ISP resolver — it is a machine
# where none of this applies, so it is skipped rather than warned about.
encrypted_dns_supported() {
    command_exists resolvectl && command_exists nmcli
}

# True when either file is missing or has drifted from what we would write.
# Content comparison rather than a mere existence check, so changing a resolver
# here reaches machines that already have the old one — the same property that
# makes reconcile_login_wallpaper re-offer itself off machine state.
encrypted_dns_needs_setup() {
    encrypted_dns_supported || return 1
    ! cmp -s <(encrypted_dns_resolved_body) "$ENCRYPTED_DNS_RESOLVED_CONF" ||
        ! cmp -s <(encrypted_dns_dispatcher_body) "$ENCRYPTED_DNS_DISPATCHER"
}

# The privileged steps, headerless so both callers frame them their own way.
# Idempotent: re-running rewrites two files and reloads one daemon.
apply_encrypted_dns() {
    if ! encrypted_dns_supported; then
        print_info "No systemd-resolved or NetworkManager here — leaving DNS alone"
        return 0
    fi

    # `install -D` and not `tee`: it lands the content, the mode and the missing
    # parent directory as one privileged call. The parent matters — no package
    # owns /etc/systemd/resolved.conf.d (systemd ships the file, never the drop-in
    # directory), so on a machine that has never had one a plain write goes into
    # nothing and the feature lands as a warning nobody reads. Ownership needs no
    # flag: run under sudo, install creates the file root-owned already.
    encrypted_dns_resolved_body | sudo install -D -m 644 /dev/stdin "$ENCRYPTED_DNS_RESOLVED_CONF" || {
        track_warning "Could not write $ENCRYPTED_DNS_RESOLVED_CONF — DNS stays with the network's resolver"
        return 1
    }

    # The mode is not cosmetic: NetworkManager ignores a dispatcher script that is
    # not executable, and does so silently. Setting it in the same call as the
    # content is what stops that from being a second step with its own failure —
    # and its own window where the file exists and does nothing.
    encrypted_dns_dispatcher_body | sudo install -D -m 755 /dev/stdin "$ENCRYPTED_DNS_DISPATCHER" || {
        track_warning "Could not install $ENCRYPTED_DNS_DISPATCHER — encrypted DNS is configured but unreachable"
        return 1
    }

    # reload, not restart: the unit is Type=notify-reload and SIGHUP makes resolved
    # re-read its configuration files, drop-ins included (systemd 256+). Verified
    # rather than assumed — a server added to the drop-in appears, and disappears,
    # on a bare reload. A restart would tear the resolver down and have NM re-push
    # every link's DNS on the way back up, for no gain.
    sudo systemctl reload systemd-resolved || {
        track_warning "systemd-resolved would not reload — encrypted DNS lands at the next boot"
        return 1
    }

    # The dispatcher only fires when a link comes *up*, so on the machine we are
    # standing on every already-connected link would keep its default route until
    # the next reconnect or reboot. Running the script itself over them, rather
    # than repeating its one line here, is what keeps the `~.` guard from existing
    # in two places and drifting.
    local dev
    while read -r dev; do
        [ -n "$dev" ] || continue
        sudo "$ENCRYPTED_DNS_DISPATCHER" "$dev" up || true
    done < <(nmcli -t -g DEVICE connection show --active 2>/dev/null)

    print_success "DNS goes to Cloudflare and Quad9 over TLS; local names still resolve through the network"
    return 0
}
