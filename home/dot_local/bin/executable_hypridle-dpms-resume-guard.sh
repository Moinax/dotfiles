#!/bin/bash
# DPMS-on guard for hypridle's on-resume — the symmetric partner of
# hypridle-dpms-guard.sh.
#
# On this NVIDIA RTX 4090 + multi-monitor box, dispatching dpms("on") to outputs
# that are ALREADY on triggers a modeset that makes the Samsung Odyssey (DP-3)
# drop and re-establish its DisplayPort link. While hyprlock is up, that output
# hotplug breaks the pinned hyprlock 0.9.5 render path: the next keypress stalls
# its main loop, so PAM authenticates ("auth: authenticated for hyprlock") but it
# never reaches "Unlocking session" -- the screen stays black and the session
# wedges locked until a hard reboot (observed 2026-06-03, boots -1/-2).
#
# Because hypridle-dpms-guard.sh already SKIPS dpms-off whenever hyprlock is
# running, the screen is never actually off during a lock -- so the on-resume
# dpms("on") is pure, harmful redundancy in exactly the locked state that can't
# survive the modeset. Mitigation: skip dpms("on") while hyprlock is running.
# When unlocked (normal idle dpms-off path) hyprlock is absent, so dpms("on")
# fires as usual and the screen comes back.
set -e

pidof hyprlock >/dev/null 2>&1 && exit 0

exec hyprctl dispatch 'hl.dsp.dpms("on")'
