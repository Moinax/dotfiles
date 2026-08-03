#!/bin/bash

# Dark/Light mode dispatcher
# Usage: apply-dark-mode.sh [dark|light]
# If no argument given, reads from state file (defaults to dark)
#
# Design: KDE/Qt is the canonical source of truth for dark/light mode.
# plasma-apply-colorscheme updates the system appearance, and this script only
# manages repo-local theme files in addition to that KDE scheme switch.

. "$HOME/.local/lib/compositor.sh"
# Owns the list of surfaces that read a copy, shared with post-apply.sh so the
# two cannot disagree about which files a mode is made of. Reloads stay here.
. "$HOME/.local/lib/theme-copies.sh"

# The mode: the argument if given, else the one in force. theme_mode already
# normalises the state file, so this only has argv left to reject.
MODE="${1:-$(theme_mode)}"

if [ "$MODE" != "dark" ] && [ "$MODE" != "light" ]; then
    echo "Usage: apply-dark-mode.sh [dark|light]" >&2
    exit 1
fi

FLAVOR=$( [ "$MODE" = "dark" ] && echo "mocha" || echo "latte" )
# ---------- State ----------

mkdir -p "$(dirname "$THEME_STATE_FILE")"
echo "$MODE" > "$THEME_STATE_FILE"

CHEZMOI_CONF="$HOME/.config/chezmoi/chezmoi.toml"
if [ -f "$CHEZMOI_CONF" ]; then
    python3 - "$CHEZMOI_CONF" "$MODE" <<'PY' || true
from pathlib import Path
import re
import sys
import tomllib

path = Path(sys.argv[1])
mode = sys.argv[2]
text = path.read_text()

try:
    tomllib.loads(text)
except tomllib.TOMLDecodeError as exc:
    print(f"apply-dark-mode: not updating invalid chezmoi TOML: {exc}", file=sys.stderr)
    sys.exit(1)

lines = text.splitlines(keepends=True)
section_re = re.compile(r'^\s*\[([^\]]+)\]\s*(?:#.*)?$')
dark_mode_re = re.compile(r'^(\s*)dark_mode\s*=')

data_start = None
data_end = len(lines)
dark_mode_idx = None

for idx, line in enumerate(lines):
    section = section_re.match(line)
    if section:
        if data_start is not None:
            data_end = idx
            break
        if section.group(1).strip() == "data":
            data_start = idx
            continue
    if data_start is not None and dark_mode_re.match(line):
        dark_mode_idx = idx

if data_start is None:
    prefix = "" if not text or text.endswith("\n") else "\n"
    new_text = text + prefix + '[data]\n    dark_mode = "' + mode + '"\n'
elif dark_mode_idx is not None:
    indent = dark_mode_re.match(lines[dark_mode_idx]).group(1)
    lines[dark_mode_idx] = f'{indent}dark_mode = "{mode}"\n'
    new_text = "".join(lines)
else:
    lines.insert(data_end, f'    dark_mode = "{mode}"\n')
    new_text = "".join(lines)

try:
    tomllib.loads(new_text)
except tomllib.TOMLDecodeError as exc:
    print(f"apply-dark-mode: generated invalid chezmoi TOML: {exc}", file=sys.stderr)
    sys.exit(1)

path.write_text(new_text)
PY
fi

# ---------- KDE color scheme ----------
KDE_SCHEME=$( [ "$MODE" = "dark" ] && echo "BreezeDark" || echo "BreezeLight" )
if command -v plasma-apply-colorscheme &>/dev/null; then
    plasma-apply-colorscheme "$KDE_SCHEME" 2>/dev/null || true
fi

# ---------- GTK / GNOME appearance ----------
# gsettings org.gnome.desktop.interface is the authoritative GTK config
# source — it overrides ~/.config/gtk-{3,4}.0/settings.ini. GTK4/libadwaita
# apps follow the portal color-scheme on their own, but GTK3 apps (e.g.
# nm-connection-editor) have no portal-driven dark switch: the theme NAME
# must flip. Breeze and Breeze-Dark ship as separate themes, so switching
# the name is unambiguous and needs no prefer-dark variant juggling.
GNOME_SCHEME=$( [ "$MODE" = "dark" ] && echo "prefer-dark" || echo "prefer-light" )
GTK_THEME_NAME=$( [ "$MODE" = "dark" ] && echo "Breeze-Dark" || echo "Breeze" )
GTK_ICON_THEME=$( [ "$MODE" = "dark" ] && echo "breeze-dark" || echo "breeze" )
# Cursor tone is inverted relative to background: white-toned cursor on
# dark mode, black-toned on light mode (Catppuccin's -light/-dark suffix
# names the cursor color, NOT the palette it pairs with).
CURSOR_TONE=$( [ "$MODE" = "dark" ] && echo "dark" || echo "light" )
CURSOR_THEME="catppuccin-${FLAVOR}-${CURSOR_TONE}-cursors"
CURSOR_SIZE=24
if command -v gsettings &>/dev/null; then
    gsettings set org.gnome.desktop.interface color-scheme "$GNOME_SCHEME" 2>/dev/null || true
    gsettings set org.gnome.desktop.interface gtk-theme "$GTK_THEME_NAME" 2>/dev/null || true
    gsettings set org.gnome.desktop.interface icon-theme "$GTK_ICON_THEME" 2>/dev/null || true
    gsettings set org.gnome.desktop.interface cursor-theme "$CURSOR_THEME" 2>/dev/null || true
    gsettings set org.gnome.desktop.interface cursor-size "$CURSOR_SIZE" 2>/dev/null || true
