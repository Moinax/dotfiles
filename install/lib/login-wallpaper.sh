#!/bin/bash
# The lock screen and the login greeter share one file, /var/lib/wallpaper/current
# — the long version of why is in CLAUDE.md. The short version: the greeter runs
# as the `plasmalogin` system user and $HOME is 0700, so the picked wallpaper has
# to be copied somewhere outside $HOME that a plain user can still write.
#
# Two steps in that story need root, and they are the only two: creating that
# directory user-owned, and pointing the greeter config at it. Neither can live in
# a chezmoi apply — that would put a sudo prompt in every one — so they live here,
# shared by `dots setup` (which runs them once) and `dots update` (which offers
# them to a machine that is missing them). Nothing else is privileged: with the
# directory in place the picker republishes on every pick with no root at all.
#
# Requires common.sh (print helpers, track_warning, command_exists) to be sourced.

# Two other places name this same path and cannot source this file: the picker
# (home/dot_local/bin/executable_wallpaper-picker.sh, PUBLISHED_DIR — a standalone
# script chezmoi installs to ~/.local/bin, where the repo may not be) and
# hyprlock.conf.tmpl, whose reader is not a shell at all. Changing the path means
# changing all three.
LOGIN_WALLPAPER_DIR=/var/lib/wallpaper
LOGIN_WALLPAPER_FILE="$LOGIN_WALLPAPER_DIR/current"
PLASMALOGIN_CONF=/etc/plasmalogin.conf

# What the greeter config should name. A `file://` URL and not a bare path,
# because that is what KDE's own Login Screen KCM writes through its KAuth helper
# — the only value on this file we can check ourselves against something
# authoritative. A machine still carrying the bare path reads as needing setup and
# is upgraded once, rather than being left on a value we never saw Plasma write.
LOGIN_WALLPAPER_GREETER_URL="file://$LOGIN_WALLPAPER_FILE"

# Where the greeter names its image. Every level matters, [Greeter] included —
# the same three groups written at the top level are read by nothing, which is a
# bug that has already been shipped once (see .claude/rules/manage-tools.md). The
# reader and the writer below share this one array so it cannot recur one-sided.
LOGIN_WALLPAPER_GREETER_GROUPS=(--group Greeter --group Wallpaper --group org.kde.image --group General)

# Whether Plasma's login manager is here to be configured at all. A machine
# without it still gets the published file — hyprlock reads it either way.
login_wallpaper_has_greeter() {
    command_exists plasmalogin && command_exists kwriteconfig6
}

# The image the greeter is configured to show, empty when unset. Only ever
# called behind login_wallpaper_has_greeter, and a missing kreadconfig6 under
# the 2>/dev/null answers the same empty string anyway.
login_wallpaper_greeter_image() {
    kreadconfig6 --file "$PLASMALOGIN_CONF" \
        "${LOGIN_WALLPAPER_GREETER_GROUPS[@]}" --key Image 2>/dev/null
}

# True when this machine is missing the privileged half of the setup.
#
# Only the two steps that need root are in here. A published file that is merely
# *missing* is not: with a writable directory the picker republishes at the next
# pick and awww-init seeds it at session start, both with no privilege at all, so
# asking for a password over that would be asking for nothing.
login_wallpaper_needs_setup() {
    [ -w "$LOGIN_WALLPAPER_DIR" ] || return 0
    login_wallpaper_has_greeter || return 1
    [ "$(login_wallpaper_greeter_image)" != "$LOGIN_WALLPAPER_GREETER_URL" ]
}

# The privileged steps themselves, headerless so both callers can frame them their
# own way. Idempotent, and safe to re-run to repair a hand-edited greeter config:
# opening System Settings → Login Screen rewrites this file with the KCM's own
# copied path, and re-running this is what puts it back.
apply_login_wallpaper() {
    # Unconditional: `install -d` also repairs the ownership of a directory that
    # already exists, which is what the picker needs to write into it. Only -o
    # matters — the mode is 755, so the group never decides the write.
    sudo install -d -o "$USER" -m 755 "$LOGIN_WALLPAPER_DIR" || {
        track_warning "Could not create $LOGIN_WALLPAPER_DIR — lock and login screens keep their stock wallpaper"
        return 1
    }

    # Seed it so the very first lock is not a black screen. The picker owns the
    # copy — one atomic write, one `awww query` parse, one published path — and
    # publishing here is the only reason this function needs a seed at all: a
    # machine that never picked one gets it from awww-init at session start.
    if [ ! -f "$LOGIN_WALLPAPER_FILE" ]; then
        if "$HOME/.local/bin/wallpaper-picker.sh" publish; then
            print_success "Seeded $LOGIN_WALLPAPER_FILE from the running desktop"
        else
            print_info "Nothing to seed it with yet — the first session, or the first pick, publishes it"
        fi
    fi

    # kwriteconfig6 rather than a heredoc: /etc/plasmalogin.conf is the greeter's
    # whole configuration, [Autologin] and all, and rewriting it wholesale to set
    # one key is how you lose the rest of it.
    if login_wallpaper_has_greeter; then
        sudo kwriteconfig6 --file "$PLASMALOGIN_CONF" \
            --group Greeter --key WallpaperPluginId org.kde.image
        sudo kwriteconfig6 --file "$PLASMALOGIN_CONF" \
            "${LOGIN_WALLPAPER_GREETER_GROUPS[@]}" \
            --key Image "$LOGIN_WALLPAPER_GREETER_URL"
        print_success "Login greeter wallpaper points at $LOGIN_WALLPAPER_FILE"
    else
        print_info "No Plasma Login Manager here — published for hyprlock only"
    fi
    return 0
}
