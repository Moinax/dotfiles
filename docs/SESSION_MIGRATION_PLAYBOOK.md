# Session modernization — execution playbook

Step-by-step procedure to apply the `session-modernization` branch on the live
machine and verify each piece works. Read top-to-bottom; nothing here is
optional unless explicitly marked.

Companion document: [`SESSION_AUDIT.md`](SESSION_AUDIT.md) explains *why* each
change exists.

---

## 0. Pre-flight

Confirm you're on the right branch and the source tree is clean:

```bash
cd ~/dotfiles
git status
git log --oneline -10
```

You should see the `session-modernization` branch ahead of `main` with 8
commits, starting at `eb9967a session: fix logout black screen…` and ending
at `56435c1 installer: hint about uwsm session`.

If you have local changes outside this branch, stash or commit them first.

---

## 1. Install `uwsm`

`uwsm` is the universal Wayland session manager — wraps the compositor in a
systemd unit, starts `graphical-session.target`, stops it cleanly on logout.

```bash
# Arch
sudo pacman -S uwsm

# Fedora
sudo dnf install uwsm

# Debian (trixie+ only — earlier releases need to build from source)
sudo apt install uwsm
```

**Verify:**

```bash
which uwsm           # → /usr/bin/uwsm
uwsm --version
```

---

## 2. Clean up stale NVIDIA STOP/CONT units (only if NVIDIA driver ≥595)

Your machine has `hyprland-suspend.service`, `hyprland-resume.service`,
`niri-suspend.service`, `niri-resume.service` left over from when the
installer was last run on driver <595. On driver 595+, the kernel uses
suspend notifiers; these legacy units now *interfere* with that mechanism
and can cause "GSP heartbeat timeouts on resume". This is the likely culprit
for the "suspend reboots the computer instantly" symptom.

**Check driver version first:**

```bash
nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null \
    || cat /sys/module/nvidia/version 2>/dev/null
```

**If ≥ 595, run the cleanup:**

```bash
# Disable and remove the four legacy units
sudo systemctl disable hyprland-suspend.service hyprland-resume.service \
                       niri-suspend.service niri-resume.service 2>/dev/null
sudo rm -f /etc/systemd/system/hyprland-{suspend,resume}.service \
           /etc/systemd/system/niri-{suspend,resume}.service
sudo systemctl daemon-reload

# Also make sure NVIDIA's own legacy services are disabled on 595+
sudo systemctl disable nvidia-suspend.service nvidia-resume.service \
                       nvidia-hibernate.service 2>/dev/null
```

**Verify:**

```bash
systemctl list-unit-files | grep -E "hyprland-(suspend|resume)|niri-(suspend|resume)|nvidia-(suspend|resume|hibernate)"
# All four hyprland/niri lines should be GONE.
# The three nvidia-* lines should show "disabled".
```

**If < 595**, keep the legacy units enabled — the installer maintains them
for that case. Skip this step.

---

## 3. Apply the dotfile changes

```bash
chezmoi diff       # Skim — should show systemd user units, autostart trim, etc.
chezmoi apply
systemctl --user daemon-reload
```

**Verify the new symlinks landed:**

```bash
ls -la ~/.config/systemd/user/graphical-session.target.wants/
```

You should see 9 symlinks: `blueman-applet.service`, `cliphist.service`,
`dropbox.service`, `hypridle.service`, `hyprpaper.service`,
`plasma-polkit-agent.service`, `swaync.service`, `swayosd-server.service`,
`waybar.service`.

**Verify the drop-ins:**

```bash
systemctl --user cat blueman-applet.service | tail -6
systemctl --user cat dropbox.service | tail -6
# Each should end with `PartOf=graphical-session.target` and
# `After=graphical-session.target`.
```

---

## 4. Log out cleanly

Right now you're still in the *old* (non-uwsm) Hyprland session.
`compositor-logout.sh` detects this (no `uwsm check active`) and falls back
to `hyprctl dispatch 'hl.dsp.exit()'` — same as before, that's fine.

```
SUPER+SHIFT+L      # direct logout binding
```

If anything refuses to die and SDDM doesn't come back, drop to a TTY
(`Ctrl+Alt+F3`), log in, and `sudo systemctl restart sddm`.

---

## 5. At SDDM, pick "Hyprland (uwsm-managed)"

**This is the critical step.** SDDM defaults to whatever you picked last
time, which on this machine is plain `Hyprland`. Use the session dropdown
(usually top-right or top-left of the greeter) to choose:

> **Hyprland (uwsm-managed)**

