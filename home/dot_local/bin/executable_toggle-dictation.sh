#!/bin/bash

# Toggle speech-to-text dictation via hyprvoice
# Bound to Mod+D in Hyprland

set -e

LOG="${XDG_STATE_HOME:-$HOME/.local/state}/hyprvoice.log"

if ! command -v hyprvoice &>/dev/null; then
    notify-send -u critical "Dictation" "hyprvoice is not installed"
    exit 1
fi

# One `hyprvoice status`, reused below: it answers both questions this script
# has — is the daemon up, and is it idle — and nothing else can toggle it in
# between. Asking twice spent two extra forks (status is 3-6ms measured, plus a
# grep each) on a keypress whose whole job is to feel instant.
# `|| true` because a missing binary is the one failure a command substitution
# would let `set -e` turn into a silent exit; the guard above already covers it.
status=$(hyprvoice status 2>/dev/null || true)

# Ensure the daemon is running (hyprvoice status always exits 0, check output instead)
if [[ "$status" != *status=* ]]; then
    # Keep the daemon's output: it is the only place a failed transcription
    # says *why* (bad API key, provider error, injection backend refusing).
    # Sent to /dev/null before, which made every failure look identical —
    # a silent recording that produced no text and no explanation.
    mkdir -p "$(dirname "$LOG")"
    # `setsid -f` so the daemon is not left a child of this script (a bare
    # `setsid` never forks here), and </dev/null so it never holds our stdin.
    setsid -f hyprvoice serve >>"$LOG" 2>&1 </dev/null
    # Wait up to 5s for daemon to be ready
    for _ in $(seq 1 10); do
        sleep 0.5
        status=$(hyprvoice status 2>/dev/null || true)
        [[ "$status" == *status=* ]] && break
    done
fi

# Which way this keypress goes, decided *before* toggling: idle means it starts
# a dictation, anything else means it ends one.
starting=no
# An `if`, not `[[ … ]] && starting=yes`: under `set -e` a bare and-list whose
# left side fails is the shape that quietly skips the rest of a script, and the
# failing case here is the *stop* press — the one that must still toggle.
if [[ "$status" == *status=idle* ]]; then
    starting=yes
fi

# Toggle recording on/off
hyprvoice toggle

# Only a starting press raises the overlay. Launching it on the stopping press
# too used to race the outgoing instance: the old pill exits the moment the
# daemon reports idle, so the new process could claim the single-instance slot
# mid-teardown and flash a second, empty pill over the finished dictation.
if [ "$starting" = yes ] && command -v hyprvoice-widget.py &>/dev/null; then
    setsid -f hyprvoice-widget.py >/dev/null 2>&1 </dev/null || true
fi
