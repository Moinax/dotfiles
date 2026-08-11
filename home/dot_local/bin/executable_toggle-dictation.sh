#!/bin/bash

# Toggle speech-to-text dictation via hyprvoice
# Bound to Mod+D in Hyprland

set -e

LOG="${XDG_STATE_HOME:-$HOME/.local/state}/hyprvoice.log"

# `--lang en`: transcribe this one dictation in English, then hand the language
# back to whatever dictation-lang remembers. Bound to Mod+Alt+D, and it exists
# because Whisper decides the language per clip from the audio alone — on
# French-accented English it lands on French and *translates* rather than
# mis-spells. See the comment block in dictation-lang for the measurements.
#
# Parsed before anything else so a bare Mod+D keeps exactly the shape it had.
# Read, not consumed: nothing below this line touches a positional, and the
# `shift 2` that used to follow was the whole failure mode of a mistyped
# `--lang` with no value — shift past the end returns non-zero, and under
# `set -e` that ends the script before the toggle, silently.
ONESHOT_LANG=""
if [ "${1:-}" = "--lang" ]; then
    ONESHOT_LANG="${2:-}"
fi

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

# The language has to be in the daemon *before* the toggle: the pipeline is
# built from the config at toggle time, and writing it afterwards would not
# reconfigure the recording but destroy it (a reload calls stopPipeline()).
# So this costs the reload — ~1s — before the mic opens, which is the whole
# reason the sticky switch exists alongside it: a language already in the file
# writes nothing and waits for nothing.
if [ "$starting" = yes ] && [ -n "$ONESHOT_LANG" ] && command -v dictation-lang &>/dev/null; then
    dictation-lang oneshot "$ONESHOT_LANG" || true
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
