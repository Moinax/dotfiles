#!/bin/bash
# DPMS-off guard for hypridle.
#
# On this NVIDIA RTX 4090 + multi-monitor box, leaving the monitors DPMS-off for
# several minutes makes the driver fully unplug the outputs. On replug the pinned
# hyprlock 0.9.5 dereferences a destroyed wl_output and crashes (wl_display
# "invalid object"), which leaves the session UNLOCKED. Upstream's own workaround
# is "don't disable monitors while hyprlock is running" -- see hyprlock#953 and
# Hyprland discussion #11356. hyprlock can't be upgraded out of it here: the
# sdbus-cpp / hyprlock pin keeps hypridle 0.1.7-9 working (see
# check-hypridle-pin.sh and the project memory).
#
# Mitigation: skip DPMS-off whenever hyprlock is running (== session locked).
# hypridle locks at 300s and would DPMS-off at 330s, so in the normal idle path
# the screen now stays on (showing hyprlock) instead of risking the crash.
# DPMS-off still fires normally when the screen idles while unlocked.
#
# We key on `pidof hyprlock` rather than logind's LockedHint because hypridle
# runs as a session-agnostic user service (no XDG_SESSION_ID), and hyprlock's
# presence is the exact hazard upstream warns about ("don't disable monitors
# while hyprlock is running"). It also matches hypridle's own lock_cmd.
set -e

pidof hyprlock >/dev/null 2>&1 && exit 0

exec hyprctl dispatch 'hl.dsp.dpms("off")'
