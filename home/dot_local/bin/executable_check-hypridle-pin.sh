#!/bin/bash
set -euo pipefail

# Watches for the Arch rebuild that lets us lift the sdbus-cpp / hyprlock pins.
#
# Background (see also the project memory project_sdbus_cpp_pin):
#   sdbus-cpp is held at 2.2.1 and hyprlock at 0.9.5-2 via IgnorePkg in
#   /etc/pacman.conf, because sdbus-cpp 2.3 broke the ABI hypridle 0.1.7-9 was
#   built against. The pins can be lifted once Arch rebuilds hypridle PAST
#   0.1.7-9 (a single pacman -Syu then brings the whole set in together).
#
# This fires once a day (systemd user timer) and sends a desktop notification
# the moment the repo carries a hypridle newer than the pinned baseline — but
# only while the pin is still active, so it goes quiet on its own once you
# remove the IgnorePkg line.

BASELINE="0.1.7-9"   # the broken pkgrel; anything newer means a rebuild landed

# Nothing to watch for if the pin is already gone.
if ! grep -Eq '^\s*IgnorePkg\s*=.*\bsdbus-cpp\b' /etc/pacman.conf 2>/dev/null; then
    exit 0
fi

# Read the repo version from the synced pacman db (no sudo, no -Sy needed).
# Reflects whatever the local sync db holds, so it surfaces right after your
# next `pacman -Sy`/`-Syu` / checkupdates run.
repo_ver="$(LC_ALL=C pacman -Si hypridle 2>/dev/null | awk -F': ' '/^Version/ {print $2; exit}')"
[ -n "${repo_ver:-}" ] || exit 0

# vercmp > 0  =>  repo_ver is newer than the broken baseline.
if [ "$(vercmp "$repo_ver" "$BASELINE")" -gt 0 ]; then
    notify-send --urgency=critical --icon=system-software-update \
        "hypridle rebuilt — lift the pins" \
        "hypridle ${repo_ver} is in the repos (was ${BASELINE}).\nRemove sdbus-cpp & hyprlock from IgnorePkg in /etc/pacman.conf, then run pacman -Syu."
fi
