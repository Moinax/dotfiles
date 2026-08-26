# Keybinding Reference: Hyprland

> **Mod** = Super / Win key.
>
> Source file: `home/dot_config/hypr/conf/binds.lua.tmpl`
>
> Letter shortcuts and workspace-number shortcuts use **physical AZERTY
> positions**. Their labels below are the French/Belgian legends: switching the
> active layout to US changes what applications type, but every Hyprland
> shortcut stays under the same fingers.

---

## 1. Application Shortcuts

| Action | Keys | Notes |
|---|---|---|
| Open terminal | `Mod+Return` | Plain kitty, a new window every press. The persistent `main` zellij session is no longer on this key — the Dev project picker below lands in it, and `term` still raises it from a shell |
| T3 Code | `Mod+Ctrl+Return` | Vicinae project picker for T3 Code, split into the projects it already knows (with their thread, running and blocked counts) and the rest of the disk. **Enter** opens a project's threads, registering the project with T3 Code first if it has never seen it. There, **Enter** on a thread opens it in the app and raises the window; typing a name and pressing **Enter** on the create row opens a new thread with that title, on the project's default model. `t3-thread` is the helper behind all of it |
| Dev project (zellij) | `Mod+Alt+Return` | Vicinae project picker (worktrees and non-repo directories filtered out), with the selected project's branch, working-tree state and worktree count in the side panel. **Enter** opens the project as a tab in the `main` zellij session (creating it if this is the first time) and focuses the terminal. **Shift+Enter** pushes the worktree picker (`wts`), grouped into worktrees / local branches / origin-only branches with each branch's last commit — select to reopen, type an unknown name to get a "Create branch" row. Either way it lands in the same `main` session, as a tab named `<project>.<branch>`. Zellij alone owns the tabs: `Ctrl+Shift+T` creates one, `Ctrl+T` then `X` closes it, `Ctrl+Tab` / `Ctrl+Shift+Tab` cycle, `Ctrl+T` then `R` renames, and `Alt+1..9` jumps directly. Closing the window detaches without killing the session; the keybind legend is zellij's own status bar |
| Launcher (vicinae) | `Mod+Space` | Apps, files, window switching, snippets — and arithmetic/unit/currency conversion inline as you type. Second press closes it |
| Open default browser | `Mod+B` | Launches the system default web browser |
| Pick browser | `Mod+Alt+B` | Vicinae list of installed browsers (freedesktop `Categories=WebBrowser` scan, no hardcoded list); the system default is marked |
| File manager (Dolphin) | `Mod+E` | |
| Open every chat app | `Mod+C` | `chats` — opens the four and tabs them in pairs; refuses if any is already up, since it only cold-starts. Where they land is per host: on `moinax-desktop` the `windowrules.lua` slots on DP-2, without following them; anywhere else the first empty workspace, tiled, and the focus does follow |
| Pick chat app | `Mod+Alt+C` | Vicinae list of installed chat apps (freedesktop `Categories=InstantMessaging` scan, same crawl as the browser one) — one app, where `Mod+C` opens all of them. On `moinax-desktop` the window rules send it to its slot on DP-2 whichever workspace you were on, and `silent` means the launch is not followed |
| Emoji & symbol picker | `Mod+I` | Vicinae built-in |
| Switch audio output | `Mod+A` | Vicinae sink picker; the current default is marked, and picking is by sink name rather than by matching a description substring |
| Switch keyboard layout | `Mod+K` | Vicinae list of `input-layouts/` entries; the active XKB group is marked |
| Window switcher (vicinae) | `Mod+Tab` | Vicinae built-in |
| Close / kill window | `Mod+Escape` | Enter asks the window to close through the compositor (its normal shutdown path); `Ctrl+Shift+Enter` is `SIGKILL` for the ones that ignore it. The list refreshes in place instead of closing |
| Clipboard history | `Mod+V` | Vicinae built-in (encrypted store, text and images) |
| Color picker (hyprpicker) | `Mod+Shift+P` | |
| Theme selector | Search `theme` in Vicinae | `Mod+N` switches the whole desktop dark/light and moves vicinae with it |
| Toggle monitors | `Mod+M` | Vicinae list of outputs with their mode and on/off state; one toggle per action, refuses to disable the last active output |
| Wallpaper picker | `Mod+W` | Vicinae grid with real 16/9 previews of `~/Wallpapers/`, applied via awww |
| Toggle dictation (speech-to-text) | `Mod+D` | hyprvoice toggle (AI group only); shows an overlay with the live mic level, a microphone picker and validate/cancel buttons, so a dictation can also be finished with the pointer |
| Cancel dictation (discard) | `Mod+Shift+D` | `hyprvoice cancel` — drops the recording with no transcription, the keyboard twin of the overlay's ✕ |
| Dictate one clip in English | `Mod+Alt+D` | Same as `Mod+D`, with Whisper pinned to English for this dictation only; the language goes back to the remembered one when the daemon falls idle. Costs ~1s of config reload before the mic opens |
| Cycle dictation language | `Mod+Ctrl+D` | `auto → fr → en → auto`, remembered across sessions and shown as a chip in the dictation pill. Auto-detect writes *in the language it hears*, so on accented English it translates instead of mis-spelling — this pins it. Ignored while a dictation is in flight |

