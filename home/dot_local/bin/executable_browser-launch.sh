#!/usr/bin/env bash
# browser-launch — launch the default web browser, or pick one via rofi.
#   browser-launch.sh        → launch the system default web browser
#   browser-launch.sh pick   → rofi menu of installed browsers, launch the pick
#
# Browsers are discovered from freedesktop .desktop entries whose Categories
# include WebBrowser (covers pacman/AUR browsers and AppImage installs that
# register a desktop file, e.g. Helium). No hardcoded browser list.
set -euo pipefail

# Launch a desktop entry detached from this script. gtk-launch takes the
# desktop id (basename, .desktop optional); setsid -f fully detaches so the
# script — and Hyprland's exec — return immediately.
launch_desktop() {
    setsid -f gtk-launch "${1%.desktop}" >/dev/null 2>&1
}

case "${1:-default}" in
    pick)
        declare -A seen
        # Parallel arrays rather than pre-built rofi rows: the row format below
        # embeds a NUL byte, which bash strips from variables — so name/icon are
        # kept raw and the row is assembled only at print time.
        ids=(); names=(); icons=()
        while IFS= read -r f; do
            id="${f##*/}"; id="${id%.desktop}"
            # One pass per file for the first Name=/Icon= and the hidden flag.
            # Fields are joined with 0x1f (non-whitespace) so read preserves
            # empty leading/middle fields instead of collapsing them.
            IFS=$'\x1f' read -r hidden name icon < <(awk -v s=$'\x1f' '
                /^NoDisplay=true/ || /^Hidden=true/ { hidden = 1 }
                /^Name=/ && !name { name = substr($0, 6) }
                /^Icon=/ && !icon { icon = substr($0, 6) }
                END { printf "%s%s%s%s%s\n", hidden, s, name, s, icon }
            ' "$f")
            [ -n "$hidden" ] && continue
            [ -z "$name" ] && name="$id"
            key="${name,,}"
            [ -n "${seen[$key]:-}" ] && continue   # dedupe on display name
            seen[$key]=1
            ids+=("$id")
            names+=("${name^}")                    # capitalize for display (helium → Helium)
            icons+=("$icon")
        done < <(
            grep -rlE '^Categories=.*WebBrowser' \
                /usr/share/applications \
                "$HOME/.local/share/applications" 2>/dev/null | sort
        )

        if [ "${#ids[@]}" -eq 0 ]; then
            notify-send -u critical "Browser picker" "No web browsers found"
            exit 1
        fi

        # `-format i` returns the 0-based index of the pick, so display names
        # can collide without ambiguity when mapping back to the desktop id.
        idx="$(
            for i in "${!names[@]}"; do
                printf '%s\0icon\x1f%s\n' "${names[$i]}" "${icons[$i]}"
            done | rofi -dmenu -i -p "Browser" -show-icons -format i
        )"
        [ -z "$idx" ] && exit 0
        launch_desktop "${ids[$idx]}"
        ;;
    *)
        def="$(xdg-settings get default-web-browser 2>/dev/null || true)"
        if [ -n "$def" ]; then
            launch_desktop "$def"
        else
            xdg-open about:blank
        fi
        ;;
esac
