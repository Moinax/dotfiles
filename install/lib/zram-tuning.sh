#!/bin/bash
# One sysctl, written where it survives: the long version of why is in
# .claude/rules/zram-tuning.md. The short version: CachyOS sets
# `vm.swappiness=150` from a udev rule, which prefers compressing live anonymous
# pages over dropping re-readable page cache. On a host whose anonymous pages
# stay hot — JVM and pytest heaps under a parallel build — that is a
# decompression treadmill that stalls the compositor, measured at 3.2M anon
# refaults and 14,040 direct-reclaim stalls for an apparent load of 25 at 83%
# idle.
#
# The one privileged step is writing that override, so it lives here, shared by
# `dots setup` (which runs it once) and `dots update` (which offers it to a
# machine that is missing it). It cannot live in a chezmoi apply — that would put
# a sudo prompt in every one.
#
# Two traps, both already paid for, both in the rule doc: a drop-in in
# /etc/sysctl.d/ loses a boot race to the udev rule and reads as though it
# worked, and a same-named file in /etc/udev/rules.d replaces the vendor rule
# wholesale rather than adding to it. This file does neither.
#
# Requires common.sh (print helpers, track_warning) to be sourced.

# Deliberately 90- and not 30-: udev(7) sorts rules files across all directories
# and applies every match in order, so a higher number runs *after*
# /usr/lib/udev/rules.d/30-zram.rules and its assignment wins. Naming it
# 30-zram.rules would instead *replace* the vendor file (identical filenames
# replace each other, /etc wins), freezing a hand-copy of it that no package
# upgrade could ever correct and that pacman would never report, since pacman
# does not own anything under /etc/udev/rules.d.
ZRAM_TUNING_UDEV_RULE=/etc/udev/rules.d/90-zram-swappiness.rules

# The one knob, named because it is the only reason to come back to this file.
#
# 60 is the mainline kernel default: still swaps under genuine pressure, but no
# longer *prefers* anonymous pages over file cache. Deliberately not 0 — zram is
# the only swap on this machine and systemd-oomd is inactive, so refusing to swap
# at all trades a slow freeze for a kernel OOM kill.
#
# Capping the device's *size* was tried here and reverted: it addresses nothing
# the refault storm is made of, and this host's steady state is 19 GiB of data in
# zram, so every cap small enough to matter is already below live demand.
ZRAM_TUNING_SWAPPINESS=60

# The file body lives in a function so the writer and the drift check below read
# the same bytes — dns-encrypted.sh does this for the same reason: a detection
# that can disagree with the write is a step that reports success while changing
# nothing.
zram_tuning_udev_body() {
    cat <<EOF
# Written by install/lib/zram-tuning.sh — edits here are replaced on the next
# \`dots setup\` or \`dots update\`, which is also where the reasoning lives.
#
# Runs after /usr/lib/udev/rules.d/30-zram.rules and overrides the swappiness it
# sets, while leaving the rest of that rule — the zswap disable — in force and
# free to change with its package. CachyOS's 150 prefers compressing live
# anonymous pages over dropping re-readable page cache; on a host whose anonymous
# pages stay hot that stalls the compositor.
ACTION=="change", KERNEL=="zram0", ATTR{initstate}=="1", SYSCTL{vm.swappiness}="$ZRAM_TUNING_SWAPPINESS"
EOF
}

# Whether there is a zram swap device to tune at all. A box without one is not
# silently mistuned — the rule keys on zram0, so it would match nothing — and is
# skipped rather than warned about.
zram_tuning_supported() {
    [ -e /dev/zram0 ]
}

# True when the override is missing or has drifted from what we would write.
# Content comparison and not mere existence, so retuning the knob above reaches a
# machine that already carries the previous value.
zram_tuning_needs_setup() {
    zram_tuning_supported || return 1
    ! cmp -s <(zram_tuning_udev_body) "$ZRAM_TUNING_UDEV_RULE"
}

# The privileged step, headerless so both callers can frame it their own way.
# Idempotent: one file write, one rule reload, one triggered event.
apply_zram_tuning() {
    if ! zram_tuning_supported; then
        print_info "No zram swap here — leaving reclaim tuning alone"
        return 0
    fi

    # `install -D` and not `tee`: content, mode and any missing parent directory
    # in one privileged call.
    zram_tuning_udev_body | sudo install -D -m 644 /dev/stdin "$ZRAM_TUNING_UDEV_RULE" || {
        track_warning "Could not write $ZRAM_TUNING_UDEV_RULE — swappiness stays at CachyOS's 150"
        return 1
    }

    # The rule only fires on a zram0 `change` event, so on the machine we are
    # standing on swappiness would keep the distro's value until the next boot.
    # Re-triggering the event runs the rule we just wrote rather than repeating
    # its assignment here — the same choice dns-encrypted.sh makes when it runs
    # its dispatcher over already-connected links, and for the same reason: a
    # value applied in two places drifts in one of them.
    #
    # `control --reload` first, and it is not belt-and-braces: udevd picks up a
    # new rules file through inotify, asynchronously, so a trigger issued
    # microseconds after the write can be matched against the *old* ruleset — and
    # the old ruleset is the one that sets 150. Without the reload this step can
    # re-assert the value it exists to replace.
    #
    # `trigger --settle` and not a separate `udevadm settle`: the latter waits on
    # the entire udev queue, and `dots update` installs packages before it reaches
    # here, so that queue is routinely non-empty — up to a 5s stall for one
    # sysctl. --settle waits only on the events this call triggered.
    if sudo udevadm control --reload &&
        sudo udevadm trigger --settle --action=change --subsystem-match=block --sysname-match=zram0; then
        local live
        live=$(sysctl -n vm.swappiness 2>/dev/null)
        if [ "${live:-}" = "$ZRAM_TUNING_SWAPPINESS" ]; then
            print_success "Reclaim prefers dropping page cache over compressing live memory (vm.swappiness=$live)"
        else
            # Not a warning: the file is in place and the next boot reads it.
            # Worth saying out loud, because the alternative is believing the
            # freeze is fixed on a machine still running the old value.
            print_info "Wrote the tuning; vm.swappiness is still ${live:-unreadable} and lands at the next boot"
        fi
    else
        # A host where udev is not the running device manager — a container, a
        # chroot — reaches this. Saying so beats the reassuring message above,
        # which would promise a next boot that never applies it either.
        track_warning "udevadm would not reload or trigger — $ZRAM_TUNING_UDEV_RULE is written but unapplied"
    fi
    return 0
}
