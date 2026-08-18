#!/bin/bash
# What has to happen after `chezmoi apply` for the running desktop to actually
# show the config that was just written.
#
# Shared by the installer and by `dots update`, because the surfaces do not care
# which one wrote the files — and because these used to live in the installer
# only, which is the script you stop running once the machine is set up.
#
# Every function here is a no-op when its surface is absent, so a terminal-only
# or headless machine can call the whole set without guarding each one.

# Sourced here rather than left to the callers: two of the three (installer.sh,
# sync-machine.sh) do not pull services.sh in at top level — the installer sources
# it inside enable_selected_services — so a user-service helper called from
# run_post_apply would be undefined on exactly the `dots update` path it exists
# for. services.sh guards its own common.sh source with a local var, so this is
# safe to re-source.
_POST_APPLY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_POST_APPLY_DIR/services.sh"

# Hyprland autoreloads on every config write, so a running session reparses the
# tree mid-apply — conf/general.lua is rewritten before the conf/theme.lua it
# requires, and the parse fails with "module 'conf.theme' not found". The files
# on disk are fine by the time the apply ends; only the error banner lingers,
# so clear it with one reload instead of leaving it to the user.
reload_hyprland_after_apply() {
    if [ -z "$HYPRLAND_INSTANCE_SIGNATURE" ] || ! command_exists hyprctl; then
        return 0
    fi

    if hyprctl reload &> /dev/null; then
        print_success "Hyprland config reloaded"
    else
        print_warning "Could not reload Hyprland — run 'hyprctl reload' manually"
    fi
}

# Waybar, unlike Hyprland, reads config-hyprland and modules.jsonc once at
# startup — it only live-switches its *stylesheet* on a colour-scheme change.
# So a running bar keeps the modules it booted with until something restarts it,
# and a freshly applied module (a new vibewatch pill, a reworked group) silently
# does not show up until the next login or Mod+SHIFT+B.
restart_waybar_after_apply() {
    restart_user_service waybar.service \
        "Waybar restarted with the new config" \
        "Could not restart Waybar — press Mod+SHIFT+B to reload it"
}

