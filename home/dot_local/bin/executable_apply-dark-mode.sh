#!/bin/bash

# Dark/Light mode dispatcher
# Usage: apply-dark-mode.sh [dark|light]
# If no argument given, reads from state file (defaults to dark)
#
# Design: KDE/Qt is the canonical source of truth for dark/light mode.
# plasma-apply-colorscheme updates the system appearance and the KDE Settings
# portal publishes it to applications. kde-gtk-config mirrors the same KDE
# settings into GTK's settings.ini, GSettings and Wayland XSettings surfaces.

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
KDE_ICON_THEME=$( [ "$MODE" = "dark" ] && echo "breeze-dark" || echo "breeze" )

# Without the bridge loaded, kde-gtk-config's generated settings.ini/colors.css
# stay frozen at the mode from the last Plasma session. Asked for here rather
# than assumed from session start, because the load has to precede the scheme
# change below for the module to see it and every change after it.
kded_load_module gtkconfig

if command -v plasma-apply-colorscheme &>/dev/null; then
    plasma-apply-colorscheme "$KDE_SCHEME" 2>/dev/null || true
fi

# Color schemes do not select an icon theme. Keep the KDE value in step too;
# --notify is important because kde-gtk-config listens through KConfigWatcher
# and then propagates the change to GTK and running Qt applications.
if command -v kwriteconfig6 &>/dev/null; then
    kwriteconfig6 --file kdeglobals --group Icons --key Theme --notify \
        "$KDE_ICON_THEME" 2>/dev/null || true
fi

# ---------- GTK / GNOME appearance ----------
# kde-gtk-config is the primary bridge and updates GTK's settings.ini, CSS,
# GSettings and XSettings. Keep these GSettings writes for GLib consumers which
# read org.gnome.desktop.interface directly, and as a fallback on a machine
# without that package (the hyprland group declares it, so that is now only a
# machine set up before it did).
#
# The gtk-theme write is the exception and happens at the very end of this
# script instead, once the bridge has rewritten the GTK colours — see the
# "Late GTK theme write" section for why every Electron app depended on it.
GNOME_SCHEME=$( [ "$MODE" = "dark" ] && echo "prefer-dark" || echo "prefer-light" )
# The theme *name* carries the mode, rather than leaving Breeze in both modes and
# relying on the scheme: GTK3 does not read org.gnome.desktop.interface color-scheme
# at all — it needs gtk-application-prefer-dark-theme from settings.ini, which only
# the bridge writes. Pinning Breeze therefore left GTK3 apps light in dark mode
# wherever the bridge is absent or kded is not running, which is exactly the
# fallback this block claims to be. breeze-gtk (base.yaml) ships both names.
GTK_THEME_NAME=$( [ "$MODE" = "dark" ] && echo "Breeze-Dark" || echo "Breeze" )
# Cursor tone is inverted relative to background: white-toned cursor on
# dark mode, black-toned on light mode (Catppuccin's -light/-dark suffix
# names the cursor color, NOT the palette it pairs with).
CURSOR_TONE=$( [ "$MODE" = "dark" ] && echo "dark" || echo "light" )
CURSOR_THEME="catppuccin-${FLAVOR}-${CURSOR_TONE}-cursors"
CURSOR_SIZE=24
# KDE's copy of the cursor theme has to move too, and before the GSettings write
# below. With the bridge loaded, kde-gtk-config mirrors kcminputrc's cursorTheme
# into settings.ini and GSettings, so leaving KDE on its old value meant KDE won and
# the cursor stopped inverting with the mode — the bridge overwrote the two writes
# below within the same run. Setting the source it reads makes them agree instead.
if command -v kwriteconfig6 &>/dev/null; then
    kwriteconfig6 --file kcminputrc --group Mouse --key cursorTheme --notify \
        "$CURSOR_THEME" 2>/dev/null || true
    kwriteconfig6 --file kcminputrc --group Mouse --key cursorSize --notify \
        "$CURSOR_SIZE" 2>/dev/null || true
fi
if command -v gsettings &>/dev/null; then
    gsettings set org.gnome.desktop.interface color-scheme "$GNOME_SCHEME" 2>/dev/null || true
    gsettings set org.gnome.desktop.interface icon-theme "$KDE_ICON_THEME" 2>/dev/null || true
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

