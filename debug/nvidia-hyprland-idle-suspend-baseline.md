# NVIDIA / Hyprland Idle + Suspend Baseline

Last updated: 2026-10-13

This note documents the intended baseline after removing several trial fixes
around black monitors after DPMS-off or suspend. Use it as context before making
new changes in this area.

## Goal

Keep the user-visible behavior:

- Idle warning at 250s.
- Lock at 300s.
- Power monitors off at 330s.
- Suspend at 1800s.
- Manual lock + screen-off on `Mod+Alt+M`.
- NVIDIA suspend/resume should preserve video memory.
- Prefer the documented Hyprland/NVIDIA path over local workarounds.

## Baseline Sources

- Hyprland NVIDIA guide: <https://wiki.hypr.land/Nvidia/>
- Hyprland hypridle guide: <https://wiki.hypr.land/Hypr-Ecosystem/hypridle/>
- Hyprland dispatchers / DPMS syntax: <https://wiki.hypr.land/Configuring/Dispatchers/>
- NVIDIA Linux README, power management: <https://download.nvidia.com/XFree86/Linux-x86_64/README/powermanagement.html>

## Current Standard Pattern

### Hyprland / hypridle

Use `hypridle` as the single idle manager for Hyprland.

Managed source:

- `home/dot_config/hypr/hypridle.conf`

Expected flow:

```conf
general {
    lock_cmd = pidof hyprlock || hyprlock
    before_sleep_cmd = loginctl lock-session
    after_sleep_cmd = hyprctl dispatch 'hl.dsp.dpms({ action = "enable" })'; hyprctl dispatch 'hl.dsp.force_idle(0)'
    inhibit_sleep = 3
}

listener {
    timeout = 250
    on-timeout = notify-send "Your computer will be locked due to inactivity"
}

listener {
    timeout = 300
    on-timeout = loginctl lock-session
}

listener {
    timeout = 330
    on-timeout = hyprctl dispatch 'hl.dsp.dpms({ action = "disable" })'
    on-resume = hyprctl dispatch 'hl.dsp.dpms({ action = "enable" })'
}

listener {
    timeout = 1800
    on-timeout = pgrep -fx "python3 .*/wayland-idle-inhibitor\.py" || systemctl suspend
}
```

Rationale:

- **Caffeine mode does not survive the lock screen, so the suspend listener is
  gated on the inhibitor process.** Hyprland stops honouring the idle inhibitor
  once hyprlock holds the session: the compositor starts reporting idle again and
  every listener rearms with the inhibitor still up. Measured on 2026-10-13 — the
  evening ran nine and a half hours without a single `Idled: rule`, then a manual
  lock at 03:33:29 and all four rules fired from 03:34:40, ending in a suspend
  nobody asked for. Only this listener is gated: locking and blanking an untouched
  machine are what caffeine is least in the way of, suspending it mid-run is the
  one that loses work. Keyed on the process and not on waybar's state file,
  because the process *is* the inhibition — a dead inhibitor with a stale `on` in
  the state file should suspend. `-x` is what stops the `sh -c` wrapper hypridle
  spawns from matching its own pattern; verified by firing the rule under a
  throwaway `hypridle -c` plus `hyprctl dispatch 'hl.dsp.force_idle(5)'`, which is
  also the only way to see what hyprlang hands to `sh` without waiting 30 minutes.

- `hyprlock` is the Hypr ecosystem locker and matches the Hyprland docs.
- `loginctl lock-session` lets logind/hypridle coordinate the lock path.
- `inhibit_sleep = 3` follows the documented pattern: inhibit suspend until the
  session is locked, then allow suspend.
- DPMS uses the documented Hyprland dispatcher directly.
- Resetting Hyprland's idle clock after resume rearms listeners which already
  fired before suspend. Without it, a wake event consumed before Wayland resumes
  input leaves DPMS and suspend disarmed until a second keyboard or pointer event.
  This keeps hypridle running, so its D-Bus inhibitor cookies survive the reset.

### Manual Lock + Screen Off

Managed source:

- `home/dot_local/bin/executable_lock-dpms-off.sh`

Behavior:

1. Call `loginctl lock-session`.
2. Wait briefly for either `hyprlock` or `swaylock`.
3. Only then power monitors off.

This guard is intentionally kept. It is not an NVIDIA workaround; it prevents a
dark but unlocked session if the locker fails to start.

Hyprland uses:

```sh
hyprctl dispatch 'hl.dsp.dpms({ action = "disable" })'
```

Niri uses:

```sh
niri msg action power-off-monitors
```

### Niri / swayidle

Managed source:

- `home/dot_config/swayidle/config`

Niri still uses `swayidle`, but should prefer `hyprlock` where available and
fall back to `swaylock` for distros where hyprlock is unavailable:

```sh
lock 'pidof hyprlock || pidof swaylock || hyprlock || swaylock'
```

### NVIDIA

Use the packaged NVIDIA suspend/resume integration:

- `nvidia-suspend.service`
- `nvidia-resume.service`
- `nvidia-hibernate.service`

Keep:

