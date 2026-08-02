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

# herdr servers read config.toml at boot and persist their layout in
# session.json, so neither follows an apply on its own: every running session
# but the current one keeps the old config, and an old layout silently comes
# back at the next server restart.
#
# Called with the list of files an update changed, only the reconciliations that
# file list justifies run. Called with nothing — a full install, where there is
# no "before" to diff against — both run: they are idempotent, and cheap next to
# guessing wrong.
reload_herdr_after_apply() {
    command_exists herdr-clients || return 0
    # No server, nothing to reconcile. `list` prints one row per session; a
    # machine that has never opened one prints nothing.
    [ -n "$(herdr-clients list 2>/dev/null)" ] || return 0

    local want_layout=false want_config=false f
    # No file list at all — a full install, where there is no "before" — so run
    # both rather than guess.
    [ $# -eq 0 ] && { want_layout=true; want_config=true; }

    for f in "$@"; do
        case "$f" in
            # Any herdr script, not a list of the three that happen to build
            # panes today: a missed migrate-layout does not fail, it brings the
            # old layout back at the next server restart, hours later, with
            # nothing tying it to the update that caused it. Over-triggering
            # costs one idempotent call — the full-install path above makes it
            # unconditionally — so the honest default is to match broadly.
            */executable_herdr-*|*/executable_dev-herdr)
                want_layout=true ;;
            *herdr/config.toml*)
                want_config=true ;;
        esac
    done

    # Config before layout: migrate-layout drives running servers through the
    # client, so it should be talking to servers that already agree with the
    # config on disk.
    if $want_config; then
        herdr-clients reload-config || print_warning "herdr reload-config failed"
    fi
    if $want_layout; then
        herdr-clients migrate-layout || print_warning "herdr migrate-layout failed"
    fi
}

# Waybar, unlike Hyprland, reads config-hyprland and modules.jsonc once at
# startup — it only live-switches its *stylesheet* on a colour-scheme change.
# So a running bar keeps the modules it booted with until something restarts it,
# and a freshly applied module (a new vibewatch pill, a reworked group) silently
# does not show up until the next login or Mod+SHIFT+B.
restart_waybar_after_apply() {
    systemctl --user is-active --quiet waybar.service 2>/dev/null || return 0

    if systemctl --user restart waybar.service 2>/dev/null; then
        print_success "Waybar restarted with the new config"
    else
        print_warning "Could not restart Waybar — press Mod+SHIFT+B to reload it"
    fi
}

# The whole set, in the one order that works.
#
# Waybar goes last, after any tool refresh the caller ran: the bar's custom
# modules are long-lived `exec` children — `vibewatch status --watch` streams
# until killed — so a bar restarted before the binary underneath it moves keeps
# running the old one.
run_post_apply() {
    reload_hyprland_after_apply
    reload_herdr_after_apply "$@"
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
