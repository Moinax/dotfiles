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
| App launcher (rofi) | `Mod+Space` | `Mod+Space` | |
| Open browser (Chrome) | `Mod+B` | `Mod+B` | |
| File manager (Dolphin) | `Mod+E` | `Mod+E` | |
| Emoji selector | `Mod+I` | `Mod+I` | |
| Switch audio output | `Mod+A` | `Mod+A` | |
| Switch keyboard layout | `Mod+K` | `Mod+K` | |
| Window switcher (rofi) | `Mod+Tab` | `Mod+Tab` | |
| Clipboard (cliphist) | `Mod+V` | `Mod+V` | |
| Color picker (hyprpicker) | `Mod+Shift+P` | `Mod+Shift+P` | |
| Calculator | `Mod+C` | `Mod+C` | |
| Theme selector | `Mod+R` | `Mod+R` | rofi-theme-selector |
| Toggle monitor layout | `Mod+M` | `Mod+M` | |
| Toggle dictation (speech-to-text) | `Mod+D` | `Mod+D` | hyprvoice toggle |

## 2. Window Management

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Close window | `Mod+Q` | `Mod+Q` | |
| Toggle floating | `Mod+T` | `Mod+T` | |
| Fullscreen | `Mod+F` | `Mod+F` | |
| Maximize | `Mod+Alt+F` | `Mod+Alt+F` | |
| Pin window | `Mod+P` | — | Hyprland only (sticky across workspaces) |
| Overview | — | `Mod+O` | Niri only; Hyprland uses `Mod+O` for opacity |
| Center column | — | `Mod+Alt+C` | Niri only |
| Center visible columns | — | `Mod+Ctrl+C` | Niri only |
| Maximize column | — | `Mod+Alt+M` | Niri only |
| Preset column widths | — | `Mod+W` | Niri only (cycles through preset widths) |
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
| Cycle prev window | `Mod+Shift+Tab` | — | Hyprland only |

## 4. Move Window / Column

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Move left | `Mod+Ctrl+Left` | `Mod+Ctrl+Left` | Hyprland: movewindoworgroup; Niri: move-column-left |
| Move right | `Mod+Ctrl+Right` | `Mod+Ctrl+Right` | Hyprland: movewindoworgroup; Niri: move-column-right |
| Move up | `Mod+Ctrl+Up` | `Mod+Ctrl+Up` | Hyprland: movewindoworgroup; Niri: move-window-up |
| Move down | `Mod+Ctrl+Down` | `Mod+Ctrl+Down` | Hyprland: movewindoworgroup; Niri: move-window-down |
| Swap window left | `Mod+Alt+Left` | — | Hyprland only; Niri uses `Mod+Alt+Left` for focus monitor |
| Swap window right | `Mod+Alt+Right` | — | Hyprland only; Niri uses `Mod+Alt+Right` for focus monitor |
| Swap window up | `Mod+Alt+Up` | — | Hyprland only; Niri uses `Mod+Alt+Up` for workspace move |
| Swap window down | `Mod+Alt+Down` | — | Hyprland only; Niri uses `Mod+Alt+Down` for workspace move |
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
| Consume into column | — | `Mod+J` | Niri only; Hyprland uses `Mod+J` for toggle split (layoutmsg togglesplit) |
| Expel from column | — | `Mod+Shift+J` | Niri only |
| Toggle tabbed display | — | `Mod+G` | Niri: set-column-display "tabbed" |
| Normal display | — | `Mod+Shift+G` | Niri: set-column-display "normal" |
| Toggle group | `Mod+G` | — | Hyprland only (togglegroup) |
| Cycle group forward | `Alt+Tab` | — | Hyprland only (changegroupactive) |
| Cycle group backward | `Alt+Shift+Tab` | — | Hyprland only |
| Swap in group | `Alt+Ctrl+Tab` | — | Hyprland only (movegroupwindow) |
| Toggle split | `Mod+J` | — | Hyprland only (togglesplit) |

> **Key reuse**: `Mod+J` and `Mod+G` serve different but analogous purposes in each compositor.
> Hyprland: `J` = toggle split layout, `G` = toggle group.
> Niri: `J` = consume/expel column, `G` = tabbed/normal display.

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
| Focus workspace up | — | `Mod+Page_Up` | Niri only |
| Focus workspace down | — | `Mod+Page_Down` | Niri only |

## 8. Move to Workspace

### By number (QWERTY)

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Move to WS 1–7 | `Mod+Shift+1` .. `Mod+Shift+7` | `Mod+Shift+1` .. `Mod+Shift+7` | |

### By number (AZERTY)

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Move to WS 1–7 | `Mod+Shift+&` .. `Mod+Shift+è` | `Mod+Shift+&` .. `Mod+Shift+è` | |

### Silent move (AZERTY)

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Silent move to WS 1–7 | `Mod+Ctrl+&` .. `Mod+Ctrl+è` | — | Hyprland only (movetoworkspacesilent) |

