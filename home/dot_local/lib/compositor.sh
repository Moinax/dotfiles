# shellcheck shell=sh
# Shared compositor-detection helpers for Wayland scripts.
# Source from ~/.local/bin/* scripts:
#   . "$HOME/.local/lib/compositor.sh"
#   if is_hyprland; then ...

is_hyprland() {
    [ "${XDG_CURRENT_DESKTOP:-}" = "Hyprland" ] \
        || [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] \
        || pgrep -x Hyprland >/dev/null
}

# Load KDED modules that a full Plasma session autoloads and a standalone
# Hyprland session does not — statusnotifierwatcher for the system tray,
# gtkconfig for the KDE→GTK appearance bridge.
#
# Shared for the same reason theme-copies.sh is: two callers need it (the waybar
# launcher at session start, apply-dark-mode before it changes the KDE scheme),
# and two copies of the incantation had already drifted apart — one guarded on
# dbus-send being present and the other did not. Idempotent by nature: loading a
# resident module is a no-op, which is what lets both callers ask without
# coordinating. Never fatal; a machine with no kded6 simply has no bridge.
kded_load_module() {
    command -v dbus-send >/dev/null 2>&1 || return 0
    for _kded_mod in "$@"; do
        dbus-send --session --print-reply --dest=org.kde.kded6 /kded \
            org.kde.kded6.loadModule "string:$_kded_mod" >/dev/null 2>&1 || true
    done
    unset _kded_mod
}
