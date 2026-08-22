#!/usr/bin/env bash
# browser-launch — launch the default web browser, or one named by desktop id.
#   browser-launch.sh              → launch the system default web browser
#   browser-launch.sh list         → <desktop id>\t<name>\t<icon>\t<default 0|1>
#
# No menu of its own: the vicinae Browser command (Mod+Alt+B) is the frontend.
#
# Both the scan and the launch live in desktop-apps — a browser is nothing but
# `Categories=*WebBrowser`, and the Chats picker wants the same crawl for
# `InstantMessaging`. What is left here is the part that is not generic: which
# of them xdg-settings calls the default.
set -euo pipefail

apps="$HOME/.local/bin/desktop-apps"

default_browser() {
    local def
    def="$(xdg-settings get default-web-browser 2>/dev/null || true)"
    echo "${def%.desktop}"
}

case "${1:-default}" in
    list)
        # Prints "<desktop id>\t<name>\t<icon name>\t<default 0|1>" and stops —
        # the vicinae Browser command renders its own menu from that, and calls
        # `desktop-apps launch` directly to open one.
        def="$(default_browser)"
        "$apps" list WebBrowser | while IFS=$'\t' read -r id name icon; do
            printf '%s\t%s\t%s\t%s\n' "$id" "$name" "$icon" \
                "$([ "$id" = "$def" ] && echo 1 || echo 0)"
        done
        ;;
    *)
        def="$(default_browser)"
        if [ -n "$def" ]; then
            "$apps" launch "$def"
        else
            xdg-open about:blank
        fi
        ;;
esac
