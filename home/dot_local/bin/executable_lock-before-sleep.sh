#!/bin/bash
# Lock the session and let hyprlock paint a frame *before* the machine suspends.
#
# Run under `systemd-inhibit --what=sleep --mode=delay` by lock-before-sleep.service,
# so the whole point is where this sits: logind holds the suspend open until this
# process exits, which is the only window in which anything can still draw.
#
# The defect it closes: logind revokes the session's DRM master on its way down
# (`[libseat] Disabling seat` in the hyprland log, then every atomic commit failing
# "Permission denied"), so from that instant nothing can paint. The panel keeps
# scanning out the last framebuffer that did land — the desktop — and that is what
# you see for several seconds after waking, before hyprlock repaints. The session
# is locked the whole time; what leaks is the picture.
#
# Why this is not hooked to the lid, which is where the symptom is noticed:
# closing the lid is one of four ways into a suspend here (`Mod+Ctrl+L`, wlogout's
# suspend button and hypridle's idle timer are the others) and they all leak the
# same frame. The defect belongs to the sleep transition, so the fix waits at the
# transition and every trigger inherits it.
#
# Why not hypridle, which advertises exactly this: both of its modes release too
# early, for two different reasons. `before_sleep_cmd` is spawned with runAsync()
# and the inhibitor is dropped immediately after (mode 1), and mode 3 releases
# inside onLocked(), which fires on the lock-notify event — before any lock frame
# is painted. Measured on this machine: lid closed at 17:06:08.7, "Releasing the
# sleep inhibitor!" the same second, hyprlock still binding its Wayland globals.
# Not tunable. Hence our own inhibitor rather than a knob.
#
# What this deliberately does NOT do is suspend. logind still owns that, and its
# InhibitDelayMaxSec (5s here) is the ceiling: blow it and the machine suspends
# anyway, exactly as it did before this existed. That is the whole reason this
# shape was chosen over taking the lid switch away from logind — the guarantee
# that a closed laptop suspends stays enforced *against* us instead of *by* us,
# and it still holds when there is no compositor running at all.
set -u

# gdbus, not dbus-monitor: dbus-monitor asks for new-style monitoring, is refused
# as a non-root user ("Sender is not authorized to send message") and falls back
# to eavesdropping, which the system bus also denies — so it would sit there
# looking healthy and never see the signal. gdbus places an ordinary match rule,
# which is all a broadcast signal needs. It comes from glib2, not optional here.
#
# `< <(…)` and NOT a pipeline — this is the whole reason the first two versions
# silently did nothing. bash waits for *every* process in a pipeline, so when the
# reader breaks out, it still waits on gdbus; gdbus only dies of SIGPIPE when it
# next writes, and after PrepareForSleep no further signal comes, so it never
# writes, never dies, and the script blocks forever *after* matching. Everything
# still looked fine from outside: logind timed the delay out at InhibitDelayMaxSec,
# hyprlock got its window from the 5s stall, and the symptom was cured by the
# wrong thing. `NRestarts=0` and a lid-to-sleep of exactly 5.17s were the only
# tells. Process substitution is not waited on, so `break` really does continue.
#
# The `(true` is the payload: PrepareForSleep is emitted with false on the way back
# up, and the object also emits PropertiesChanged for LidClosed and the inhibitor
# counts, so the match has to be on the member *and* the argument.
while read -r line; do
    case "$line" in
    *"PrepareForSleep (true"*) break ;;
    esac
done < <(gdbus monitor --system \
    --dest org.freedesktop.login1 \
    --object-path /org/freedesktop/login1)

