#!/bin/bash
# The dark/light surfaces that read a *copy* instead of the mode-specific file.
#
# Each reads one fixed path — style.css, theme.yml, current-theme.conf — and the
# mode is expressed by copying style-dark.css or style-light.css over it. None of
# those copies is chezmoi-managed, so nothing but this file's callers ever writes
# them, and **a `chezmoi apply` that rewrites the managed sources reaches none of
# these surfaces**: the copy they actually read keeps whatever the last dark/light
# toggle put there, and the change waits, silently, for the next Mod+N.
#
# Hence a shared file rather than a list in either caller: `apply-dark-mode.sh`
# needs it to switch modes and `install/lib/post-apply.sh` to reconcile after an
# apply, and two copies of the list would go stale the first time a surface was
# added to one and not the other — which is the bug above, again. The whole story
# is in `.claude/rules/post-apply.md`.
#
# Reload policy is deliberately *not* here. The two callers need different
# things: a mode toggle only changes colours, so swaync takes a cheap
# `swaync-client -rs`, while an apply can change structure (a font family) and
# needs the daemon replaced outright. Each caller reloads what it knows it broke.

THEME_STATE_FILE="$HOME/.local/share/dark-light-mode"

# The mode in force. Same file and same default apply-dark-mode.sh has always
# used; anything unrecognised reads as dark rather than propagating a typo into
# six filenames.
theme_mode() {
    [ "$(cat "$THEME_STATE_FILE" 2>/dev/null)" = light ] && echo light || echo dark
}

# The mode a `uint32 N` payload carries: 1 = dark, 2 = light, 0 = no preference.
# Anything but an explicit 2 reads as dark, matching theme_mode's default.
# Takes any gdbus text carrying the value — a ReadOne reply or a monitor's
# SettingChanged line — and fails when it carries none.
scheme_mode() {
    [[ $1 =~ uint32\ ([0-9]+) ]] || return 1
    [ "${BASH_REMATCH[1]}" = 2 ] && echo light || echo dark
}

# The appearance the desktop is *showing*, which is not always the one this repo
# last wrote — anything can flip the KDE scheme, and the portal is where every
# app reads it. Fails on a session without a portal, so callers pair it with
# theme_mode: `$(portal_mode || theme_mode)`.
#
# Both readers exist on purpose. This one answers "what is on screen" and is
# what a *toggle* has to invert; theme_mode answers "what did we last apply" and
# is what the copies are keyed on. They agree unless something outside this repo
# changed the scheme, which is exactly the case worth getting right.
portal_mode() {
    scheme_mode "$(gdbus call --session --dest org.freedesktop.portal.Desktop \
        --object-path /org/freedesktop/portal/desktop \
        --method org.freedesktop.portal.Settings.ReadOne \
        org.freedesktop.appearance color-scheme 2>/dev/null)"
}

# One copy, source then destination, both relative to $HOME. A missing source is
# skipped rather than an error — a machine without swayosd installed still has
# the rest to sync.
_theme_copy() {
    [ -f "$HOME/$1" ] || return 0
    cp "$HOME/$1" "$HOME/$2" 2>/dev/null || true
}

# Refresh every copy for the given mode (default: the mode in force). Never
# fails: the caller's real work follows.
sync_theme_copies() {
    local mode="${1:-$(theme_mode)}"

    _theme_copy ".config/kitty/themes/$mode.conf"            ".config/kitty/current-theme.conf"
    _theme_copy ".config/eza/theme-$mode.yml"                ".config/eza/theme.yml"
    _theme_copy ".config/swaync/style-$mode.css"             ".config/swaync/style.css"
    _theme_copy ".config/swayosd/style-$mode.css"            ".config/swayosd/style.css"
    _theme_copy ".config/wlogout/style-$mode.css"            ".config/wlogout/style.css"
    return 0
}