fi

# ---------- Compositor cursor (live) ----------
# env = XCURSOR_THEME/HYPRCURSOR_THEME in the hypr config sets the boot-time
# theme; this updates the running compositor so Mod+N flips it without re-login.
if is_hyprland; then
    hyprctl setcursor "$CURSOR_THEME" "$CURSOR_SIZE" 2>/dev/null || true
fi

# ---------- Themed copies ----------
# Every surface that reads a fixed path instead of the mode-specific file; the
# list is theme-copies.sh's.
sync_theme_copies "$MODE"

# ---------- Reloads for the copies above ----------
# Only the surfaces with something running to tell — the rest re-read their file
# on every invocation, so for those the copy alone is the whole job.
pkill -SIGUSR1 -x kitty 2>/dev/null || true

# A toggle only ever changes colours here, so the cheap stylesheet reload is
# right: restarting would drop every queued notification on each Mod+N. An
# apply is the case that needs the daemon replaced, and post-apply.sh does that.
if pgrep -x swaync &>/dev/null; then
    swaync-client -rs 2>/dev/null || true
fi

if systemctl --user is-active --quiet swayosd-server.service 2>/dev/null; then
    systemctl --user restart swayosd-server.service 2>/dev/null || true
fi

# Waybar discovers the appearance via the portal color-scheme (set through
# gsettings above) and live-switches its stylesheet. The icon is a separate
# custom module with `interval: once`, though, so non-click callers such as the
# Mod+N keybind must explicitly ask it to rerun.
pkill -RTMIN+8 -x waybar 2>/dev/null || true

# ---------- Compositor group tabs ----------
# Group tabs are the one compositor colour that differs between modes (they
# mirror waybar's workspace pills, which have a light and a dark palette).
# Borders do not, and are set from conf/general.lua at parse time only.
#
# The palette is not repeated here: conf/theme.lua derives it from the state file
# — written above — and is loaded with dofile so this stays one `eval` and not a
# `hyprctl reload`. A reload would re-apply the whole config over the live
# session, reverting anything else set at runtime through `hyprctl eval`
# (toggle-monitors, toggle-hdr, toggle-all-opacity, toggle-workspace-scrolling).
# dofile rather than require: require would return the palette cached from
# before the flip. `hyprctl keyword` is not an option at all — Hyprland 0.55+
# rejects it on Lua configs ("non-legacy parsers").
if is_hyprland; then
    hyprctl eval 'local t = dofile(os.getenv("HOME") .. "/.config/hypr/conf/theme.lua").groupbar
        hl.config({ group = { groupbar = {
            ["col.active"] = t.active, ["col.inactive"] = t.inactive,
            text_color = t.text, text_color_inactive = t.text_dim,
        } } })' >/dev/null 2>&1 || true
fi

# ---------- Neovim ----------
NVIM_THEME_FILE="$HOME/.local/share/nvim-theme"
echo "$FLAVOR" > "$NVIM_THEME_FILE"
for addr in /run/user/$(id -u)/nvim.*.0 /tmp/nvim.*/0; do
    [ -S "$addr" ] || continue
    nvim --server "$addr" --remote-send "<Cmd>lua local c = require('catppuccin'); c.options.flavour = '${FLAVOR}'; c.compile(); vim.cmd.colorscheme('catppuccin')<CR>" 2>/dev/null || true
done

# ---------- Chezmoi templated configs ----------
if command -v chezmoi &>/dev/null; then
    chezmoi apply \
        ~/.gitconfig \
        ~/.config/ccstatusline/settings.json \
        ~/.config/gh-dash/config.yml \
        ~/.config/hunk/config.toml \
        ~/.config/starship.toml \
        ~/.config/tuicr/config.toml \
        ~/.config/yazi/theme.toml \
        ~/.local/share/rofi/themes/wallpaper.rasi \
        2>/dev/null || true
fi
