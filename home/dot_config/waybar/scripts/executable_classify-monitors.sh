#!/usr/bin/env bash
# Classify connected monitors by effective width (post-scale, post-rotation).
# Emits {"wide":[...],"narrow":[...]} on stdout.
# Threshold: effective width >= 1920 is "wide".

set -euo pipefail

COMPOSITOR="${1:?compositor arg required: hyprland}"

case "$COMPOSITOR" in
  hyprland)
    hyprctl -j monitors | jq -c '
      def eff: if (.transform % 2 == 1) then (.height / .scale) else (.width / .scale) end;
      [.[] | select(.disabled | not)] as $active |
      { wide:   [$active[] | select((eff) >= 1920) | .name],
        narrow: [$active[] | select((eff) <  1920) | .name] }'
    ;;
  *)
    echo "unknown compositor: $COMPOSITOR (expected hyprland)" >&2
    exit 2
    ;;
esac
