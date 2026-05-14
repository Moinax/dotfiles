# Hyprland session audit

Comparison of the current Hyprland session lifecycle against the standard patterns documented by the Hyprland and freedesktop ecosystems, with a recommendation for each deviation.

**Audit scope:** SDDM → session start → autostart → user-services → logout → suspend/resume. Hyprland only; Niri parity tracked separately.

**Target environment** (per `packages/groups/hyprland.yaml`): KDE base + SDDM, Hyprland layered on top with `waybar`, `rofi-wayland`, `swaync`, `swayosd`, `hypridle/hyprlock`, `wlogout`. Arch, Fedora, Debian.

---

## TL;DR

The session is plumbed by hand instead of using **`uwsm`** (Universal Wayland Session Manager — the post-0.45 standard). Most of the unique pain in this repo (the env-push race, the `start-limit-hit` recovery dance, services surviving the compositor exit, the broken-pipe SIGABRTs that triggered the drkonqi cascade) traces back to that single decision. Adopting `uwsm` would let us delete most of the workarounds and replace them with one-liners.

The other deviations (custom logout script, hardcoded distro paths, NVIDIA suspend helper scripts) are smaller; some are still load-bearing, some are stale.

### Deviation summary

| # | Area | Severity | Reason still relevant? | Effort to fix |
|---|------|----------|------------------------|---------------|
| 1 | No `uwsm` — manual session bootstrap | High | Partial — historical, can revisit | Medium (1 day, mostly migration testing) |
| 2 | `dbus-update-activation-environment` in `autostart.lua` | High | No — uwsm makes it unnecessary | Trivial (delete) once #1 done |
| 3 | `reset-failed` + `StartLimitIntervalSec=0` workarounds | Medium | No — symptoms of #1 | Trivial (delete) once #1 done |
| 4 | Mixed `exec-once` + `systemctl --user start` for autostart entries | Medium | Yes for now; uwsm makes it consistent | Small |
| 5 | Hardcoded `/usr/lib/polkit-kde-authentication-agent-1` path | Low | Yes | Trivial |
| 6 | Custom `compositor-logout.sh` instead of `uwsm stop` / `loginctl terminate-user` | Medium | Yes (we don't have uwsm) | Trivial once #1 done |
| 7 | NVIDIA suspend `hyprland-suspend.service` (STOP/CONT) on installer-managed units | Medium | Conditional — only on driver <595 | Already handled, but stale units may linger |
| 8 | `wlogout` uses `systemctl suspend/poweroff/reboot` rather than `loginctl` | Low | Yes (works fine), no benefit to changing | Trivial |
| 9 | `swayidle-resume-reset.sh` — gdbus poller restarting swayidle | Low | Yes (real bug) but solvable with proper sleep.target hook | Small |
| 10 | drkonqi `/dev/null` masks for KF6 bug | Low (workaround) | Yes until KF6 ships fix | N/A |

---

## 1. No `uwsm` — manual session bootstrap

### What we do

SDDM's wayland-sessions list contains *both* of Arch's stock entries:
```
/usr/share/wayland-sessions/hyprland.desktop          ← currently used
/usr/share/wayland-sessions/hyprland-uwsm.desktop
```

We run the plain `hyprland.desktop`, which calls `/usr/bin/start-hyprland` (binary from the Hyprland package, NOT a script). SDDM's `sddm-helper` is the parent and owns the user `session.scope`. Hyprland runs as a direct child:
```
session-2.scope                   ← sddm-helper as scope leader
 └── sddm-helper --start /usr/bin/start-hyprland
      └── Hyprland --watchdog-fd 4
           └── hyprpaper, swaync, hypridle, dropbox, … (exec-once children)
           └── systemctl --user start waybar.service (cgroup user@1000.service)
```

Nothing starts or stops `graphical-session.target`. Services declared `PartOf=graphical-session.target` (waybar, swayosd) are decorative — the target is never active in the first place.

### What the standard is

Since Hyprland 0.45 (Sept 2024), the Hyprland wiki explicitly recommends **`uwsm`** as the canonical session manager: [wiki.hypr.land/Useful-Utilities/Systemd-start/](https://wiki.hypr.land/Useful-Utilities/Systemd-start/). `uwsm` wraps the compositor in a transient systemd unit (`wayland-wm@hyprland.service`), starts `graphical-session.target`, sets up systemd activation environment, and stops everything in dependency order on logout. The intended SDDM entry is `hyprland-uwsm.desktop`, which the Hyprland package already installs.

Standard autostart pattern becomes:
- One-shot apps: `uwsm-app -- foo` (runs `foo` inside a transient unit bound to graphical-session)
- Long-running daemons: regular `~/.config/systemd/user/foo.service` with `PartOf=graphical-session.target` + `WantedBy=graphical-session.target` — and unlike today, `PartOf` actually fires because `graphical-session.target` is real.

### Why we deviated (git archaeology)

`uwsm` is not mentioned anywhere in the repo's history. The migration was simply never done. The session bootstrap predates `uwsm`'s maturity, and no commit has revisited it since 0.45 landed.

### Consequences we paid

Every workaround documented below is downstream of this:
- The env-push hack (#2) exists because `hyprland.start` fires before WAYLAND_DISPLAY is in the systemd user-env. `uwsm` does this push *before* the compositor starts.
- The `start-limit-hit` problem (#3) exists because waybar runs under `user@1000.service` (not the session scope), so it survives logout, sees the Wayland socket close, retries 5 times in 5 s, and gives up. `uwsm` stops it cleanly *before* the socket goes away.
- The 4 SIGABRT/SEGV cascade on logout (which then triggered the drkonqi storm) is the same race for `hyprpaper`, `xdg-desktop-portal-hyprland`, `xdg-desktop-portal-kde`, `kded6`. They all see the Wayland socket vanish unexpectedly. Under `uwsm`, they're stopped first, see a clean disconnect, exit 0.

### Effort to migrate

Medium. Roughly:
1. Add `uwsm` to `packages/groups/hyprland.yaml` for all distros (`extra/uwsm` on Arch; available on Fedora and Debian).
2. Change the SDDM-selectable session — set up chezmoi/post-install to write the default session selection to `hyprland-uwsm.desktop`, or just leave it to the user (SDDM remembers the last login).
3. Move `autostart.lua` entries into one of two buckets:
   - **Become uwsm-app one-shots** for short-lived launches: `hl.exec_cmd("uwsm-app -- hyprpaper")`, etc.
   - **Become systemd user units** for daemons that have lifecycle/restart needs: `hyprpaper.service`, `swaync.service`, etc., all `PartOf=graphical-session.target`. Already done for waybar, swayosd, hyprvoice, vibewatch — extending the pattern.
4. Delete the env-push and `reset-failed` plumbing from `autostart.lua.tmpl`.
5. Delete `StartLimitIntervalSec=0` from the two unit files.
6. Replace `compositor-logout.sh`'s Hyprland branch with `uwsm stop`.
7. Test cycle: logout, login, suspend, resume, lock/unlock, all twice in a row.

Risk: medium. Touches the boot path. Niri parity adds work but you said Niri is out of scope here.

### Verdict

This is the foundational cleanup. Recommend doing it. Everything else gets simpler.

---

## 2. `dbus-update-activation-environment` in `autostart.lua`

### What we do

`home/dot_config/hypr/conf/autostart.lua.tmpl` lines 12–21:
```lua
hl.exec_cmd(
    "dbus-update-activation-environment --systemd " .. env_vars ..
    " && systemctl --user reset-failed " .. user_services ..
    " && systemctl --user start " .. user_services
)
```

This pushes `WAYLAND_DISPLAY`, `XDG_CURRENT_DESKTOP`, `HYPRLAND_INSTANCE_SIGNATURE` into the systemd user-manager environment so subsequent `systemctl --user start` calls find the Wayland display.

### What the standard is

`uwsm` calls `dbus-update-activation-environment --systemd` for you, before the compositor starts. The autostart hook then doesn't need to do anything except spawn apps.

### Why we deviated

Commit `0498011` (May 13 2026): without the env push, services were race-crashing with `cannot open display:` and hitting start-limit before recovery.

### Effort

Trivial deletion once `uwsm` is in place. Until then, this is correct.

---

## 3. `StartLimitIntervalSec=0` + `reset-failed` band-aids

### What we do

- `waybar.service` and `swayosd-server.service` have `StartLimitIntervalSec=0` so they can retry indefinitely after a broken-pipe exit on logout.
- `autostart.lua` runs `systemctl --user reset-failed swayosd-server.service waybar.service hyprvoice.service` before starting them.

### What the standard is

A service whose lifecycle is bound to a target should stop *when the target stops* — `PartOf=graphical-session.target` does this — and never reach the failure path at all. Under `uwsm`, that's automatic.

### Why we deviated

This conversation (May 14 2026). The waybar broken-pipe loop revealed that `PartOf=graphical-session.target` is decorative because the target is never started/stopped.

### Effort

Trivial deletion once `uwsm` is in place. Until then, leave it.

---

## 4. Mixed `exec-once` and `systemctl --user start` in autostart

### What we do

`autostart.lua.tmpl` has two flavors:

| Pattern | Apps |
|---------|------|
| Direct `hl.exec_cmd(...)` | hyprpaper, swaync, polkit-kde-agent, hypridle, blueman-applet, dropbox, wl-paste/cliphist, apply-dark-mode.sh, hyprpm |
| `systemctl --user start <unit>` | swayosd-server, waybar, hyprvoice (+ vibewatch elsewhere) |

The split is historical: things that crashed on suspend/resume (waybar, swayosd) got promoted to user units; everything else still runs as a Hyprland child process.

### Why it matters

Children of Hyprland die when Hyprland dies — *visibly* on logout, as the cascade of 4 SIGABRT/SEGV crashes we traced. None of them handle the Wayland socket disappearing gracefully. They're not bugs we should fix (the processes were dying anyway), but they're noisy and triggered the drkonqi cascade.

User-unit children are managed by systemd and can be cleanly stopped before the compositor exits — *if* something stops them. Under the current setup, nothing does, which is why they hit the *opposite* failure mode (broken pipe + retry storm).

### What the standard is

Pick one pattern per app, based on lifecycle:
- **Daemon** (status bar, OSD server, notification daemon, wallpaper, idle/lock daemons, polkit agent, clipboard watcher): systemd user service, `PartOf=graphical-session.target`.
- **One-shot** (apply-dark-mode.sh, hyprpm reload, plugin loaders): `uwsm-app --` or just exec, doesn't matter.

### Effort

Small. ~6 new `.service` files in `home/dot_config/systemd/user/`, autostart.lua becomes ~5 lines.

### Verdict

Tied to #1. Doing this without uwsm partially works (services survive crashes via Restart=) but the cleanup-on-exit problem remains. Together with uwsm it's the right pattern.

---

## 5. Hardcoded `/usr/lib/polkit-kde-authentication-agent-1` path

### What we do

`autostart.lua.tmpl` line 25: `hl.exec_cmd("/usr/lib/polkit-kde-authentication-agent-1")`.

Niri config has a Fedora/Arch split for the same binary at `/usr/libexec/polkit-kde-authentication-agent-1` vs `/usr/lib/...`. Hyprland's autostart doesn't have that split — it just hardcodes the Arch path.

### What the standard is

The polkit-kde-agent package ships a `.desktop` file in `/etc/xdg/autodiscover/` or similar; on KDE-aware sessions it's auto-started by `plasma-workspace`. Outside Plasma you launch it yourself, but ideally via either:
- `systemctl --user start plasma-polkit-agent.service` (KF6 ships this), or
- `uwsm-app -- /usr/bin/polkit-kde-authentication-agent-1` resolved via `which`/`command -v`.

### Why we deviated

Cargo-culted from the original wlogout/Hyprland setup. The hardcoded path works on Arch but breaks on Fedora.

### Effort

Trivial. Either:
- Use `systemctl --user start plasma-polkit-agent.service` and let KF6 own it, or
- Replicate the niri config's distro-conditional path.

### Verdict

Easy win, do it independently of #1.

---

## 6. Custom `compositor-logout.sh`

### What we do

```bash
if is_hyprland; then
    hyprctl dispatch 'hl.dsp.exit()'
elif is_niri; then
    niri msg action quit --skip-confirmation
else
    loginctl terminate-session "${XDG_SESSION_ID}"
fi
```

### What the standard is

- Under `uwsm`: `uwsm stop` — gracefully stops user services (via `graphical-session.target`), then exits compositor. Compositor-agnostic.
- Without `uwsm`: graceful compositor exit is what we do now (`hyprctl dispatch 'hl.dsp.exit()'` / `niri msg action quit`). The `loginctl terminate-session` fallback we previously had was abrupt and triggered the SDDM "Process crashed" misread we just fixed.

### Why we deviated

`uwsm` isn't installed. Once it is, this script's Hyprland branch becomes `uwsm stop` (one line, no compositor-detection lib needed).

### Effort

Trivial once #1 is done.

---

## 7. Installer-generated NVIDIA suspend helper services

### What we do

`install/installer.sh` lines 1518–1525 conditionally creates two `/etc/systemd/system/` units **on driver <595**:
- `hyprland-suspend.service` → `pkill -STOP -x Hyprland` before `nvidia-suspend.service`
- `hyprland-resume.service` → `pkill -CONT -x Hyprland` after `nvidia-resume.service`

On driver 595+, `cleanup_legacy_nvidia_suspend_services()` is supposed to disable and remove them. NVIDIA's own `nvidia-suspend.service` is also disabled on 595+ (kernel uses suspend notifiers instead).

### What I observed live

Your system runs NVIDIA `595.71.05`, but `/etc/systemd/system/hyprland-suspend.service` and `niri-{suspend,resume}.service` files are still present and enabled. Either the installer hasn't been re-run since the 595+ upgrade, or `cleanup_legacy_nvidia_suspend_services` isn't being invoked on every `setup` pass. The journal from your May 14 suspend (`Starting Suspend Hyprland before NVIDIA driver suspends...`) confirms they fired — at minimum redundant on 595+, possibly harmful per the comment at installer.sh:1492 ("interfere with the kernel notifier mechanism and cause NVIDIA GSP heartbeat timeouts on resume").

### What the standard is

- For driver ≥595: nothing — the kernel notifier owns suspend/resume.
- For driver <595: NVIDIA's own `nvidia-suspend/resume.service` (shipped by the driver package) + the per-compositor STOP/CONT services are correct.

The installer-generated units are correct for what they do; the issue is that on driver 595+ they shouldn't exist.

### Why we deviated

Commit `45e1ac0` + `6919e1f` — these services were the *correct* workaround for driver <595's known GPU-deadlock-on-suspend bug. The 595+ rework removed them from the install path but cleanup of preexisting units depends on `setup_nvidia()` being re-run.

### Effort

Two parts:
- **Now (one-off):** run the installer's nvidia setup again or manually `sudo systemctl disable hyprland-suspend hyprland-resume niri-suspend niri-resume && sudo rm /etc/systemd/system/{hyprland,niri}-{suspend,resume}.service && sudo systemctl daemon-reload`.
- **Permanent:** make `cleanup_legacy_nvidia_suspend_services` idempotent and call it unconditionally on every setup pass (currently called only in the 595+ branch). Already idempotent looking at it — just needs to be invoked more often.

### Verdict

Actionable today. Possibly related to the "suspend reboots instantly" symptom you reported, since stale STOP/CONT services racing the kernel notifier is the exact failure mode the comment warns about.

---

## 8. `wlogout` invokes `systemctl` directly

### What we do

`wlogout/layout`:
```json
"action": "systemctl suspend"
"action": "systemctl reboot"
"action": "systemctl poweroff"
```

### What the standard is

`loginctl suspend` / `loginctl reboot` / `loginctl poweroff`. Goes through logind, which honors inhibitors, calls `before-sleep`/`after-sleep` hooks, respects polkit policy. `systemctl` bypasses some of that.

### Why we deviated

Probably copy-paste from upstream wlogout examples. Behavior is the same on a typical desktop because polkit allows the action either way.

### Effort

Trivial. But:

### Verdict

Cosmetic. Skip unless you hit an inhibitor or polkit edge case.

---

## 9. `swayidle-resume-reset.sh` — gdbus poller

### What we do

A persistent `gdbus monitor` daemon listens for logind's `PrepareForSleep(false)` signal and restarts `swayidle` after every resume, to reset stale idle counters.

### What the standard is

Run swayidle as a systemd user service with `Requires=sleep.target` and `Restart=on-failure`; or have a small `sleep.target.wants/` user unit that runs `pkill -USR1 swayidle` (or restarts the service) post-resume. systemd already knows when we're waking up; no need for a long-lived dbus poller.

### Why we deviated

Commit `9bafff4` "Fix spurious re-lock after resume on Niri" — the dbus monitor approach was simpler to write than a systemd hook at the time, and works.

### Effort

Small. ~15-line systemd user unit pair (`swayidle.service` + `swayidle-resume.service`) replaces the script.

### Verdict

Low priority. Works as-is, runs cheaply. Worth doing alongside the broader "everything is a systemd unit" cleanup in #4.

---

## 10. `drkonqi-coredump-{launcher.socket,pickup.service}` masks

### What we do

`home/dot_config/systemd/user/symlink_drkonqi-coredump-{launcher.socket,pickup.service}` → `/dev/null` (chezmoi-managed mask of the user-level drkonqi pickup chain).

### What the standard is

Don't mask system-provided services. drkonqi is supposed to work; if it's crashing, that's an upstream bug.

### Why we deviated

This conversation. drkonqi 6.6.4 + knotifications 6.26 still hits a use-after-free in KNotifications (variant of [KDE bug 511645](https://bugs.kde.org/show_bug.cgi?id=511645)) that turns each primary crash into 20+ secondary drkonqi crashes. The fix that landed in KF6 6.20 doesn't cover the path we hit on logout.

### Effort

N/A — leave masked until upstream fixes, then `chezmoi forget` the symlinks.

### Verdict

Justified workaround. Re-evaluate after the next KF6 release.

---

## Recommended sequencing

If you act on this audit, the natural order is:

1. **One-off cleanup** of the stale NVIDIA STOP/CONT units (#7) — possibly fixes the suspend-reboot symptom, takes 5 minutes.
2. **Fix #5** (polkit path) — trivial portability improvement, independent of everything else.
3. **Adopt `uwsm`** (#1) — the big one, ~1 day with testing.
   - That immediately deletes the workarounds in #2 (env push), #3 (StartLimitIntervalSec=0 / reset-failed), simplifies #6 (logout script), and makes #4 (autostart consistency) natural.
4. **Convert remaining autostart entries to user units** (#4) — best done as part of #1.
5. **Move swayidle to a systemd unit pair** (#9) — small follow-up.
6. **Leave #8, #10** — low-value or upstream-pending.

The first three steps eliminate roughly the entire class of bugs we've been hitting this week.

---

## What's *not* a deviation (and why)

For completeness, a few things that look custom but are actually fine:

- **Lua config (`hyprland.lua`)** vs hyprlang (`hyprland.conf`) — the Lua path is now Hyprland's recommended config language as of 0.55 (commit `2a7eee2` correctly auto-picks based on local Hyprland version). Not a deviation, just a forward migration.
- **`hypridle` + `hyprlock`** — Hyprland's first-party idle/lock daemons. Standard. Config looks fine.
- **`compositor.sh` detection helper** — needed because we support both Hyprland and Niri. Would still be needed under uwsm.
- **`waybar-caffeine.sh`, `toggle-monitors.sh`, custom scripts in `~/.local/bin`** — application-level scripts, not session plumbing.
- **`XDG_MENU_PREFIX=plasma-`** in environments — required for kbuildsycoca6 to populate KDE's service cache when running under non-Plasma compositor. Documented in commit `ffb8c2d`.

---

## Sources

- [Hyprland wiki — Systemd start / uwsm](https://wiki.hypr.land/Useful-Utilities/Systemd-start/)
- [uwsm — Vladimir Kudrya / GitHub](https://github.com/Vladimir-csp/uwsm)
- [systemd graphical-session.target](https://www.freedesktop.org/software/systemd/man/systemd.special.html#graphical-session.target)
- [KDE Bug 511645 — drkonqi-coredump-launcher SEGV](https://bugs.kde.org/show_bug.cgi?id=511645)
- Repo commits cited inline: `2a7eee2`, `0498011`, `6cbd6d0`, `d23d385`, `97e96e0`, `cc3b4b4`, `6919e1f`, `45e1ac0`, `ffb8c2d`, `9bafff4`.