### Directional

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Move column to WS up | — | `Mod+Shift+Page_Up` | Niri only |
| Move column to WS down | — | `Mod+Shift+Page_Down` | Niri only |
| Reorder workspace up | — | `Mod+Alt+Page_Up` | Niri only (move-workspace-up) |
| Reorder workspace down | — | `Mod+Alt+Page_Down` | Niri only (move-workspace-down) |

## 9. Monitor Navigation

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Focus monitor left | — | `Mod+Alt+Left` | Niri only; Hyprland uses `Mod+Alt+Left` for swap |
| Focus monitor right | — | `Mod+Alt+Right` | Niri only; Hyprland uses `Mod+Alt+Right` for swap |
| Move column to monitor left | — | `Mod+Alt+Ctrl+Left` | Niri only |
| Move column to monitor right | — | `Mod+Alt+Ctrl+Right` | Niri only |
| Move column to monitor up | — | `Mod+Alt+Ctrl+Up` | Niri only |
| Move column to monitor down | — | `Mod+Alt+Ctrl+Down` | Niri only |

## 10. Scratchpad

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Toggle scratchpad | `Mod+S` | — | Hyprland only (special workspace) |
| Move to scratchpad | `Mod+Shift+S` | — | Hyprland only |
| Move to scratchpad (silent) | `Mod+Ctrl+S` | — | Hyprland only |

## 11. Reload Configs

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Reload Waybar | `Mod+Shift+B` | `Mod+Shift+B` | |
| Reload wallpaper | `Mod+Shift+W` | `Mod+Shift+W` | Hyprland: hyprpaper; Niri: swaybg |
| Reload Mako | `Mod+Shift+M` | `Mod+Shift+M` | |
| Reload compositor | `Mod+Shift+R` | `Mod+Shift+R` | |

## 12. Screenshots

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Screenshot monitor | `Print` | `Print` | Hyprland: hyprshot monitor; Niri: screenshot-screen |
| Screenshot window | `Mod+Print` | — | Hyprland only (hyprshot window) |
| Screenshot region | `Mod+Shift+Print` | `Mod+Shift+Print` | Hyprland: hyprshot region; Niri: built-in screenshot |

## 13. Media & Volume

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Volume up | `XF86AudioRaiseVolume` | `XF86AudioRaiseVolume` | Hyprland: custom script; Niri: wpctl |
| Volume down | `XF86AudioLowerVolume` | `XF86AudioLowerVolume` | Hyprland: custom script; Niri: wpctl |
| Mute toggle | `XF86AudioMute` | `XF86AudioMute` | Hyprland: custom script; Niri: wpctl |
| Mic mute | — | `XF86AudioMicMute` | Niri only |
| Play / Pause | — | `XF86AudioPlay` | Niri only (playerctl) |
| Stop | — | `XF86AudioStop` | Niri only (playerctl) |
| Previous track | — | `XF86AudioPrev` | Niri only (playerctl) |
| Next track | — | `XF86AudioNext` | Niri only (playerctl) |
| Brightness up | — | `XF86MonBrightnessUp` | Niri only (brightnessctl) |
| Brightness down | — | `XF86MonBrightnessDown` | Niri only (brightnessctl) |

## 14. Session & System

| Action | Hyprland | Niri | Notes |
|---|---|---|---|
| Power menu (wlogout) | `Mod+L` | `Mod+L` | Full-screen overlay with 6 buttons |
| Power menu (rofi) | `Mod+Shift+L` | `Mod+Shift+L` | Text-based fallback |
| Lock screen | `Mod+Alt+L` | `Mod+Alt+L` | `loginctl lock-session` |
| Logout | `Mod+Ctrl+L` | `Mod+Ctrl+L` | `compositor-logout.sh` |
| Quit compositor | `Mod+Shift+Q` | `Mod+Shift+E` | **Different key** |
| Quit (alt) | — | `Ctrl+Alt+Delete` | Niri only |
| Power off monitors | — | `Mod+Alt+P` | Niri only |
| Keyboard shortcut inhibit | — | `Mod+Escape` | Niri only (toggle-keyboard-shortcuts-inhibit) |
| Help / hotkey overlay | — | `Mod+H` | Niri only (show-hotkey-overlay) |

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
| Toggle full opacity | `Mod+O` | — | Hyprland only; Niri uses `Mod+O` for overview |
| Toggle half opacity | `Mod+Shift+O` | — | Hyprland only |
| Unfocused opacity | — | *(window rule: 0.85)* | Niri uses automatic window rules |

---

## Quick Reference: Key Conflicts

Keys that do **different things** in each compositor:

| Key | Hyprland | Niri |
|---|---|---|
| `Mod+G` | Toggle group | Tabbed column display |
| `Mod+J` | Toggle split | Consume into column |
| `Mod+O` | Toggle opacity | Toggle overview |
| `Mod+Alt+Left/Right` | Swap window | Focus monitor |
| `Mod+Shift+Q` | Quit Hyprland | *(unbound)* |
| `Mod+Shift+E` | *(unbound)* | Quit Niri |
