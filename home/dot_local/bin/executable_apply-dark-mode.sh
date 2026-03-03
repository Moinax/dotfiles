#!/bin/bash
set -e

# Dark/Light mode dispatcher
# Usage: apply-dark-mode.sh [dark|light]
# If no argument given, reads from state file (defaults to dark)

STATE_FILE="$HOME/.local/share/dark-light-mode"

# Determine mode
if [ -n "$1" ]; then
    MODE="$1"
else
    MODE=$(cat "$STATE_FILE" 2>/dev/null || echo "dark")
fi

# Validate
if [ "$MODE" != "dark" ] && [ "$MODE" != "light" ]; then
    echo "Usage: apply-dark-mode.sh [dark|light]" >&2
    exit 1
fi

# Map mode to catppuccin flavor
if [ "$MODE" = "dark" ]; then
    FLAVOR="mocha"
else
    FLAVOR="latte"
fi

# 1. Write state
mkdir -p "$(dirname "$STATE_FILE")"
echo "$MODE" > "$STATE_FILE"

# 2. Portal/GTK color scheme
if command -v gsettings &>/dev/null; then
    if [ "$MODE" = "dark" ]; then
        gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' 2>/dev/null || true
    else
        gsettings set org.gnome.desktop.interface color-scheme 'prefer-light' 2>/dev/null || true
    fi
fi

# 3. Kitty
KITTY_THEME_SRC="$HOME/.config/kitty/themes/${MODE}.conf"
if [ -f "$KITTY_THEME_SRC" ]; then
    cp "$KITTY_THEME_SRC" "$HOME/.config/kitty/current-theme.conf"
    if pgrep -x kitty &>/dev/null; then
        kill -SIGUSR1 $(pgrep -x kitty) 2>/dev/null || true
    fi
fi

# 4. Starship
STARSHIP_CONF="$HOME/.config/starship.toml"
if [ -f "$STARSHIP_CONF" ]; then
    sed -i "s/^palette = .*/palette = 'catppuccin_${FLAVOR}'/" "$STARSHIP_CONF"
fi

# 5. Yazi
YAZI_THEME="$HOME/.config/yazi/theme.toml"
if [ -f "$YAZI_THEME" ]; then
    sed -i "s/^dark = .*/dark = \"catppuccin-${FLAVOR}\"/" "$YAZI_THEME"
fi

# 6. Mako
MAKO_SRC="$HOME/.config/mako/config-${MODE}"
if [ -f "$MAKO_SRC" ]; then
    cp "$MAKO_SRC" "$HOME/.config/mako/config"
    makoctl reload 2>/dev/null || true
fi

# 7. Rofi
ROFI_SRC="$HOME/.local/share/rofi/themes/moinax-${MODE}.rasi"
if [ -f "$ROFI_SRC" ]; then
    cp "$ROFI_SRC" "$HOME/.local/share/rofi/themes/moinax.rasi"
fi

# 8. Wlogout
WLOGOUT_SRC="$HOME/.config/wlogout/style-${MODE}.css"
if [ -f "$WLOGOUT_SRC" ]; then
    cp "$WLOGOUT_SRC" "$HOME/.config/wlogout/style.css"
fi

# 9. Waybar CSS
WAYBAR_CSS_SRC="$HOME/.config/waybar/style-${MODE}.css"
if [ -f "$WAYBAR_CSS_SRC" ]; then
    cp "$WAYBAR_CSS_SRC" "$HOME/.config/waybar/style.css"
fi

# 10. Hyprland borders
if pgrep -x Hyprland &>/dev/null; then
    if [ "$MODE" = "dark" ]; then
        hyprctl keyword general:col.active_border "rgba(ff64ff80) rgba(9696ffff) 45deg" 2>/dev/null || true
        hyprctl keyword general:col.inactive_border "rgba(6464ff4d)" 2>/dev/null || true
    else
        hyprctl keyword general:col.active_border "rgba(8839efcc) rgba(1e66f5cc) 45deg" 2>/dev/null || true
        hyprctl keyword general:col.inactive_border "rgba(7287fd4d)" 2>/dev/null || true
    fi
fi

# 10b. Niri borders (best-effort sed on deployed config + reload)
if pgrep -x niri &>/dev/null; then
    NIRI_CONF="$HOME/.config/niri/config.kdl"
    if [ -f "$NIRI_CONF" ]; then
        if [ "$MODE" = "dark" ]; then
            sed -i 's/active-gradient from="[^"]*" to="[^"]*"/active-gradient from="#ff64ff80" to="#9696ffff"/' "$NIRI_CONF"
            sed -i 's/inactive-color "[^"]*"/inactive-color "#6464ff4d"/' "$NIRI_CONF"
        else
            sed -i 's/active-gradient from="[^"]*" to="[^"]*"/active-gradient from="#8839efcc" to="#1e66f5cc"/' "$NIRI_CONF"
            sed -i 's/inactive-color "[^"]*"/inactive-color "#7287fd4d"/' "$NIRI_CONF"
        fi
        niri msg action do-screen-transition 2>/dev/null || true
    fi
fi

# 11. Neovim
NVIM_THEME_FILE="$HOME/.local/share/nvim-theme"
echo "$FLAVOR" > "$NVIM_THEME_FILE"
# Best-effort remote send to running nvim instances
for addr in /run/user/$(id -u)/nvim.*.0 /tmp/nvim.*/0; do
    [ -S "$addr" ] || continue
    nvim --server "$addr" --remote-send "<Cmd>lua require('catppuccin').setup({flavour='${FLAVOR}'}) vim.cmd.colorscheme('catppuccin')<CR>" 2>/dev/null || true
done

# 12. Delta (git diff)
if command -v git &>/dev/null; then
    if [ "$MODE" = "dark" ]; then
        git config --global delta.features "arctic-fox" 2>/dev/null || true
        git config --global delta.syntax-theme "Catppuccin Macchiato" 2>/dev/null || true
    else
        git config --global delta.features "hoopoe" 2>/dev/null || true
        git config --global delta.syntax-theme "GitHub" 2>/dev/null || true
    fi
fi

# 13. Cursor
CURSOR_SETTINGS="$HOME/.config/Cursor/User/settings.json"
if [ -f "$CURSOR_SETTINGS" ] && command -v jq &>/dev/null; then
    if [ "$MODE" = "dark" ]; then
        THEME="Catppuccin Mocha"
        ICON_THEME="catppuccin-mocha"
    else
        THEME="Catppuccin Latte"
        ICON_THEME="catppuccin-latte"
    fi
    tmp=$(mktemp)
    jq --arg theme "$THEME" --arg iconTheme "$ICON_THEME" \
        '.["workbench.colorTheme"] = $theme | .["workbench.iconTheme"] = $iconTheme' \
        "$CURSOR_SETTINGS" > "$tmp" && mv "$tmp" "$CURSOR_SETTINGS"
fi

# 14. Waybar restart
if [ -x "$HOME/.config/waybar/launch-waybar.sh" ]; then
    killall -q waybar 2>/dev/null || true
    "$HOME/.config/waybar/launch-waybar.sh" &
    disown
fi

# Signal waybar dark-mode module to refresh
pkill -RTMIN+11 waybar 2>/dev/null || true

# 15. Notification
if [ "$MODE" = "dark" ]; then
    ICON_CHAR="Moon"
    notify-send -u low "Dark Mode" "Switched to Catppuccin Mocha (dark)" 2>/dev/null || true
else
    ICON_CHAR="Sun"
    notify-send -u low "Light Mode" "Switched to Catppuccin Latte (light)" 2>/dev/null || true
fi