- `NVreg_PreserveVideoMemoryAllocations=1`
- `nvidia-drm.modeset=1`
- NVIDIA package default `NVreg_UseKernelSuspendNotifiers=1`
- `NVreg_TemporaryFilePath=/var/tmp`

The last two lines of that list used to read "NVIDIA package default" both. For
`NVreg_TemporaryFilePath` that was never true: **no package sets it**, and unset
it is `/tmp` — a 32 GiB tmpfs here, so the video memory the driver saves on the
way into S3 never leaves RAM. `NVreg_PreserveVideoMemoryAllocations=1` was not a
package default either; the only file setting it was
`/usr/lib/modprobe.d/gsr-nvidia.conf`, from **gpu-screen-recorder**, so
uninstalling a screen recorder would have taken VRAM preservation with it.

Both are now written by `install/lib/nvidia-vram-suspend.sh`, called by
`dots setup` (`setup_nvidia_vram_suspend`) and by `dots update`
(`reconcile_nvidia_vram_suspend`, keyed on the content of
`/etc/modprobe.d/nvidia-vram-suspend.conf`). The lib also rebuilds the
initramfs, which is not optional: `nvidia.ko` is loaded from it on this machine
and the `modconf` hook bakes a *copy* of `/etc/modprobe.d` into the image, so
writing the file alone changes nothing at boot while looking like it worked.

**The rebuild command is `limine-mkinitcpio`.** `limine-mkinitcpio-hook` ships
`/etc/pacman.d/hooks/90-mkinitcpio-install.hook`, which overrides the stock
mkinitcpio one: the images this box boots are
`/boot/<machine-id>/<pkgbase>/{vmlinuz,initramfs}`, `/etc/mkinitcpio.d` holds no
presets for `mkinitcpio -P` to walk, and `/boot` is the ESP (root-only, `fmask=0077`).

`kernel-install add-all` is a dead end here, paid for on 2026-10-13: it builds a
correct image into systemd's own *kernel-version*-keyed layout
(`/boot/<machine-id>/<kver>/{linux,initrd}` plus `/boot/loader/entries/*.conf`),
leaves what limine boots untouched, and costs 240 MB of ESP. Worse, undoing it
with `kernel-install remove <kver>` runs the `50-depmod.install` plugin, which
**deletes `modules.dep` and the rest of the depmod output for that kernel** —
after which every mkinitcpio build fails with `module not found: nvidia` and a
reboot would reach a root that can load no module. Recovery is
`sudo depmod -a <kver>` per kernel; verify with
`modinfo -k <kver> nvidia` and a count of `modules.*` files (14 per kernel here).

Do not install custom compositor `SIGSTOP` / `SIGCONT` suspend services.

Do not force a platform sleep mode in the dotfiles baseline. In particular, do
not force either:

- `mem_sleep_default=s2idle`
- `mem_sleep_default=deep`

If a machine needs one of those, treat it as a machine-local firmware/kernel
choice rather than the default dotfiles policy.

## Workarounds Removed

These were removed from the managed dotfiles baseline:

- `~/.local/bin/toggle-dpms.sh`
- `hypridle-watchdog.service`
- `hyprland-suspend.service`
- `hyprland-resume.service`
- `niri-suspend.service`
- `niri-resume.service`
- Forced `NVreg_UseKernelSuspendNotifiers=0`
- Forced `mem_sleep_default=s2idle`
- Forced `nvidia-drm.fbdev=1`
- Automatic `spd5118` blacklist
- Hyprland idle lock through `swaylock`

Why:

- They were accumulated from debugging sessions and contradicted each other.
- The watchdog targeted a whole Wayland disconnect failure, but observed logs
  showed per-output removal/re-addition, especially DP-3.
- The compositor `SIGSTOP` / `SIGCONT` services are not part of the documented
  Hyprland/NVIDIA setup.
- The sleep-mode and notifier overrides made the baseline machine-specific.

## Observed Failure Clues

### 2026-10-13: frozen entering S3, in the NVIDIA suspend hook

Two nights in a row (11→12 and 12→13 October). The journal only reaches back to
12 Oct 08:52 — CachyOS caps it at 50 MB in
`/usr/lib/systemd/journald.conf.d/00-journal-size.conf` — so only the second
night is on record. Its boot ends on:

```
systemd[1]: Reached target Sleep.
systemd[1]: Starting NVIDIA system suspend actions...
suspend[3177302]: nvidia-suspend.service
```

and nothing after; the next boot is cold. Missing are both the end of
`nvidia-suspend.service` and systemd's `Starting System Suspend...`, while
journald was still writing normally at that point — so the machine hung inside
`nvidia-sleep.sh suspend` (`chvt 63`, then `echo suspend > /proc/driver/nvidia/suspend`)
and **never entered S3 at all**. Screens off since 03:40:10, power on: it looks
like a failed S3 from the outside.