# zellij holds its colours per *server*, and a server reads config.kdl only at
# boot — so the terminal is the one surface a copy cannot reach. It names both
# halves instead (theme_dark / theme_light in config.kdl) and switches a live
# session between them on command, which is what this is. Per session, because
# `zellij action` with no `-s` needs a session in the environment and there is
# none out here.
#
# `list-sessions -s` also lists the dead-but-resurrectable ones, so the long
# form is parsed instead: a resurrected session re-reads the config anyway, and
# talking to one that is not running just prints an error per Mod+N.
if command -v zellij >/dev/null 2>&1; then
    zellij list-sessions --no-formatting 2>/dev/null \
        | awk '!/\(EXITED/ { print $1 }' \
        | while IFS= read -r session; do
            zellij -s "$session" action "set-$MODE-theme" 2>/dev/null || true
        done
fi

# A toggle only ever changes colours here, so the cheap stylesheet reload is
# right: restarting would drop every queued notification on each Mod+N. An
# apply is the case that needs the daemon replaced, and post-apply.sh does that.
if pgrep -x swaync &>/dev/null; then
    swaync-client -rs 2>/dev/null || true
fi

if systemctl --user is-active --quiet swayosd-server.service 2>/dev/null; then
    systemctl --user restart swayosd-server.service 2>/dev/null || true
fi

# Vicinae is not driven from here, and deliberately so. Its config maps a theme
# to each system appearance — theme.light.name / theme.dark.name in
# ~/.config/vicinae/moinax.json — and it follows the KDE portal's colour-scheme,
# which this script has already flipped above. It is the same arrangement as
# Waybar's, one layer down: set the appearance, let the app pick its own side.
#
# Calling `vicinae theme set` here would be worse than redundant. That command
# writes whichever half of the mapping matches the appearance vicinae believes
# is current, and at this point in the script vicinae may not have seen the
# portal change yet — so a dark toggle could land "catppuccin-mocha" in the
# *light* slot and quietly corrupt the mapping.

# Waybar is not driven from here either: it discovers the appearance via the
# portal color-scheme (set through gsettings above) and live-switches its
# stylesheet, and its dark-mode icon is a continuous module watching the same
# portal signal — waybar-dark-mode.sh. It used to be `interval: once` refreshed
# by an RTMIN+8 poke from here, which meant the icon followed *this script*
# rather than the appearance, and stayed stale for anything else that flipped it.

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
        ~/.config/btop/btop.conf \
        ~/.config/ccstatusline/settings.json \
        ~/.config/gh-dash/config.yml \
        ~/.config/hunk/config.toml \
        ~/.config/starship.toml \
        ~/.config/tuicr/config.toml \
        ~/.config/yazi/theme.toml \
        2>/dev/null || true
fi

# ---------- Late GTK theme write (Electron/Chromium) ----------
# Chromium, so every Electron app, recomputes shouldUseDarkColors when GTK
# announces a theme change — but it computes it by sampling the GTK colours,
# not by reading the portal value that woke it up. kde-gtk-config rewrites
# those colours about half a second after the scheme flip, so a gtk-theme write
# issued next to the flip has Chromium sample the *previous* mode's palette and
# cache it until the next notification: with two modes that is not a lag, it is
# a permanent inversion. Every Electron window sat one Mod+N behind, which is
# exactly how it was found.
#
# So this write, and only this one of the GSettings block above, waits for the
# colours to land first — and it is last in the script, because nothing else
# has any reason to queue behind an Electron quirk. The name has to really
# change for GSettings to signal at all, and it does: Breeze and Breeze-Dark
# alternate.
#
# What it waits on is the bridge's own settings.ini agreeing with $MODE, not
# an mtime: the mode is written in the same pass as the colours, so a rewrite
# triggered by something else — `kded_load_module gtkconfig` above fires one on
# the first toggle of a session — cannot be mistaken for this one. It also
# makes re-applying the mode already in force free, which is the login path.
GTK_SETTINGS_FILE="$HOME/.config/gtk-3.0/settings.ini"
GTK_PREFER_DARK=$( [ "$MODE" = "dark" ] && echo "true" || echo "false" )
if command -v gsettings &>/dev/null; then
    for ((i = 0; i < 30; i++)); do
        [ -f "$GTK_SETTINGS_FILE" ] || break
        grep -qx "gtk-application-prefer-dark-theme=$GTK_PREFER_DARK" \
            "$GTK_SETTINGS_FILE" && break
        sleep 0.1
    done
    # The rewrite is the file; GTK still has to notice it and reload.
    sleep 0.5
    gsettings set org.gnome.desktop.interface gtk-theme "$GTK_THEME_NAME" 2>/dev/null || true
fi
