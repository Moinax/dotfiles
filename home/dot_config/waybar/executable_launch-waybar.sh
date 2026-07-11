#!/usr/bin/env bash
# Waybar launcher: detects compositor, classifies monitors by effective width,
# and generates a runtime config with per-bar output filters.

. "$HOME/.local/lib/compositor.sh"

if is_hyprland; then
    COMPOSITOR="hyprland"
else
    echo "Error: no supported compositor detected (Hyprland expected)" >&2
    exit 1
fi

# kded6 StatusNotifierWatcher is required for system tray on standalone WMs.
dbus-send --session --print-reply --dest=org.kde.kded6 /kded \
    org.kde.kded6.loadModule string:statusnotifierwatcher >/dev/null 2>&1 || true

CONFIG_FILE="$HOME/.config/waybar/config-${COMPOSITOR}"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Waybar config not found: $CONFIG_FILE" >&2
    echo "Run 'chezmoi apply' to generate compositor-specific configs." >&2
    exit 1
fi

CLASSIFIER="$HOME/.config/waybar/scripts/classify-monitors.sh"
CLASS_JSON="$("$CLASSIFIER" "$COMPOSITOR" 2>/dev/null || echo '{"wide":[],"narrow":[]}')"

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/waybar"
mkdir -p "$CACHE_DIR"
GEN_CONFIG="$CACHE_DIR/config-${COMPOSITOR}.json"

# Inject per-bar outputs by matching each bar's "name" sentinel, then drop
# bars that ended up with no assigned monitors. Fall back to the raw template
# if jq fails or produces no bars (e.g. empty classifier output at autostart).
if jq -e --argjson cls "$CLASS_JSON" '
  map(
    if .name == "full"    then .output = $cls.wide
    elif .name == "minimal" then .output = $cls.narrow
    else . end
  ) | map(select(.output | length > 0)) | if length > 0 then . else empty end
' "$CONFIG_FILE" > "$GEN_CONFIG"; then
    exec waybar -c "$GEN_CONFIG"
else
    exec waybar -c "$CONFIG_FILE"
fi
