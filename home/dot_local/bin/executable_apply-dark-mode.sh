#!/bin/bash

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

# 2. Update chezmoi config so chezmoi diff stays clean for templated files
CHEZMOI_CONF="$HOME/.config/chezmoi/chezmoi.toml"
if [ -f "$CHEZMOI_CONF" ]; then
    if grep -q 'dark_mode = ' "$CHEZMOI_CONF"; then
        sed -i 's/dark_mode = .*/dark_mode = "'"$MODE"'"/' "$CHEZMOI_CONF"
    else
        sed -i '/^\[data\]/a\    dark_mode = "'"$MODE"'"' "$CHEZMOI_CONF"
    fi
fi

# 3. Portal color-scheme (tells browsers prefers-color-scheme via xdg-desktop-portal)
# Each portal backend monitors its own settings store; write to the correct one.
if [ "$MODE" = "dark" ]; then
    GNOME_SCHEME='prefer-dark'
else
    GNOME_SCHEME='prefer-light'
fi

# 3a. GTK/GNOME portal backend — monitors dconf
if command -v gsettings &>/dev/null; then
    gsettings set org.gnome.desktop.interface color-scheme "$GNOME_SCHEME" 2>/dev/null || true
elif command -v dconf &>/dev/null; then
    dconf write /org/gnome/desktop/interface/color-scheme "'$GNOME_SCHEME'" 2>/dev/null || true
fi

# 3b. KDE portal backend — monitors kdeglobals
if command -v plasma-apply-colorscheme &>/dev/null; then
    if [ "$MODE" = "dark" ]; then
        plasma-apply-colorscheme BreezeDark 2>/dev/null || true
    else
        plasma-apply-colorscheme BreezeLight 2>/dev/null || true
    fi
fi

# 4. Kitty
KITTY_THEME_SRC="$HOME/.config/kitty/themes/${MODE}.conf"
if [ -f "$KITTY_THEME_SRC" ]; then
    cp "$KITTY_THEME_SRC" "$HOME/.config/kitty/current-theme.conf"
    pkill -SIGUSR1 -x kitty 2>/dev/null || true
fi

# 5. Starship (only replace the top-level palette line, not palette definitions)
STARSHIP_CONF="$HOME/.config/starship.toml"
if [ -f "$STARSHIP_CONF" ]; then
    sed -i "s/^palette = 'catppuccin_.*'/palette = 'catppuccin_${FLAVOR}'/" "$STARSHIP_CONF"
fi

# 6. Yazi
YAZI_THEME="$HOME/.config/yazi/theme.toml"
if [ -f "$YAZI_THEME" ]; then
    sed -i "s/^dark = .*/dark = \"catppuccin-${FLAVOR}\"/" "$YAZI_THEME"
fi

# 7. Mako
MAKO_SRC="$HOME/.config/mako/config-${MODE}"
if [ -f "$MAKO_SRC" ]; then
    cp "$MAKO_SRC" "$HOME/.config/mako/config"
    makoctl reload 2>/dev/null || true
fi

# 8. Rofi
ROFI_SRC="$HOME/.local/share/rofi/themes/moinax-${MODE}.rasi"
if [ -f "$ROFI_SRC" ]; then
    cp "$ROFI_SRC" "$HOME/.local/share/rofi/themes/moinax.rasi"
fi

# 9. Wlogout
WLOGOUT_SRC="$HOME/.config/wlogout/style-${MODE}.css"
if [ -f "$WLOGOUT_SRC" ]; then
    cp "$WLOGOUT_SRC" "$HOME/.config/wlogout/style.css"
fi

# 10. Waybar CSS
WAYBAR_CSS_SRC="$HOME/.config/waybar/style-${MODE}.css"
if [ -f "$WAYBAR_CSS_SRC" ]; then
    cp "$WAYBAR_CSS_SRC" "$HOME/.config/waybar/style.css"
fi

