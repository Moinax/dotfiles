# NVIDIA / Hyprland Idle + Suspend Baseline

Last updated: 2026-06-23

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
    after_sleep_cmd = hyprctl dispatch 'hl.dsp.dpms({ action = "enable" })'
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
    on-timeout = systemctl suspend
}
```

Rationale:

- `hyprlock` is the Hypr ecosystem locker and matches the Hyprland docs.
- `loginctl lock-session` lets logind/hypridle coordinate the lock path.
- `inhibit_sleep = 3` follows the documented pattern: inhibit suspend until the
  session is locked, then allow suspend.
- DPMS uses the documented Hyprland dispatcher directly.

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
- NVIDIA package default `NVreg_TemporaryFilePath=/var/tmp`

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
