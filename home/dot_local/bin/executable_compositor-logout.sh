#!/bin/bash
set -e

# Exit the compositor gracefully so sddm-helper finishes with status 0 and
# SDDM re-spawns the greeter. `loginctl terminate-session` looks tidy but
# SIGTERMs the whole cgroup including sddm-helper, which SDDM then logs as
# "Process crashed" — on NVIDIA the DRM master isn't always released
# cleanly afterwards and the VT stays black.
. "$HOME/.local/lib/compositor.sh"

if is_hyprland; then
    # Hyprland 0.55 parses `hyprctl dispatch` args as Lua, so the bare
    # `exit` identifier no longer resolves. The Lua call form does.
    hyprctl dispatch 'hl.dsp.exit()'
elif is_niri; then
    niri msg action quit --skip-confirmation
else
    loginctl terminate-session "${XDG_SESSION_ID}"
fi
