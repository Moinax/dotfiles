# Keybinding Reference: Hyprland vs Niri

> **Mod** = Super / Win key. Entries marked with **—** are not available in that compositor.
>
> Source files:
> - Hyprland: `home/dot_config/hypr/conf/binds.conf`
> - Niri: `home/dot_config/niri/config.kdl.tmpl`

---

## 1. Application Shortcuts


| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Open terminal (kitty) | `Mod+Return` | `Mod+Return` | |
| Dev terminal (Zellij session) | `Mod+Alt+Return` | `Mod+Alt+Return` | Rofi directory picker, then a persistent Zellij dev session (agent + nvim tabs) |
| App launcher (rofi) | `Mod+Space` | `Mod+Space` | |
| Open browser (Helium) | `Mod+B` | `Mod+B` | Default browser |
| Open browser (Zen) | `Mod+Alt+B` | `Mod+Alt+B` | |
| Open browser (Chrome) | `Mod+Ctrl+B` | `Mod+Ctrl+B` | |
| File manager (Dolphin) | `Mod+E` | `Mod+E` | |
| Emoji selector | `Mod+I` | `Mod+I` | rofimoji (clipboard paste) |
| Switch audio output | `Mod+A` | `Mod+A` | |
| Switch keyboard layout | `Mod+K` | `Mod+K` | |
| Window switcher (rofi) | `Mod+Tab` | `Mod+Tab` | |
| Kill window (rofi) | `Mod+Escape` | `Mod+Escape` | Picks window like switcher, then `kill -9` |
| Clipboard (cliphist) | `Mod+V` | `Mod+V` | |
| Color picker (hyprpicker) | `Mod+Shift+P` | `Mod+Shift+P` | |
| Calculator (rofi-calc) | `Mod+C` | `Mod+C` | Quick inline calculator |
| Calculator (kcalc) | `Mod+Alt+C` | `Mod+Ctrl+Alt+C` | Full calculator app |
| Theme selector | `Mod+R` | `Mod+R` | rofi-theme-selector |
| Toggle monitor layout | `Mod+M` | `Mod+M` | |
| Toggle dictation (speech-to-text) | `Mod+D` | `Mod+D` | hyprvoice toggle (AI group only) |

## 2. Window Management

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Close window | `Mod+Q` | `Mod+Q` | |
| Toggle floating | `Mod+T` | `Mod+T` | |
| Fullscreen | `Mod+Alt+F` | `Mod+Alt+F` | |
| Maximize | `Mod+F` | `Mod+F` | |
| Pin window | `Mod+P` | — | Hyprland only (sticky across workspaces) |
| Overview | — | `Mod+Ctrl+O` | Niri only |
| Center column | — | `Mod+Alt+C` | Niri only |
| Center visible columns | — | `Mod+Ctrl+C` | Niri only |
| Maximize column | — | `Mod+Ctrl+M` | Niri only |
| Preset column widths | — | `Mod+W` | Niri only |
| Preset column widths (reverse) | — | `Mod+Alt+W` | Niri only (preset window heights) |
| Preset window heights | — | `Mod+Alt+W` | Niri only |
| Reset window height | — | `Mod+Ctrl+W` | Niri only |
| Switch float/tile focus | — | `Mod+P` | Niri only |

## 3. Focus Navigation

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Focus left | `Mod+Left` | `Mod+Left` | Niri: focus-column-left |
| Focus right | `Mod+Right` | `Mod+Right` | Niri: focus-column-right |
| Focus up | `Mod+Up` | `Mod+Up` | Niri: focus-window-up (within column) |
| Focus down | `Mod+Down` | `Mod+Down` | Niri: focus-window-down (within column) |
| Focus first column | — | `Mod+Home` | Niri only |
| Focus last column | — | `Mod+End` | Niri only |
| Cycle prev window | `Mod+Shift+Tab` | `Mod+Shift+Tab` | Niri: recent-windows previous-window |

