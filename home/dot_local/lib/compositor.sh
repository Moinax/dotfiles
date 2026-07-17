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
