# Keybinding Reference: Hyprland

> **Mod** = Super / Win key.
>
> Source file: `home/dot_config/hypr/conf/binds.conf` (or `binds.lua` on Hyprland ≥ 0.55)

---

## 1. Application Shortcuts

| Action | Keys | Notes |
|---|---|---|
| Open terminal (kitty) | `Mod+Return` | |
| Dev terminal (Zellij session) | `Mod+Alt+Return` | Rofi directory picker, then a persistent Zellij dev session (agent + nvim tabs) |
| App launcher (rofi) | `Mod+Space` | |
| Open browser (Helium) | `Mod+B` | Default browser |
| Open browser (Zen) | `Mod+Alt+B` | |
| Open browser (Chrome) | `Mod+Ctrl+B` | |
| File manager (Dolphin) | `Mod+E` | |
| Emoji selector | `Mod+I` | rofimoji (clipboard paste) |
| Switch audio output | `Mod+A` | |
| Switch keyboard layout | `Mod+K` | |
| Window switcher (rofi) | `Mod+Tab` | |
| Kill window (rofi) | `Mod+Escape` | Picks window like switcher, then `kill -9` |
| Clipboard (cliphist) | `Mod+V` | |
| Color picker (hyprpicker) | `Mod+Shift+P` | |
| Calculator (rofi-calc) | `Mod+C` | Quick inline calculator |
| Calculator (kcalc) | `Mod+Alt+C` | Full calculator app |
| Theme selector | `Mod+R` | rofi-theme-selector |
| Toggle monitor layout | `Mod+M` | |
| Toggle dictation (speech-to-text) | `Mod+D` | hyprvoice toggle (AI group only) |

## 2. Window Management

| Action | Keys | Notes |
|---|---|---|
| Close window | `Mod+Q` | |
| Toggle floating | `Mod+T` | |
| Fullscreen | `Mod+Alt+F` | |
| Maximize | `Mod+F` | |
| Pin window | `Mod+P` | Sticky across workspaces |

## 3. Focus Navigation

| Action | Keys | Notes |
|---|---|---|
| Focus left/right/up/down | `Mod+Arrows` | |
| Cycle prev window | `Mod+Shift+Tab` | |

## 4. Move Window / Column

| Action | Keys | Notes |
|---|---|---|
| Swap with neighbor / group | `Mod+Ctrl+Arrows` | Group-aware swap (in-group→out / adjacent-group→in / else→swap) |
| Move window (whole group as unit) | `Mod+Alt+Arrows` | `move({ direction = ... })` — moves the focused window or group container; crosses monitor at edge |

## 5. Resize

| Action | Keys | Notes |
|---|---|---|
| Resize right/left/up/down | `Mod+Shift+Arrows` | ±30px steps, repeats while held |

## 6. Column / Group Operations

| Action | Keys | Notes |
|---|---|---|
| Toggle group | `Mod+G` | togglegroup |
| Cycle group forward | `Alt+Tab` | changegroupactive |
| Cycle group backward | `Alt+Shift+Tab` | |
| Swap in group | `Alt+Ctrl+Tab` | movegroupwindow |
| Toggle split | `Mod+J` | togglesplit (dwindle layout) |

> **Scrolling layout**: when a workspace is flipped to `scrolling` (via `Mod+Alt+T`), the standard arrow binds above (focus / movewindow / group-swap / resize) all work — Hyprland routes them through the active layout. Column-stacking ops (consume/expel/promote) and viewport pan are not bound.

## 7. Workspace Navigation

| Action | Keys | Notes |
|---|---|---|
| Workspace 1–7 (QWERTY) | `Mod+1` .. `Mod+7` | |
| Workspace 1–7 (AZERTY) | `Mod+&` .. `Mod+è` | |
| Focus workspace up | `Mod+Page_Up` | `workspace r-1` (cycles rule-defined WS on current monitor, incl. empty) |
| Focus workspace down | `Mod+Page_Down` | `workspace r+1` |
| Focus next workspace (mouse) | `Mod+WheelUp` | Wheel inverted vs page keys (`r+1` on scroll up, natural-scroll feel) |
| Focus prev workspace (mouse) | `Mod+WheelDown` | `r-1` on scroll down |

## 8. Move to Workspace

> **Convention**: `Alt` = move with focus follow, `Ctrl` = silent move (window goes, focus stays). `Shift` is reserved for less common actions (reload configs, etc.).