## 4. Move Window / Column

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Swap with neighbor / group | `Mod+Ctrl+Left` | `Mod+Ctrl+Left` | Hyprland: group-aware swap (in-group→out / adjacent-group→in / else→swap); Niri: move-column-left |
| Swap with neighbor / group | `Mod+Ctrl+Right` | `Mod+Ctrl+Right` | Hyprland: group-aware swap; Niri: move-column-right |
| Swap with neighbor / group | `Mod+Ctrl+Up` | `Mod+Ctrl+Up` | Hyprland: group-aware swap; Niri: move-window-up |
| Swap with neighbor / group | `Mod+Ctrl+Down` | `Mod+Ctrl+Down` | Hyprland: group-aware swap; Niri: move-window-down |
| Move window (whole group as unit) | `Mod+Alt+Left` | `Mod+Alt+Left` | Hyprland: `move({ direction = "l" })` — moves the focused window or group container; crosses monitor at edge; Niri: swap-window-left |
| Move window (whole group as unit) | `Mod+Alt+Right` | `Mod+Alt+Right` | Hyprland: `move({ direction = "r" })`; Niri: swap-window-right |
| Move window (whole group as unit) | `Mod+Alt+Up` | — | Hyprland only; Niri uses `Mod+Alt+Up` for workspace move |
| Move window (whole group as unit) | `Mod+Alt+Down` | — | Hyprland only; Niri uses `Mod+Alt+Down` for workspace move |
| Move column to first | — | `Mod+Ctrl+Home` | Niri only |
| Move column to last | — | `Mod+Ctrl+End` | Niri only |

## 5. Resize

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Resize / widen right | `Mod+Shift+Right` | `Mod+Shift+Right` | Hyprland: +30px; Niri: +10% column width |
| Resize / narrow left | `Mod+Shift+Left` | `Mod+Shift+Left` | Hyprland: -30px; Niri: -10% column width |
| Resize / shrink up | `Mod+Shift+Up` | `Mod+Shift+Up` | Hyprland: -30px; Niri: -10% window height |
| Resize / grow down | `Mod+Shift+Down` | `Mod+Shift+Down` | Hyprland: +30px; Niri: +10% window height |

## 6. Column / Group Operations

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Consume into column | — | `Mod+J` | Niri only (consume-window-into-column) |
| Expel from column | — | `Mod+Shift+J` | Niri only (expel-window-from-column) |
| Toggle tabbed display | — | `Mod+G` | Niri: toggle-column-tabbed-display |
| Normal display | — | `Mod+Shift+G` | Niri: set-column-display "normal" |
| Toggle group | `Mod+G` | — | Hyprland only (togglegroup) |
| Cycle group forward | `Alt+Tab` | — | Hyprland only (changegroupactive) |
| Cycle group backward | `Alt+Shift+Tab` | — | Hyprland only |
| Swap in group | `Alt+Ctrl+Tab` | — | Hyprland only (movegroupwindow) |
| Toggle split | `Mod+J` | — | Hyprland only (togglesplit, dwindle layout) |

> **Scrolling layout**: when a workspace is flipped to `scrolling` (via `Mod+Alt+T`), the standard arrow binds above (focus / movewindow / group-swap / resize) all work — Hyprland routes them through the active layout. Column-stacking ops (consume/expel/promote) and viewport pan are not bound.

> **Key reuse**: `Mod+J` and `Mod+G` serve different but analogous purposes in each compositor.
> Hyprland: `J` = toggle split layout, `G` = toggle group.
> Niri: `J` = consume/expel column, `G` = toggle tabbed display.

## 7. Workspace Navigation

### By number (QWERTY)

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Workspace 1–7 | `Mod+1` .. `Mod+7` | `Mod+1` .. `Mod+7` | |

### By number (AZERTY)

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Workspace 1–7 | `Mod+&` .. `Mod+è` | `Mod+&` .. `Mod+è` | |

### Directional

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Focus workspace up | `Mod+Page_Up` | `Mod+Page_Up` | Hyprland: `workspace r-1` (cycles rule-defined WS on current monitor, incl. empty) |
| Focus workspace down | `Mod+Page_Down` | `Mod+Page_Down` | Hyprland: `workspace r+1` |
| Focus next workspace (mouse) | `Mod+WheelUp` | `Mod+WheelDown` | Hyprland wheel inverted vs page keys (`r+1` on scroll up); Niri throttles 150ms |
| Focus prev workspace (mouse) | `Mod+WheelDown` | `Mod+WheelUp` | Hyprland: `r-1` on scroll down |

## 8. Move to Workspace

> **Hyprland convention**: `Alt` = move with focus follow, `Ctrl` = silent move (window goes, focus stays). `Shift` is reserved for less common actions (reload configs, etc.).

### By number (QWERTY)

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Move to WS 1–7 (follow) | `Mod+Alt+1` .. `Mod+Alt+7` | `Mod+Shift+1` .. `Mod+Shift+7` | |
| Silent move to WS 1–7 | `Mod+Ctrl+1` .. `Mod+Ctrl+7` | — | Hyprland only (movetoworkspacesilent) |

