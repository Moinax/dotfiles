#!/bin/bash

# Waybar custom module: dark/light mode status (continuous JSON output)
#
# Follows the portal's colour-scheme — the same source waybar's own stylesheet
# and vicinae read — so the icon tracks the system appearance itself, whoever
# flipped it, and not the caller that happened to flip it. It used to be a
# one-shot re-run poked with RTMIN+8 by apply-dark-mode.sh, which is why it
# only ever moved for Mod+N.
#
# Waybar runs this as a long-lived process (continuous exec mode); one gdbus
# monitor for the whole bar, woken only by the signal.

ICON_MOON=$(printf '\uf4ee') # Octicons moon
ICON_SUN=$(printf '\uf522')

# The portal announces the same color-scheme three times per flip (KDE emits it
# for the scheme change, the accent recompute and the kdeglobals mirror), so the
# mode already drawn is remembered rather than redrawn.
LAST_MODE=""

emit_status() {
    [ "$1" = "$LAST_MODE" ] && return
    LAST_MODE="$1"
    if [ "$1" = "light" ]; then
        printf '{"text": "%s", "class": "light", "tooltip": "Light mode (Catppuccin Latte)"}\n' "$ICON_SUN"
    else
        printf '{"text": "%s", "class": "dark", "tooltip": "Dark mode (Catppuccin Mocha)"}\n' "$ICON_MOON"
    fi
}

# org.freedesktop.appearance color-scheme: 1 = dark, 2 = light, 0 = no
# preference. Anything but an explicit 2 is drawn as dark, which is also this
# desktop's default.
scheme_to_mode() {
    [ "$1" = "2" ] && echo light || echo dark
}

# Initial state. The portal is the source of truth, but a session without it
# still has the state file apply-dark-mode.sh writes.
initial=$(gdbus call --session --dest org.freedesktop.portal.Desktop \
    --object-path /org/freedesktop/portal/desktop \
    --method org.freedesktop.portal.Settings.ReadOne \
    org.freedesktop.appearance color-scheme 2>/dev/null)

if [[ $initial =~ uint32\ ([0-9]+) ]]; then
    emit_status "$(scheme_to_mode "${BASH_REMATCH[1]}")"
else
    emit_status "$(cat "$HOME/.local/share/dark-light-mode" 2>/dev/null || echo dark)"
fi

# Then re-emit on every appearance change. gdbus exiting (portal restart) ends
# the script, and waybar's restart-interval brings it back.
#
# Read through a process substitution rather than a pipe, for the trap: waybar
# terminates this script on every reload, and a piped gdbus would outlive it
# until its next write hit the closed pipe — one stray monitor per reload.
exec 3< <(gdbus monitor --session --dest org.freedesktop.portal.Desktop 2>/dev/null)
MONITOR_PID=$!
trap 'kill "$MONITOR_PID" 2>/dev/null' EXIT

while IFS= read -r line <&3; do
    case "$line" in
        *"SettingChanged ('org.freedesktop.appearance', 'color-scheme'"*)
            [[ $line =~ uint32\ ([0-9]+) ]] || continue
            emit_status "$(scheme_to_mode "${BASH_REMATCH[1]}")"
            ;;
    esac
done
