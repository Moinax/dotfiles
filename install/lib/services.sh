#!/bin/bash
# Service management functions

# Source common functions (use local var to avoid overwriting parent's SCRIPT_DIR)
_SERVICES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SERVICES_DIR/common.sh"

# ── systemd instances ────────────────────────────────────────────────────────
#
# Everything below talks to one of two instances, named `system` or `user`, and
# these two wrappers are the only place that difference is spelled out. The split
# between them is not cosmetic:
#
#   - Queries never need root. `is-enabled` and `is-active` answer perfectly well
#     as the caller, so putting sudo on them would buy a password prompt for a
#     read.
#   - The user instance must never see sudo at all. `sudo systemctl --user` talks
#     to *root's* user instance, not the caller's — it does not fail, it silently
#     acts on the wrong session, which is the worst possible failure here.
_systemctl_query() {
    local scope="$1"; shift
    if [ "$scope" = user ]; then systemctl --user "$@"; else systemctl "$@"; fi
}

_systemctl_admin() {
    local scope="$1"; shift
    if [ "$scope" = user ]; then systemctl --user "$@"; else sudo systemctl "$@"; fi
}

# Enable and start a systemd service
enable_service() {
    local service="$1"

    if _systemctl_query system is-enabled "$service" &>/dev/null; then
        print_info "Service $service is already enabled"
    else
        print_info "Enabling service: $service"
        if _systemctl_admin system enable --now "$service"; then
            print_success "Service $service enabled and started"
        else
            print_warning "Failed to enable service $service"
        fi
    fi
}

# Apply a verb to a list of services, ignoring duplicates and blanks — several
# groups declare the same unit, so every caller had to dedupe by hand.
#
# Verb-generic rather than enable-only: the four system/user × enable/disable
# combinations differ in nothing but which function they dispatch to, and the
# dedupe is the part that would drift if written four times. (Named
# `enable_each_service` while enable was its only caller, which read wrong the
# moment `disable_service` went through it.) Replaces the older
# `enable_services`, which iterated without deduping and had no callers left:
# installer.sh had inlined its own copy instead.
for_each_service() {
    local verb="$1"; shift
    [ $# -eq 0 ] && return 0

    local unique=() service
    mapfile -t unique < <(printf '%s\n' "$@" | sort -u | grep -v '^$')
    for service in "${unique[@]}"; do
        "$verb" "$service"
    done
}

# Read service names on stdin, emit those whose enabled-state matches $2
# (`yes`/`no`), asked of the instance named by $1 (`system`/`user`). Blank lines
# are dropped, so a caller can feed it an empty list without guarding.
#
# One helper because both callers ask this question twice each, once per
# instance: four hand-written copies of the same read-filter-append loop is what
# adding the user half would otherwise have cost, and the filter is exactly the
# part that would drift between them.
services_with_state() {
    local scope="$1" want="$2" svc state

    while IFS= read -r svc; do
        [ -n "$svc" ] || continue
        state=no
        _systemctl_query "$scope" is-enabled "$svc" &>/dev/null && state=yes
        [ "$state" = "$want" ] && printf '%s\n' "$svc"
    done
    return 0
}

# Start an enabled user unit that is not running. Kept apart from the enable
# because the two are genuinely different questions, and conflating them is the
# bug this file exists to prevent: a user unit is almost always
# `WantedBy=graphical-session.target`, and systemd pulls in `Wants` only when the
# target *activates*. So enabling one under a session that is already up does
# nothing at all — the unit reads `enabled`, and the daemon stays dead until the
# next login.
#
# That is exactly how vicinae shipped. `dots update` installed it mid-session,
# its own systemd preset enabled it a minute after graphical-session.target had
# already been reached, and the server never ran once — an empty journal, and
# every Hyprland keybind firing a `vicinae://` deeplink at nothing.
#
# Gated on the graphical session because of that same `PartOf=`: with no session
# there is nothing to fix. Starting one from a TTY install, or over SSH, gives a
# daemon no compositor to draw on — and the enable has already done the real
# work, since the unit then starts with the session at next login.
start_user_service_if_needed() {
    local service="$1"

    systemctl --user is-active --quiet "$service" 2>/dev/null && return 0
    systemctl --user is-active --quiet graphical-session.target 2>/dev/null || return 0

    if systemctl --user start "$service" &>/dev/null; then
        print_success "Service $service started"
    else
        print_warning "Could not start $service — run 'systemctl --user start $service'"
    fi
}

# The per-user counterpart of enable_service. Deliberately *not* folded into one
# body with it, unlike the disable pair below: the system version can use
# `enable --now` because multi-user.target is active long before any install
# runs, whereas the user version has to enable and start as two steps for the
# reason above. Sharing a body would mean either giving up `--now` on the system
# side or teaching the user side a `--now` that does not do what it says.
enable_user_service() {
    local service="$1"

    if _systemctl_query user is-enabled "$service" &>/dev/null; then
        print_info "Service $service is already enabled"
    elif _systemctl_admin user enable "$service" &>/dev/null; then
        print_success "Service $service enabled"
    else
        print_warning "Failed to enable user service $service"
        return 0
    fi

    start_user_service_if_needed "$service"
}

# Restart a user service, but only if it is already running — a surface that is
# not up has nothing to reconcile — and say which way it went either way.
# `is-active` first rather than `try-restart`: the latter exits 0 whether it
# restarted the unit or found nothing, so it cannot tell the two apart.
#
# Lives here beside start_user_service_if_needed, its mirror image (that one
# returns early when the unit *is* active, this one when it is not). They were in
# separate files, which left post-apply.sh — a file about which surfaces need
# reconciling — holding a raw systemd primitive.
restart_user_service() {
    local unit="$1" ok="$2" hint="$3"
    systemctl --user is-active --quiet "$unit" 2>/dev/null || return 0

    if systemctl --user restart "$unit" 2>/dev/null; then
        print_success "$ok"
    else
        print_warning "$hint"
    fi
}

# Disable a service in the given instance. One body for both, unlike the enable
# pair above: disabling is genuinely the same operation in each, and the two
# copies this replaces had drifted only in whether they reported a failure at all.
#
# `--now` is unambiguous here in a way it is not for the enable — a unit the user
# has just asked to disable should not still be running — so there is no
# start-vs-enable question to keep apart.
disable_service_in() {
    local scope="$1" service="$2"

    if _systemctl_query "$scope" is-enabled "$service" &>/dev/null; then
        print_info "Disabling service: $service"
        _systemctl_admin "$scope" disable --now "$service" &>/dev/null \
            || print_warning "Failed to disable service $service"
    else
        print_info "Service $service is already disabled"
    fi
}

disable_service()      { disable_service_in system "$1"; }
disable_user_service() { disable_service_in user   "$1"; }

# Check service status
check_service() {
    local service="$1"
    
    if systemctl is-active "$service" &>/dev/null; then
        print_success "Service $service is running"
        return 0
    else
        print_warning "Service $service is not running"
        return 1
    fi
}

# Add user to a group (e.g., docker)
add_user_to_group() {
    local group="$1"
    local user="${2:-$USER}"
    
    if groups "$user" | grep -q "\b$group\b"; then
        print_info "User $user is already in group $group"
    else
        print_info "Adding user $user to group $group"
        sudo usermod -aG "$group" "$user"
        print_success "User added to $group group (logout/login required)"
    fi
}