# We do NOT lock. hypridle's `before_sleep_cmd = loginctl lock-session` already
# does, on this same signal — locking is the one part it gets right, and the only
# thing it gets wrong is releasing its inhibitor before the frame is painted,
# which is exactly what this script is here to replace. So the split is: hypridle
# locks, we hold the window open.
#
# A `loginctl lock-session` here as well is not harmless, and cost a debugging
# round: both callers fire within the same millisecond, so hypridle's
# `lock_cmd = pidof hyprlock || hyprlock` runs its guard twice before either
# hyprlock exists and starts **two** of them. They then fight over the fingerprint
# reader — one claims it, verifies and unlocks *itself* ("Unlock called, but not
# locked yet"), while the one actually holding the session lock is refused the
# device ("could not claim device, AlreadyInUse") and stays on screen. The symptom
# is a fingerprint that does nothing on wake.
# The two log lines are the whole diagnostic surface, and they are worth keeping:
# a version of this that never receives the signal and one that receives it and
# then hangs are indistinguishable from outside — that is how the first two
# versions passed a real lid test while doing nothing (logind timed the delay out
# and hyprlock got its window from the 5s stall). "waiting" without "settled", or
# `NRestarts` stuck at 0, is the signature.
logger -t lock-before-sleep -- "PrepareForSleep(true) — waiting for the lock frame"

# Already locked — a manual Mod+Alt+L, or the idle timer — means the frame landed
# long ago and there is nothing to wait for. Settling anyway is pure delay, and it
# is what made `Mod+Alt+L` followed by `Mod+Ctrl+L` feel like the machine had hung:
# a locked, unresponsive screen for the whole settle before the suspend.
if pidof hyprlock >/dev/null 2>&1; then
    logger -t lock-before-sleep -- "already locked — releasing immediately"
    exit 0
fi

started=$(date +%s.%N)

# hyprlock's pid appears well before its first frame, so the settle is what
# actually buys the painted frame. What it has to cover is the **screencopy**, not
# the fade: hypridle's lock_cmd passes --no-fade-in, and measured across two locks
# `onLockLocked` lands 7-14ms after "Gathered all screencopy frames" every time,
# while the screencopy itself swings between 16ms and 422ms depending on what the
# compositor is doing. So the worst seen is ~0.5s from lock request to final frame,
# and 1s is a little over twice that.
#
# Do not derive this from the log line "Starting fade in" — it is printed whether
# or not the fade runs, which is what made a slow screencopy look like a fade that
# had ignored the flag.
#
# Bounded: a hyprlock that never starts costs 3s and then lets the suspend
# proceed, because holding the inhibitor longer cannot help and logind would
# take the window back at InhibitDelayMaxSec regardless.
SETTLE_SECS=1
for ((i = 0; i < 30; i++)); do
    if pidof hyprlock >/dev/null 2>&1; then
        sleep "$SETTLE_SECS"
        break
    fi
    sleep 0.1
done

# Report the margin instead of assuming it. A settle that is too short reopens the
# leak, and that is the one failure here nothing else would report: the machine
# suspends, wakes, and only a human looking at the screen would notice. hyprlock's
# own output lands in hypridle's journal because hypridle spawns it, and
# "onLockLocked" is the moment its frame is final — so the margin we actually had
# is measurable, every cycle, for one journalctl in a path that runs a few times a
# day. A negative margin, or no frame at all, then says so in words.
locked=$(journalctl --user -u hypridle --since "@${started%%.*}" -o short-unix --no-pager 2>/dev/null |
    grep -F "onLockLocked" | tail -n1 | cut -d' ' -f1)
if [ -n "$locked" ]; then
    logger -t lock-before-sleep -- "$(awk -v a="$started" -v b="$locked" -v c="$(date +%s.%N)" \
        'BEGIN { printf "settled — frame landed %dms in, margin %dms", (b - a) * 1000, (c - b) * 1000 }')"
else
    logger -t lock-before-sleep -- "settled — NO LOCK FRAME OBSERVED, the desktop may show on wake"
fi

# Exiting is the release: systemd-inhibit holds the lock for exactly as long as
# this process lives, so there is nothing to drop by hand. The unit's Restart=
# takes a fresh inhibitor for the next cycle once the machine is back up.