### By number (AZERTY)

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Move to WS 1–7 (follow) | `Mod+Alt+&` .. `Mod+Alt+è` | `Mod+Shift+&` .. `Mod+Shift+è` | |
| Silent move to WS 1–7 | `Mod+Ctrl+&` .. `Mod+Ctrl+è` | — | Hyprland only |

### Directional

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Move window to WS up (follow) | `Mod+Alt+Page_Up` | `Mod+Shift+Page_Up` | Hyprland: `movetoworkspace r-1` |
| Move window to WS down (follow) | `Mod+Alt+Page_Down` | `Mod+Shift+Page_Down` | Hyprland: `movetoworkspace r+1` |
| Silent move to WS up | `Mod+Ctrl+Page_Up` | — | Hyprland: `movetoworkspacesilent r-1` |
| Silent move to WS down | `Mod+Ctrl+Page_Down` | — | Hyprland: `movetoworkspacesilent r+1` |
| Move to next WS (mouse, follow) | `Mod+Alt+WheelUp` | — | Hyprland: `movetoworkspace r+1` (wheel inverted vs page keys) |
| Move to prev WS (mouse, follow) | `Mod+Alt+WheelDown` | — | Hyprland: `movetoworkspace r-1` |
| Silent move to next WS (mouse) | `Mod+Ctrl+WheelUp` | `Mod+Ctrl+WheelDown` | Hyprland: `movetoworkspacesilent r+1` |
| Silent move to prev WS (mouse) | `Mod+Ctrl+WheelDown` | `Mod+Ctrl+WheelUp` | Hyprland: `movetoworkspacesilent r-1` |
| Reorder workspace up | — | `Mod+Alt+Page_Up` | Niri only (key shadowed on Hyprland by follow-move) |
| Reorder workspace down | — | `Mod+Alt+Page_Down` | Niri only |

## 9. Monitor Navigation

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Focus monitor left | — | `Mod+Alt+Comma` | Niri only |
| Focus monitor right | — | `Mod+Alt+Period` | Niri only |
| Move column to monitor left | — | `Mod+Alt+Ctrl+Left` | Niri only |
| Move column to monitor right | — | `Mod+Alt+Ctrl+Right` | Niri only |
| Move column to monitor up | — | `Mod+Alt+Ctrl+Up` | Niri only |
| Move column to monitor down | — | `Mod+Alt+Ctrl+Down` | Niri only |

## 10. Scratchpad

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Toggle scratchpad | `Mod+S` | — | Hyprland only (special workspace) |
| Move to scratchpad | `Mod+Alt+S` | — | Hyprland only |
| Move to scratchpad (silent) | `Mod+Ctrl+S` | — | Hyprland only |

## 11. Reload Configs

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Reload Waybar | `Mod+Shift+B` | `Mod+Shift+B` | |
| Wallpaper picker (rofi) | `Mod+Shift+W` | `Mod+Shift+W` | Picks from `~/Wallpapers/`, applies via awww (Arch) / swww (Fedora) |
| Reload SwayNC | `Mod+Shift+M` | `Mod+Shift+M` | `swaync-client -R && swaync-client -rs` |
| Reload compositor | `Mod+Shift+R` | `Mod+Shift+R` | |

## 12. Screenshots

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Screenshot monitor | `Print` | `Print` | Hyprland: hyprshot monitor; Niri: screenshot-screen |
| Screenshot window | `Mod+Print` | `Mod+Print` | Hyprland: hyprshot window; Niri: screenshot-window |
| Screenshot region | `Mod+Shift+Print` | `Mod+Shift+Print` | Hyprland: hyprshot region; Niri: built-in screenshot |

## 13. Media & Volume

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Volume up | `XF86AudioRaiseVolume` | `XF86AudioRaiseVolume` | swayosd-client OSD |
| Volume down | `XF86AudioLowerVolume` | `XF86AudioLowerVolume` | swayosd-client OSD |
| Mute toggle | `XF86AudioMute` | `XF86AudioMute` | swayosd-client OSD |
| Mic mute | `XF86AudioMicMute` | `XF86AudioMicMute` | swayosd-client OSD |
| Play / Pause | — | `XF86AudioPlay` | Niri only (playerctl) |
| Stop | — | `XF86AudioStop` | Niri only (playerctl) |
| Previous track | — | `XF86AudioPrev` | Niri only (playerctl) |
| Next track | — | `XF86AudioNext` | Niri only (playerctl) |
| Brightness up | `XF86MonBrightnessUp` | `XF86MonBrightnessUp` | swayosd-client OSD |
| Brightness down | `XF86MonBrightnessDown` | `XF86MonBrightnessDown` | swayosd-client OSD |

