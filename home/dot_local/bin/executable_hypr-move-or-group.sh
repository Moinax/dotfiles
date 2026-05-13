#!/bin/bash
# Group-aware window mover for Hyprland 0.55+. Behavior:
#   1. If the active window is in a group: move OUT of the group in <dir>.
#   2. Else if an adjacent group exists in <dir>: move INTO it.
#   3. Else: swap with the visual neighbor in <dir> (no tree restructuring).
#
# Step 2 is detected by attempting into_group and re-reading the active
# window's group state — into_group is a no-op when no adjacent group exists.
#
# Must be invoked via `hl.exec_cmd` (async child) — NEVER via `io.popen` from
# within a Lua bind callback, which would deadlock Hyprland (the compositor
# blocks on read while hyprctl is waiting on Hyprland's IPC socket).
#
# Usage: hypr-move-or-group.sh <l|r|u|d>

set -e

dir="$1"
case "$dir" in
    l|r|u|d) ;;
    *) echo "usage: $0 <l|r|u|d>" >&2; exit 2 ;;
esac

in_group=$(hyprctl activewindow -j | jq -r '(.grouped // []) | length > 1')

if [ "$in_group" = "true" ]; then
    hyprctl dispatch "hl.dsp.window.move({ out_of_group = \"$dir\" })" >/dev/null
    exit 0
fi

# Try to enter an adjacent group; check whether it took effect.
hyprctl dispatch "hl.dsp.window.move({ into_group = \"$dir\" })" >/dev/null
after_in_group=$(hyprctl activewindow -j | jq -r '(.grouped // []) | length > 1')

if [ "$after_in_group" = "false" ]; then
    hyprctl dispatch "hl.dsp.window.swap({ direction = \"$dir\" })" >/dev/null
fi
