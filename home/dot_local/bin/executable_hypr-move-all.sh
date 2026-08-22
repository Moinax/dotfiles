#!/bin/bash
# Move every window of the active workspace to another workspace at once.
#
# Hyprland has no dispatcher for this — movetoworkspace takes a single window —
# so the only route is one dispatch per window. `window = "address:…"` targets
# each one without focusing it first, and the whole list goes through a single
# `hyprctl --batch` so the compositor relayouts once rather than per window.
#
# Must be invoked via `hl.exec_cmd` (async child) — NEVER via `io.popen` from
# within a Lua bind callback, which would deadlock Hyprland (see the note in
# hypr-move-or-group.sh).
#
# Usage: hypr-move-all.sh <workspace> [--silent]
#   hypr-move-all.sh 3            → move them all to workspace 3 and follow
#   hypr-move-all.sh special      → move them all to the scratchpad
#   hypr-move-all.sh 3 --silent   → move them, stay where you are

set -euo pipefail

target="${1:?usage: $0 <workspace> [--silent]}"
follow=true
[ "${2-}" = "--silent" ] && follow=false

# The source is the scratchpad when it is open over the focused monitor, and the
# normal workspace otherwise. `activeworkspace` cannot say which: it reports the
# normal workspace underneath even while the special one is shown on top, so the
# monitor is what has to be asked. Moving *to* the scratchpad is the exception —
# source and target would be the same workspace and nothing would move — so that
# direction always reads the normal one.
ws=$(hyprctl monitors -j | jq --arg t "$target" 'map(select(.focused))[0]
    | if .specialWorkspace.id != 0 and $t != "special"
      then .specialWorkspace.id else .activeWorkspace.id end')
[ -n "$ws" ] && [ "$ws" != "null" ] || { echo "$0: no focused monitor" >&2; exit 1; }

batch=$(hyprctl clients -j | jq -r --argjson ws "$ws" --arg t "$target" --arg f "$follow" '
    [ .[]
      | select(.workspace.id == $ws)
      | "dispatch hl.dsp.window.move({ workspace = \"\($t)\", follow = \($f), window = \"address:\(.address)\" })"
    ] | join(" ; ")')

# An empty workspace has nothing to move, and `hyprctl --batch ""` is an error.
if [ -n "$batch" ]; then
    hyprctl --batch "$batch" >/dev/null
fi