Log in. SDDM remembers your choice — you only do this once per user per
machine.

If you accidentally pick plain `Hyprland`, the compositor starts but no
daemons run (no waybar, no notifications, no wallpaper). Recovery: log out
again and pick the right entry.

---

## 6. Post-login verification

Open a terminal and run:

```bash
# Session is uwsm-managed
loginctl show-session "$XDG_SESSION_ID" | grep Desktop
# → Desktop=Hyprland

# graphical-session.target should be active
systemctl --user is-active graphical-session.target
# → active

# All the daemons that used to be Hyprland children are now systemd units
systemctl --user --no-pager list-units --type=service --state=active \
    | grep -E "waybar|hyprpaper|swaync|hypridle|cliphist|blueman-applet|dropbox|plasma-polkit-agent|swayosd"
```

Expected: 9 active services. If any are missing or failed:

```bash
systemctl --user status <missing-service>
journalctl --user -u <missing-service> --since "5 minutes ago"
```

**Visual sanity check:**

- Waybar at the top: ✓
- Wallpaper visible: ✓ (hyprpaper)
- Notifications work: `notify-send hello world` → ✓ (swaync)
- Volume keys show OSD: ✓ (swayosd)
- Bluetooth tray icon: ✓ (blueman-applet)
- Dropbox tray icon: ✓ (dropbox)
- App that needs root opens polkit prompt: ✓ (plasma-polkit-agent)

---

## 7. Test logout under uwsm

```
SUPER+SHIFT+L
```

The compositor should exit gracefully, SDDM greeter should come back
immediately, *no* black-screen wait. Then check:

```bash
# After logging back in, look at what crashed during the last logout
coredumpctl list --since "5 minutes ago"
```

**Expected:** empty, or at most one entry. Before this migration, you'd see
~25 (4 primary crashes + ~21 drkonqi cascade). The whole point of the work
is that this list shrinks to nothing.

---

## 8. Test suspend

```
SUPER+CTRL+L       # direct suspend binding, or SUPER+L → Suspend in wlogout
```

**Expected on driver 595+** (after step 2 cleanup):

- Screen goes off
- System actually suspends (LEDs change, fans stop)
- Resume on keypress works
- Display returns
- Session is intact

**If suspend still reboots instantly**, the legacy units may not have been
fully removed. Re-check:

```bash
sudo find /etc/systemd/system/ /usr/lib/systemd/system/ -name "hyprland-*.service" -o -name "niri-*.service"
# Should output nothing related to suspend/resume.

journalctl -b 0 | grep -iE "PM:.*suspend|nvidia.*suspend|GSP" | tail -20
# Look for "PM: suspend entry (deep)" followed by "PM: suspend exit" — that's success.
# If it's followed by a reboot timestamp, NVIDIA still tripped on something.
```

---

## 9. Rollback (if needed)

If anything's deeply broken and you need to get back to a working state:

```bash
# Switch back to main branch
cd ~/dotfiles
git checkout main
chezmoi apply

# Log out, at SDDM pick plain "Hyprland" (not uwsm-managed)
```

Note: today's bug-fix commits are *also* on `main` after merge — only roll
back if you literally can't log in any other way.

---

## 10. After everything works — merge the branch

```bash
cd ~/dotfiles
git checkout main
git merge --no-ff session-modernization
git push origin main          # only if you want to publish; not strictly needed
git branch -d session-modernization
```

---

## Reference: what each change buys you

| Change | Visible effect |
|---|---|
| Stale NVIDIA STOP/CONT removed | Suspend stops rebooting |
| Daemons → systemd units | Survive Hyprland reload, restart on failure |
| `uwsm` session | `graphical-session.target` actually starts/stops |
| Strip env-push / reset-failed | Simpler autostart, no race conditions |
| `compositor-logout.sh` → `uwsm stop` | Clean teardown, no broken-pipe SIGABRTs |
| drkonqi masks (already merged) | No 89-coredump cascade per logout |

---

## Reference: open questions / future work

- **Niri parity** — the same migration (uwsm, systemd-unit daemons) should
  happen for niri but is intentionally out of scope here. Track separately.
- **Suspend reboot root cause** — if step 8 still fails after cleanup, the
  problem is NVIDIA-side (firmware/driver) rather than our session config.
  Capture `journalctl -b -1` immediately after the next failed suspend.
- **drkonqi mask** — revisit when KDE Frameworks ships a fix for KB511645
  variants. Just `chezmoi forget` the two `symlink_drkonqi-*` files.