# 11. Compositor borders
if pgrep -x Hyprland &>/dev/null; then
    if [ "$MODE" = "dark" ]; then
        hyprctl keyword general:col.active_border "rgba(ff64ff80) rgba(9696ffff) 45deg" 2>/dev/null || true
        hyprctl keyword general:col.inactive_border "rgba(6464ff4d)" 2>/dev/null || true
    else
        hyprctl keyword general:col.active_border "rgba(8839efcc) rgba(1e66f5cc) 45deg" 2>/dev/null || true
        hyprctl keyword general:col.inactive_border "rgba(7287fd4d)" 2>/dev/null || true
    fi
elif pgrep -x niri &>/dev/null; then
    NIRI_CONF="$HOME/.config/niri/config.kdl"
    if [ -f "$NIRI_CONF" ]; then
        if [ "$MODE" = "dark" ]; then
            sed -i '/border {/,/}/ s/active-gradient from="[^"]*" to="[^"]*"/active-gradient from="#ff64ff80" to="#9696ffff"/' "$NIRI_CONF"
            sed -i '/border {/,/}/ s/inactive-color "[^"]*"/inactive-color "#6464ff4d"/' "$NIRI_CONF"
        else
            sed -i '/border {/,/}/ s/active-gradient from="[^"]*" to="[^"]*"/active-gradient from="#8839efcc" to="#1e66f5cc"/' "$NIRI_CONF"
            sed -i '/border {/,/}/ s/inactive-color "[^"]*"/inactive-color "#7287fd4d"/' "$NIRI_CONF"
        fi
        niri msg action load-config-file 2>/dev/null || true
    fi
fi

# 12. Neovim
NVIM_THEME_FILE="$HOME/.local/share/nvim-theme"
echo "$FLAVOR" > "$NVIM_THEME_FILE"
# Best-effort remote send to running nvim instances
for addr in /run/user/$(id -u)/nvim.*.0 /tmp/nvim.*/0; do
    [ -S "$addr" ] || continue
    nvim --server "$addr" --remote-send "<Cmd>lua local c = require('catppuccin'); c.options.flavour = '${FLAVOR}'; c.compile(); vim.cmd.colorscheme('catppuccin')<CR>" 2>/dev/null || true
done

# 13. Delta (git diff) — swap theme feature while preserving other features
if command -v git &>/dev/null; then
    CURRENT_FEATURES=$(git config --global --get delta.features 2>/dev/null || true)
    if [ "$MODE" = "dark" ]; then
        NEW_FEATURES=$(echo "$CURRENT_FEATURES" | sed 's/hoopoe/arctic-fox/')
        git config --global delta.syntax-theme "Catppuccin Macchiato" 2>/dev/null || true
    else
        NEW_FEATURES=$(echo "$CURRENT_FEATURES" | sed 's/arctic-fox/hoopoe/')
        git config --global delta.syntax-theme "GitHub" 2>/dev/null || true
    fi
    git config --global delta.features "$NEW_FEATURES" 2>/dev/null || true
fi

# 14. Cursor
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
    if jq --arg theme "$THEME" --arg iconTheme "$ICON_THEME" \
        '.["workbench.colorTheme"] = $theme | .["workbench.iconTheme"] = $iconTheme' \
        "$CURSOR_SETTINGS" > "$tmp"; then
        mv "$tmp" "$CURSOR_SETTINGS"
    else
        rm -f "$tmp"
    fi
fi

# 15. Waybar restart
if [ -x "$HOME/.config/waybar/launch-waybar.sh" ]; then
    killall -q waybar 2>/dev/null || true
    "$HOME/.config/waybar/launch-waybar.sh" &
    disown
fi

# 16. Notification
if [ "$MODE" = "dark" ]; then
    notify-send -u low "Dark Mode" "Switched to Catppuccin Mocha (dark)" 2>/dev/null || true
else
    notify-send -u low "Light Mode" "Switched to Catppuccin Latte (light)" 2>/dev/null || true
fi
