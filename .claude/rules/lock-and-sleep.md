---
description: Why locking before suspend is a delay inhibitor rather than a lid bind, the dead ends already paid for, and why systemd-logind must never be restarted on a live session.
paths:
  - home/dot_local/bin/executable_lock-before-sleep.sh
  - home/dot_config/systemd/user/lock-before-sleep.service
  - home/dot_config/hypr/hypridle.conf
  - home/dot_config/hypr/hyprlock.conf.tmpl
---

# Locking before a suspend

**It is a `delay` inhibitor, not a lid bind.** `lock-before-sleep.service` runs
`systemd-inhibit --what=sleep --mode=delay` around a script that waits for
`PrepareForSleep`, waits for hyprlock's frame, then exits; the exit *is* the
release.

logind revokes the session's DRM master on its way down (`[libseat] Disabling
seat`, then every atomic commit failing `Permission denied` in the hyprland log),
so from that instant nothing can draw and the panel keeps scanning out the last
frame that landed — the desktop.

**Fix it at the transition, never per trigger.** `Mod+Ctrl+L`, wlogout's suspend
button, hypridle's idle timer and the lid all pass through it. The first version
bound the lid alone, which meant taking `HandleLidSwitch` from logind and giving
up its guarantee that a closed laptop suspends. Here logind keeps it and
`InhibitDelayMaxSec` (5s) is the ceiling — overrun it and the machine suspends
anyway.

**The script must not lock.** hypridle's `before_sleep_cmd` already does, on the
same signal, and a second `loginctl lock-session` fires within the same
millisecond — so `lock_cmd = pidof hyprlock || hyprlock` runs its guard twice
before either exists and starts **two** hyprlocks, which then fight over the
fingerprint reader (one claims it and unlocks *itself*, the one holding the
session lock is refused and stays up). Worse, the loser survives unlocked, and
the next `pidof hyprlock` guard then finds it and starts nothing at all — a
session that does not lock. hypridle locks, this holds the window.

## Dead ends already paid for

- `after_sleep_cmd`, or a DPMS-ordering script: nothing can paint in that window.
- Tuning hypridle: both modes release too early — `before_sleep_cmd` is spawned
  with `runAsync()`, and mode 3 releases inside `onLocked()`, before any frame is
  painted.
- `dbus-monitor`: refused new-style monitoring as non-root, falls back to
  eavesdropping which the system bus also denies — it looks healthy and never
  fires.
- **Piping `gdbus` into the reader**, the subtlest: bash waits for every process
  in a pipeline, so after `break` it still waits on gdbus, which only dies of
  SIGPIPE when it next writes and never writes again — the script hangs *after*
  matching. Use `< <(…)`, which is not waited on. That one passed two real lid
  tests while doing nothing, because logind timed the delay out and hyprlock got
  its window from the 5s stall; `NRestarts=0` and a lid-to-sleep of exactly 5.17s
  were the only tells.

## What the settle must cover

The **screencopy**, not the fade. `lock_cmd` passes `--no-fade-in` (the fade
blended from a screencopy of the desktop, so its first commits showed what the
lock hides), and `onLockLocked` then lands 7-14ms after "Gathered all screencopy
frames" every time, while the screencopy itself swings 16-422ms.

Never read the settle off the log line "Starting fade in" — it prints whether or
not the fade runs, which made a slow screencopy look like a flag being ignored.
Healthy reads ~1.1s lid-to-sleep, with the frame final ~90ms in and logind
starting 5ms after the release.

## Never restart systemd-logind on a live graphical session

`reload` is what you want (`CanReload=yes`). logind hands out the DRM leases the
compositor holds through libseat, and it supervises `plasmalogin.service`, so a
restart revokes the display from the running session *and* respawns the greeter.

What you get is not a crash: the session's processes survive (audio keeps
playing), but the compositor has lost the screen and the greeter is showing, so
every login opens a *new* session while the orphaned one still owns the display —
you bounce back to the greeter forever and only a reboot clears it. This cost two
reboots here, both times from a "pick up the new logind.conf.d drop-in"
instruction.

`sudo systemctl reload systemd-logind` applies config changes with no session
impact; when in doubt, say the setting lands at the next boot.