What preceded it, and the likely trigger: **DP-3 dropped and re-acquired its
DisplayPort link twice**, at 03:34:40 and 03:42:30 (`removed iface 74` / `75`,
re-added 3-4s later, waybar SIGABRT-ing on the second one). That is the shape of
the documented 615-branch regressions — a DP power-cycle wedges `nvidia-modeset`
on the RM lock, and the suspend hook then blocks on it forever:
<https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1392>,
<https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1371>,
<https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1394>,
<https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1380>. The reporter of
#1392 says it did not happen on 610.57.04; this box moved to 615.71.09 around
15 Sep and to 615.78.08 on 12 Oct, and both nights froze, so it is not specific
to the newer of the two.

Why it surfaced only now: the machine almost never suspends, because caffeine
mode is usually on. The two nights it tried are the two nights it froze.

Changed in response, one thing at a time: the VRAM save path (see the NVIDIA
section above) and the caffeine gate on the suspend listener. **Still untested
and still the next experiments if it freezes again:** DP-3 at `3440x1440@120`,
then `@59.96`, then a downgrade to 610.57.04.

### Earlier

Useful historical observations:

- On 2026-06-23, a normal idle wake showed `toggle-dpms.sh on` succeeding.
- Around 40 seconds later, logs showed DP-3 removed and re-added.
- Waybar also logged `Bar removed from output: DP-3`, then reconfigured DP-3.
- That points more toward DisplayPort link/output renegotiation than a helper
  simply forgetting to enable DPMS.
- DP-3 is the Samsung Odyssey G85SB at `3440x1440@174.96`.

If problems continue after returning to the baseline, the next controlled tests
should be:

1. Run DP-3 at `3440x1440@120` for several days.
2. Then test `3440x1440@59.96`.
3. Test one change at a time and record exact dates, kernel version, NVIDIA
   version, Hyprland version, and whether the failure followed DPMS-only or real
   suspend.

## Live Root Cleanup

The source now encodes the baseline, but some live root-level cleanup may need
manual sudo if it has not already been applied.

Check current state:

```sh
systemctl is-enabled nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service
systemctl is-enabled hyprland-suspend.service hyprland-resume.service niri-suspend.service niri-resume.service 2>/dev/null || true
cat /proc/driver/nvidia/params | rg 'PreserveVideo|UseKernel|TemporaryFilePath'
cat /proc/cmdline
cat /sys/power/mem_sleep
```

Expected after reboot:

- NVIDIA services: enabled.
- Compositor suspend/resume services: not found or disabled.
- `PreserveVideoMemoryAllocations: 1`.
- `UseKernelSuspendNotifiers: 1`.
- `TemporaryFilePath: "/var/tmp"`.
- No `mem_sleep_default=...` in `/proc/cmdline`.
- No `nvidia-drm.fbdev=1` in `/proc/cmdline`.

Cleanup commands:

```sh
sudo systemctl disable hyprland-suspend.service hyprland-resume.service niri-suspend.service niri-resume.service
sudo rm -f /etc/systemd/system/hyprland-suspend.service /etc/systemd/system/hyprland-resume.service /etc/systemd/system/niri-suspend.service /etc/systemd/system/niri-resume.service
sudo systemctl daemon-reload

sudo rm -f /etc/modprobe.d/zz-nvidia-local.conf /etc/modprobe.d/blacklist-spd5118.conf
sudo sed -i '/fbdev=1/d; s/[[:space:]]*NVreg_UseKernelSuspendNotifiers=0//g' /etc/modprobe.d/nvidia.conf
sudo sed -i -E 's/[[:space:]]+nvidia-drm\.fbdev=1//g; s/[[:space:]]+mem_sleep_default=[^"[:space:]]+//g; s/  +/ /g' /etc/default/grub
sudo mkinitcpio -P
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

Reboot after running those commands.

## Verification After Reboot

Run:

```sh
hyprctl version
hyprlock --version
hypridle --version
nvidia-smi --query-gpu=driver_version,name --format=csv,noheader
systemctl --user status hypridle.service --no-pager
systemctl --user status hypridle-watchdog.service --no-pager
systemctl is-enabled nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service
systemctl is-enabled hyprland-suspend.service hyprland-resume.service niri-suspend.service niri-resume.service 2>/dev/null || true
cat /proc/driver/nvidia/params | rg 'PreserveVideo|UseKernel|TemporaryFilePath'
cat /proc/cmdline
cat /sys/power/mem_sleep
```

Expected:

- `hypridle.service` active.
- `hypridle-watchdog.service` not found.
- NVIDIA services enabled.
- Custom compositor suspend services absent/disabled.
- NVIDIA params match the baseline above.
- No forced sleep mode in the kernel command line.

## Debugging Rules Going Forward

- Keep only one experiment active at a time.
- Prefer changing monitor mode/refresh before adding more suspend scripts.
- Do not reintroduce compositor STOP/CONT services unless a current upstream
  NVIDIA or Hyprland issue explicitly recommends it.
- Do not override `NVreg_UseKernelSuspendNotifiers` unless testing a single
  controlled hypothesis.
- Do not force `mem_sleep_default` in shared dotfiles; document machine-local
  sleep-mode choices separately.
- Record exact dates and package versions for every failure and fix attempt.
