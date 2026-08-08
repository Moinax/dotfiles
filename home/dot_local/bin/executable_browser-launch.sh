#!/usr/bin/env bash
# browser-launch — launch the default web browser, or one named by desktop id.
#   browser-launch.sh              → launch the system default web browser
#   browser-launch.sh list         → <desktop id>\t<name>\t<icon>\t<default 0|1>
#   browser-launch.sh launch ID    → launch that desktop id
#
# No menu of its own: the vicinae Browser command (Mod+Alt+B) is the frontend.
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

# Scan freedesktop entries once, into parallel arrays.
scan_browsers() {
    declare -A seen
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

    # Aborting here rather than in each caller: an empty scan is never a usable
    # result, whichever front door asked for it.
    if [ "${#ids[@]}" -eq 0 ]; then
        notify-send -u critical "Browser picker" "No web browsers found"
        exit 1
    fi
}

case "${1:-default}" in
    list)
        # Prints "<desktop id>\t<name>\t<icon name>\t<default 0|1>" and stops —
        # the vicinae Browser command renders its own menu from that. Launching
        # still goes through `launch`, so the gtk-launch + setsid detach is not
        # reimplemented anywhere.
        scan_browsers
        def="$(xdg-settings get default-web-browser 2>/dev/null || true)"
        def="${def%.desktop}"
        for i in "${!ids[@]}"; do
            printf '%s\t%s\t%s\t%s\n' "${ids[$i]}" "${names[$i]}" "${icons[$i]}" \
                "$([ "${ids[$i]}" = "$def" ] && echo 1 || echo 0)"
        done
        exit 0
        ;;
    launch)
        [ -n "${2:-}" ] || { echo "browser-launch: launch requires a desktop id" >&2; exit 1; }
        launch_desktop "$2"
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