## 2. Window Management

| Action | Keys | Notes |
|---|---|---|
| Close window | `Mod+Q` | |
| Toggle floating | `Mod+T` | |
| Toggle pseudotile | `Mod+Alt+T` | Keeps the window at its own size, centred in the tile it still occupies |
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

> **Scrolling layout**: when a workspace is flipped to `scrolling` (via `Mod+Shift+T`), the standard arrow binds above (focus / movewindow / group-swap / resize) all work — Hyprland routes them through the active layout. Column-stacking ops (consume/expel/promote) and viewport pan are not bound.

## 7. Workspace Navigation

| Action | Keys | Notes |
|---|---|---|
| Workspace 1–7 | `Mod+&` .. `Mod+è` | Physical number-row positions; the same keys are `Mod+1` .. `Mod+7` while the US layout is active |
| Focus workspace up | `Mod+Page_Up` | `workspace r-1` (cycles rule-defined WS on current monitor, incl. empty) |
| Focus workspace down | `Mod+Page_Down` | `workspace r+1` |
| Focus prev workspace (mouse) | `Mod+WheelUp` | `r-1` on scroll up, matching `Page_Up` |
| Focus next workspace (mouse) | `Mod+WheelDown` | `r+1` on scroll down, matching `Page_Down` |

## 8. Move to Workspace

> **Convention**: `Alt` = move with focus follow, `Ctrl` = silent move (window goes, focus stays), `Shift` = move *every* window of the workspace instead of just the focused one (so `Ctrl+Shift` is the silent bulk move). On the letter keys `Shift` still means the less common action (reload configs, etc.).

| Action | Keys | Notes |
|---|---|---|
| Move to WS 1–7 (follow) | `Mod+Alt+&` .. `Mod+Alt+è` | Same physical keys as `Mod+Alt+1` .. `Mod+Alt+7` in US |
| Silent move to WS 1–7 | `Mod+Ctrl+&` .. `Mod+Ctrl+è` | Same physical keys as `Mod+Ctrl+1` .. `Mod+Ctrl+7` in US |
| Move window to WS up (follow) | `Mod+Alt+Page_Up` | `movetoworkspace r-1` |
| Move window to WS down (follow) | `Mod+Alt+Page_Down` | `movetoworkspace r+1` |
| Silent move to WS up | `Mod+Ctrl+Page_Up` | `movetoworkspacesilent r-1` |
| Silent move to WS down | `Mod+Ctrl+Page_Down` | `movetoworkspacesilent r+1` |
| Move to next WS (mouse, follow) | `Mod+Alt+WheelUp` | `movetoworkspace r+1` (wheel inverted vs page keys) |
| Move to prev WS (mouse, follow) | `Mod+Alt+WheelDown` | `movetoworkspace r-1` |
| Silent move to next WS (mouse) | `Mod+Ctrl+WheelUp` | `movetoworkspacesilent r+1` |
| Silent move to prev WS (mouse) | `Mod+Ctrl+WheelDown` | `movetoworkspacesilent r-1` |
| Move **all** windows to WS 1–7 (follow) | `Mod+Shift+&` .. `Mod+Shift+è` | Same physical keys as `Mod+Shift+1` .. `Mod+Shift+7` in US; empties the current workspace — or the scratchpad, when that is the one on screen |
| Silent move of **all** windows to WS 1–7 | `Mod+Ctrl+Shift+&` .. `Mod+Ctrl+Shift+è` | Same physical keys as `Mod+Ctrl+Shift+1` .. `Mod+Ctrl+Shift+7` in US |

## 9. Scratchpad

> **Desktop only**: the three binds that *reveal* the scratchpad pin it to DP-3. Hyprland has no such thing as a home monitor for a special workspace — every dispatcher that shows one puts it on whichever monitor is focused, and a `monitor:` rule on `special:special` parses without holding it — so the binds focus DP-3 first. The two silent binds reveal nothing and are unaffected, on every host.