## 14. Session & System

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Power menu (wlogout) | `Mod+L` | `Mod+L` | Centered vertical list with keybind hints |
| Lock screen | `Mod+Alt+L` | `Mod+Alt+L` | `loginctl lock-session` |
| Suspend | `Mod+Ctrl+L` | `Mod+Ctrl+L` | `systemctl suspend` |
| Logout | `Mod+Shift+L` | `Mod+Shift+L` | `compositor-logout.sh` |
| Toggle dark/light mode | `Mod+N` | `Mod+N` | Switches Catppuccin Mocha/Latte + portal |
| Toggle caffeine mode | `Mod+Alt+N` | `Mod+Alt+N` | Inhibits idle (prevents lock/sleep) |
| Toggle Tailscale VPN | `Mod+Ctrl+N` | `Mod+Ctrl+N` | Connect/disconnect Tailscale |
| Quit compositor | `Mod+Shift+Q` | `Mod+Shift+Q` | |
| Quit (alt) | — | `Ctrl+Alt+Delete` | Niri only |
| Lock + screen off | `Mod+Alt+M` | `Mod+Alt+M` | Locks the session, then powers the screen off; wake by mouse/key, then unlock |
| Toggle HDR (10-bit) | `Mod+Alt+H` | — | Desktop only; flips DP-3 between SDR (default) and 10-bit HDR, reverts on reload |
| Keybinding help (rofi) | `Mod+H` | `Mod+H` | rofi-keybindings |
| Toggle notification center | `Mod+U` | `Mod+U` | `swaync-client -t` |
| Toggle DND | `Mod+Alt+U` | `Mod+Alt+U` | `swaync-client -d` |

## 15. Mouse & Scroll

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Mouse move window | `Mod+LMB` | — | Hyprland only |
| Mouse resize window | `Mod+RMB` | — | Hyprland only |
| Scroll workspace down | — | `Mod+WheelDown` | Niri only (cooldown 150ms) |
| Scroll workspace up | — | `Mod+WheelUp` | Niri only |
| Scroll move to WS down | — | `Mod+Ctrl+WheelDown` | Niri only |
| Scroll move to WS up | — | `Mod+Ctrl+WheelUp` | Niri only |
| Scroll focus column right | — | `Mod+WheelRight` | Niri only |
| Scroll focus column left | — | `Mod+WheelLeft` | Niri only |
| Scroll move column right | — | `Mod+Ctrl+WheelRight` | Niri only |
| Scroll move column left | — | `Mod+Ctrl+WheelLeft` | Niri only |
| Shift+Scroll focus right | — | `Mod+Shift+WheelDown` | Niri only (alt for horizontal) |
| Shift+Scroll focus left | — | `Mod+Shift+WheelUp` | Niri only |
| Shift+Scroll move right | — | `Mod+Ctrl+Shift+WheelDown` | Niri only |
| Shift+Scroll move left | — | `Mod+Ctrl+Shift+WheelUp` | Niri only |

## 16. Opacity

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Toggle full opacity | `Mod+O` | `Mod+O` | Niri: toggle-window-rule-opacity |
| Toggle half opacity | `Mod+Ctrl+O` | — | Hyprland only |
| Toggle global opacity on/off | `Mod+Alt+O` | — | Hyprland: flips decoration opacity session-wide (Lua `eval`, legacy `keyword` fallback) |
| Focused opacity baseline | — | *(window rule: 0.99)* | Needed for Niri opacity toggle |
| Unfocused opacity | — | *(window rule: 0.90)* | Niri uses automatic window rules |

## 17. Layout Switching (Hyprland only)

Hyprland uses `dwindle` as the default layout on every host.

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Toggle workspace scrolling ↔ dwindle | `Mod+Alt+T` | — | Flips the active workspace into the `scrolling` (Niri-style tape) layout or back to `dwindle`. State persisted to `~/.cache/hypr-ws-layout`. |

---

## Quick Reference: Key Conflicts

Keys that do **different things** in each compositor:

| Key | Hyprland | Niri |
|---|---|---|
| `Mod+G` | Toggle group | Tabbed column display |
| `Mod+J` | Toggle split (dwindle) | Consume into column |
| `Mod+Alt+Up/Down` | Swap window | Workspace reorder |
| `Mod+Alt+T` | Toggle workspace scrolling ↔ baseline | *(unbound)* |
