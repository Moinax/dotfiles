#!/bin/bash
# hyprlock's own PAM auth stack, with neither pam_faillock nor pam_fprintd.
#
# The package ships /etc/pam.d/hyprlock as `auth include login`, which pulls in
# system-auth and its pam_faillock. A screen locker is a local-presence unlock,
# so the tally buys nothing there and self-DoSes instead: three mistyped
# passwords (Caps Lock left on, 2026-11-23) — or, with a fingerprint reader,
# three *successful* fingerprint unlocks, see below — inside fail_interval lock
# the account for unlock_time, taking sudo, TTY login and this screen's own
# password fallback down with it. faillock stays in the greeter and login stacks.
#
#   pam_fprintd — a typed password would wait out the fingerprint timeout
#   (~10s) before pam_unix ever sees it. Fingerprint at the lockscreen is
#   handled by hyprlock natively over D-Bus (auth.fingerprint in
#   hyprlock.conf), independently of this stack.
#
#   pam_faillock and fingerprints — hyprlock races the PAM password
#   conversation against that D-Bus fingerprint check and aborts the
#   conversation when the fingerprint wins. pam_unix then returns
#   "conversation failed", which faillock's authfail branch records as a
#   failed login — so every SUCCESSFUL fingerprint unlock increments the tally.
#
# Deriving this from system-auth with a sed was the obvious alternative and is a
# trap: deleting the three pam_faillock lines shifts the [success=N] jump counts
# on pam_systemd_home and pam_unix, and a miscounted jump in an auth stack fails
# open. Hand-authored and auditable beats generated here. Only `account`
# includes system-auth, which pambase always ships — so that include cannot
# dangle.
#
# Shared by `dots setup` and `dots update` (reconcile_hyprlock_pam) — this used
# to live in setup_biometric only, so a machine without the biometric group, or
# set up before it, kept the stock stack.
#
# pacman lists the file in hyprlock's backup array, so an upgrade leaves our
# copy alone and drops a .pacnew beside it.
#
# Requires common.sh (print helpers, track_warning) to be sourced.

HYPRLOCK_PAM_FILE=/etc/pam.d/hyprlock

# One body for the writer and the drift check, so they cannot disagree.
hyprlock_pam_body() {
    cat <<'EOF'
#%PAM-1.0
# Installed by the dotfiles installer — hyprlock's own auth stack.
# Deliberately not an include of login/system-auth/password-auth: it must carry
# neither pam_fprintd (a typed password would wait out the fingerprint timeout)
# nor pam_faillock (a few typos at the lock screen lock the whole account, and
# every successful fingerprint unlock counts as a failure). See
# install/lib/hyprlock-pam.sh for the full reasoning.

-auth      [success=1 default=ignore]  pam_systemd_home.so
auth       required                    pam_unix.so          try_first_pass nullok
auth       required                    pam_env.so

account    include                     system-auth
EOF
}

# hyprlock ships the file, so its absence means there is no hyprlock to fix.
hyprlock_pam_needs_setup() {
    [ -f "$HYPRLOCK_PAM_FILE" ] || return 1
    ! cmp -s <(hyprlock_pam_body) "$HYPRLOCK_PAM_FILE"
}

apply_hyprlock_pam() {
    if [ ! -f "$HYPRLOCK_PAM_FILE" ]; then
        print_info "hyprlock is not installed — leaving its PAM stack alone"
        return 0
    fi
    if ! hyprlock_pam_needs_setup; then
        print_info "hyprlock's PAM stack is already in place"
        return 0
    fi

    # Any drift gets a copy, header or not: a hand edit may keep our header.
    local backup
    backup="${HYPRLOCK_PAM_FILE}.bak.$(date +%s)"
    sudo cp "$HYPRLOCK_PAM_FILE" "$backup" || {
        track_warning "Could not back up $HYPRLOCK_PAM_FILE — leaving it as is"
        return 1
    }
    print_info "Backed up $HYPRLOCK_PAM_FILE to $backup"

    hyprlock_pam_body | sudo install -m 644 /dev/stdin "$HYPRLOCK_PAM_FILE" || {
        track_warning "Could not write $HYPRLOCK_PAM_FILE — hyprlock still goes through faillock"
        return 1
    }
    # PAM reads the file per transaction; a running hyprlock picks it up on its
    # next attempt, nothing to restart.
    print_success "hyprlock no longer counts toward faillock"
}