| Action | Keys | Notes |
|---|---|---|
| Toggle scratchpad | `Mod+S` | Special workspace. Always appears on DP-3, wherever you press it; the dismiss press hands focus straight back to the monitor you were on |
| Move to scratchpad | `Mod+Alt+S` | Moves the window without following, then reveals the scratchpad on DP-3 |
| Move to scratchpad (silent) | `Mod+Ctrl+S` | Window goes, nothing is revealed |
| Move **all** windows to scratchpad | `Mod+Shift+S` | Empties the workspace, then reveals the scratchpad on DP-3 |
| Move **all** windows to scratchpad (silent) | `Mod+Ctrl+Shift+S` | |

## 10. Reload Configs

| Action | Keys | Notes |
|---|---|---|
| Reload Waybar, SwayNC or Hyprland | Search `reload` in Vicinae | Opens the local Reload command |

## 11. Screenshots

| Action | Keys | Notes |
|---|---|---|
| Screenshot monitor | `Print` | screenshot.sh (hyprshot); click the notification to open |
| Screenshot window | `Mod+Print` | screenshot.sh (hyprshot); click the notification to open |
| Screenshot region | `Mod+Shift+Print` | screenshot.sh (hyprshot); click the notification to open |

## 12. Screen recordings

| Action | Keys | Notes |
|---|---|---|
| Record monitor | `Mod+R` | Select a monitor; press any recording shortcut again to stop and save |
| Record window | `Mod+Alt+R` | Select a visible window, including a scratchpad window |
| Record region | `Mod+Shift+R` | Select a free-form region |
| Cancel recording | `Mod+Ctrl+R` | Stops and deletes the unfinished video; Escape cancels the initial selection |

## 13. Media & Volume

> All six keys below carry the `locked` bind flag, so they keep working while hyprlock holds the screen — Hyprland dispatches only flagged binds during a session lock, and without it volume and brightness were dead the whole time the laptop sat locked. The bar for that flag is not convenience but "would I let anyone standing at the locked machine do this": these change no data and reveal nothing.

| Action | Keys | Notes |
|---|---|---|
| Volume up / down | `XF86AudioRaiseVolume` / `XF86AudioLowerVolume` | swayosd-client OSD |
| Mute toggle | `XF86AudioMute` | swayosd-client OSD |
| Mic mute | `XF86AudioMicMute` | swayosd-client OSD |
| Brightness up / down | `XF86MonBrightnessUp` / `XF86MonBrightnessDown` | swayosd-client OSD |

## 14. Session & System

| Action | Keys | Notes |
|---|---|---|
| Power menu (wlogout) | `Mod+L` | Centered vertical list with keybind hints |
| Lock screen | `Mod+Alt+L` | `loginctl lock-session` |
| Suspend | `Mod+Ctrl+L` | `systemctl suspend`. Works from the lock screen too (`locked` bind) — hyprlock locks first and the suspend waits for its frame, see `lock-before-sleep.service` |
| Logout | `Mod+Shift+L` | `compositor-logout.sh` |
| Toggle dark/light mode | `Mod+N` | Switches Catppuccin Mocha/Latte + portal |
| Toggle caffeine mode | `Mod+Alt+N` | Inhibits idle (prevents lock/sleep) |
| Toggle Tailscale VPN | `Mod+Ctrl+N` | Connect/disconnect Tailscale |
| Lock + screen off | `Mod+Alt+M` | Locks the session, then powers the screen off; wake by mouse/key, then unlock |
| Toggle HDR (10-bit) | `Mod+Alt+H` | Desktop only; flips DP-3 between SDR (default) and 10-bit HDR, reverts on reload |
| Keybinding help | `Mod+H` | Vicinae list, grouped by section with a section filter; parsed from `binds.lua` by `hypr-keybindings` |

## 15. Mouse

| Action | Keys | Notes |
|---|---|---|
| Mouse move window | `Mod+LMB` | |
| Mouse resize window | `Mod+RMB` | |

## 16. Opacity

| Action | Keys | Notes |
|---|---|---|
| Toggle full opacity | `Mod+O` | |
| Toggle half opacity | `Mod+Ctrl+O` | |
| Toggle global opacity on/off | `Mod+Alt+O` | Flips decoration opacity session-wide (Lua `eval`, legacy `keyword` fallback) |

## 17. Layout Switching

Hyprland uses `dwindle` as the default layout on every host.

| Action | Keys | Notes |
|---|---|---|
| Toggle workspace scrolling ↔ dwindle | `Mod+Shift+T` | Flips the active workspace into the `scrolling` (tape) layout or back to `dwindle`. State persisted to `~/.cache/hypr-ws-layout`. |