# The themed surfaces each read one fixed path — a *copy* of the mode-specific
# file, which nothing but apply-dark-mode.sh writes and which chezmoi does not
# manage. So an apply that rewrites the managed sources reaches none of them: the
# copies they actually read keep whatever the last dark/light toggle put there,
# and the change waits, silently, for the next Mod+N. Refreshing those copies is
# the reconciliation; the reloads below are only what makes it visible.
#
# theme-copies.sh owns the list, shared with apply-dark-mode.sh so adding a
# surface to one cannot leave it stale in the other. Sourced from the deployed
# copy because that is the one apply-dark-mode.sh sees too, and chezmoi_apply has
# already put it there by the time any caller reaches this.
reconcile_theme_copies_after_apply() {
    local lib="$HOME/.local/lib/theme-copies.sh"
    [ -r "$lib" ] || return 0
    # shellcheck source=/dev/null
    . "$lib"

    # Unconditional: the copies are idempotent and cost nothing, and a copy
    # skipped is exactly the silent staleness this function exists to prevent.
    # Only the reloads are gated, because only they cost anything.
    sync_theme_copies

    # These patterns are deliberately not derived from theme-copies.sh: they gate
    # a *reload*, which is broader than the copy. kitty is the proof — it reads
    # kitty.conf once at startup too, so a font or keybind change there needs the
    # same signal as the theme copy, and `*kitty/*` catches both.
    local f swaync=false swayosd=false kitty=false
    # No file list at all — a full install, where there is no "before" — so
    # reload everything rather than guess.
    if [ $# -eq 0 ]; then
        swaync=true; swayosd=true; kitty=true
    fi
    for f in "$@"; do
        case "$f" in
            *swaync/*)  swaync=true ;;
            *swayosd/*) swayosd=true ;;
            *kitty/*)   kitty=true ;;
        esac
    done

    # Restart rather than `swaync-client -rs`: the reload re-reads the
    # stylesheet but a running daemon keeps its old font map, so a font change
    # stays tofu until the process is replaced. Gated because a restart drops
    # whatever notifications are queued.
    if $swaync; then
        restart_user_service swaync.service \
            "swaync restarted with the new stylesheet" \
            "Could not restart swaync — run 'systemctl --user restart swaync'"
    fi

    if $swayosd; then
        restart_user_service swayosd-server.service \
            "swayosd restarted with the new stylesheet" \
            "Could not restart swayosd — run 'systemctl --user restart swayosd-server'"
    fi

    # No pgrep guard: pkill already exits non-zero when nothing matched, which is
    # exactly the "kitty is not running" case.
    if $kitty && pkill -SIGUSR1 -x kitty 2>/dev/null; then
        print_success "kitty reloaded its config"
    fi
}

# The whole set, in the one order that works.
#
# Waybar goes last, after any tool refresh the caller ran: the bar's custom
# modules are long-lived `exec` children — `vibewatch status --watch` streams
# until killed — so a bar restarted before the binary underneath it moves keeps
# running the old one.
# A user service installed mid-session is enabled but not running — see
# start_user_service_if_needed in services.sh for why systemd leaves it that way.
# Nothing else in the repo closed that gap: `services:` is the system half and
# goes through sudo, and `enable_selected_services` runs in the installer, which
# is the script you stop running once the machine is set up. So the one path that
# installs packages on a live desktop, `dots update`, was the one path that could
# leave a daemon dead — and did.
#
# **Starts only what is already enabled, and never enables anything.** The
# distinction is the whole safety of running this every time: `is-enabled` cannot
# tell a unit nobody has enabled yet from one the user deliberately disabled, so
# enabling here would silently undo `systemctl --user disable` at the next
# update. Enabling belongs to the two places that have a reason to believe it is
# wanted — the installer, and a group being switched on in `dots packages`.
#
# Deliberately not gated on the changed-file list the other reconciliations use:
# the trigger is a *package* install, which leaves no trace in the files an apply
# touched. That makes it ungated on a path that runs every time, so the order of
# the guards below is the whole cost of the feature — see each one.
start_user_services_after_apply() {
    command_exists systemctl || return 0

    # The precondition that makes the entire pass a no-op, asked before any of
    # the work rather than per unit at the bottom: with no graphical session
    # nothing here can start anything. A TTY install or an SSH `dots update`
    # should discover that in milliseconds instead of scanning the tree first.
    systemctl --user is-active --quiet graphical-session.target 2>/dev/null || return 0

    # Resolved from this file, not from $DOTFILES_DIR, which is a caller
    # precondition that `dots` does not meet — it sets only SCRIPT_DIR. So
    # `dots reconfig`, which applies through apply_dotfiles, globbed
    # /packages/groups/*.yaml, matched nothing, and reconciled nothing at all,
    # silently and on the one path with no other signal that it had run.
    local groups_dir="$_POST_APPLY_DIR/../../packages/groups"

    # grep before yq, and not as tidiness: yq here is python-yq at ~170ms of
    # interpreter startup per call, there are eight group files, and exactly one
    # declares user_services — so parsing them all spent ~1.2s of every apply to
    # find a single line. That is the whole budget the catalogue-scan
    # optimisation bought back, re-spent on a more frequent path.
    # parse_requires_hardware greps for the same reason.
    local declaring=()
    mapfile -t declaring < <(grep -l '^user_services:' "$groups_dir"/*.yaml 2>/dev/null)
    [ ${#declaring[@]} -eq 0 ] && return 0

    local group_file svc
    for group_file in "${declaring[@]}"; do
        group_enabled "$group_file" || continue

        while IFS= read -r svc; do
            [ -n "$svc" ] && start_user_service_if_needed "$svc"
        done < <(parse_user_services "$group_file")
    done

    # Not decoration: the loop's exit status is whatever its last iteration left
    # behind, and a disabled group exits via `continue` after a failed
    # group_enabled — so this returns 1 on any machine whose last group file
    # alphabetically is switched off. installer.sh runs under `set -e`, which
    # would take that as a failure and abort the run between here and the waybar
    # restart, silently, looking like a clean exit.
    return 0
}

run_post_apply() {
    reload_hyprland_after_apply
    reconcile_theme_copies_after_apply "$@"
    start_user_services_after_apply
    restart_waybar_after_apply
}

# The apply itself. --force everywhere: managed files are the repo's, and a
# local edit to one is drift to be overwritten, not a change to preserve.
# Returns 0 even on failure — every caller wants to carry on and say so.
chezmoi_apply() {
    command_exists chezmoi || { print_warning "chezmoi not installed — skipping apply"; return 0; }

    if chezmoi apply --force; then
        print_success "Dotfiles applied"
    else
        print_warning "chezmoi apply reported problems"
    fi
}

# The one sanctioned way to apply. `chezmoi apply` on its own leaves the running
# desktop showing the old config, so pairing the two here is what makes "an
# apply is always reconciled" an invariant rather than a convention the next
# caller forgets — `dots reconfig` and `dots packages`, which apply precisely
# when a group flag has just rewritten the bar and the hypr tree, both forgot it.
#
# Takes the list of files the change touched, forwarded to run_post_apply; no
# list means reconcile everything. A caller that also refreshes tools must call
# chezmoi_apply and run_post_apply itself instead, with the refresh in between,
# so waybar still restarts last.
apply_dotfiles() {
    chezmoi_apply
    run_post_apply "$@"
}