| Action | Keys | Notes |
|---|---|---|
| Move to WS 1–7 (follow) | `Mod+Alt+1` .. `Mod+Alt+7` | AZERTY: `Mod+Alt+&` .. `Mod+Alt+è` |
| Silent move to WS 1–7 | `Mod+Ctrl+1` .. `Mod+Ctrl+7` | AZERTY: `Mod+Ctrl+&` .. `Mod+Ctrl+è` |
| Move window to WS up (follow) | `Mod+Alt+Page_Up` | `movetoworkspace r-1` |
| Move window to WS down (follow) | `Mod+Alt+Page_Down` | `movetoworkspace r+1` |
| Silent move to WS up | `Mod+Ctrl+Page_Up` | `movetoworkspacesilent r-1` |
| Silent move to WS down | `Mod+Ctrl+Page_Down` | `movetoworkspacesilent r+1` |
| Move to next WS (mouse, follow) | `Mod+Alt+WheelUp` | `movetoworkspace r+1` (wheel inverted vs page keys) |
| Move to prev WS (mouse, follow) | `Mod+Alt+WheelDown` | `movetoworkspace r-1` |
| Silent move to next WS (mouse) | `Mod+Ctrl+WheelUp` | `movetoworkspacesilent r+1` |
| Silent move to prev WS (mouse) | `Mod+Ctrl+WheelDown` | `movetoworkspacesilent r-1` |

## 9. Scratchpad

| Action | Keys | Notes |
|---|---|---|
| Toggle scratchpad | `Mod+S` | Special workspace |
| Move to scratchpad | `Mod+Alt+S` | |
| Move to scratchpad (silent) | `Mod+Ctrl+S` | |

## 10. Reload Configs

| Action | Keys | Notes |
|---|---|---|
| Reload Waybar | `Mod+Shift+B` | |
| Wallpaper picker (rofi) | `Mod+Shift+W` | Picks from `~/Wallpapers/`, applies via awww |
| Reload SwayNC | `Mod+Shift+M` | `swaync-client -R && swaync-client -rs` |
| Reload compositor | `Mod+Shift+R` | |

## 11. Screenshots

| Action | Keys | Notes |
|---|---|---|
| Screenshot monitor | `Print` | hyprshot monitor |
| Screenshot window | `Mod+Print` | hyprshot window |
| Screenshot region | `Mod+Shift+Print` | hyprshot region |

## 12. Media & Volume

| Action | Keys | Notes |
|---|---|---|
| Volume up / down | `XF86AudioRaiseVolume` / `XF86AudioLowerVolume` | swayosd-client OSD |
| Mute toggle | `XF86AudioMute` | swayosd-client OSD |
| Mic mute | `XF86AudioMicMute` | swayosd-client OSD |
| Brightness up / down | `XF86MonBrightnessUp` / `XF86MonBrightnessDown` | swayosd-client OSD |

## 13. Session & System

| Action | Keys | Notes |
|---|---|---|
| Power menu (wlogout) | `Mod+L` | Centered vertical list with keybind hints |
| Lock screen | `Mod+Alt+L` | `loginctl lock-session` |
| Suspend | `Mod+Ctrl+L` | `systemctl suspend` |
| Logout | `Mod+Shift+L` | `compositor-logout.sh` |
| Toggle dark/light mode | `Mod+N` | Switches Catppuccin Mocha/Latte + portal |
| Toggle caffeine mode | `Mod+Alt+N` | Inhibits idle (prevents lock/sleep) |
| Toggle Tailscale VPN | `Mod+Ctrl+N` | Connect/disconnect Tailscale |
| Quit compositor | `Mod+Shift+Q` | |
| Lock + screen off | `Mod+Alt+M` | Locks the session, then powers the screen off; wake by mouse/key, then unlock |
| Toggle HDR (10-bit) | `Mod+Alt+H` | Desktop only; flips DP-3 between SDR (default) and 10-bit HDR, reverts on reload |
| Keybinding help (rofi) | `Mod+H` | rofi-keybindings |
| Toggle notification center | `Mod+U` | `swaync-client -t` |
| Toggle DND | `Mod+Alt+U` | `swaync-client -d` |

## 14. Mouse

| Action | Keys | Notes |
|---|---|---|
| Mouse move window | `Mod+LMB` | |
| Mouse resize window | `Mod+RMB` | |

## 15. Opacity

| Action | Keys | Notes |
|---|---|---|
| Toggle full opacity | `Mod+O` | |
| Toggle half opacity | `Mod+Ctrl+O` | |
| Toggle global opacity on/off | `Mod+Alt+O` | Flips decoration opacity session-wide (Lua `eval`, legacy `keyword` fallback) |

## 16. Layout Switching

Hyprland uses `dwindle` as the default layout on every host.

| Action | Keys | Notes |
|---|---|---|
| Toggle workspace scrolling ↔ dwindle | `Mod+Alt+T` | Flips the active workspace into the `scrolling` (tape) layout or back to `dwindle`. State persisted to `~/.cache/hypr-ws-layout`. |
