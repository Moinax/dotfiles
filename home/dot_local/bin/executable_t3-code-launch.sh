#!/usr/bin/env bash
# t3-code-launch — put T3 Code in front, starting it if it is down.
#
# Called by `t3-thread open` with --start-only before opening a native draft,
# and by `t3-thread focus` when its deep-link socket is missing. Both ask again,
# detached, to raise the window after navigation. Also fine to run by hand.
# There is deliberately no "toggle": T3 Code holds every running
# agent, so a second call must never hide it the way a vicinae menu closes.
#
# Why not just run the AppImage every time: T3 Code is single-instance and its
# `second-instance` handler does reveal the existing window, so a bare launch
# would work — but it boots a whole Electron process just to hand the lock over
# and quit. Raising an existing window costs two hyprctl calls instead.
set -euo pipefail

# Wait for startup without stealing focus from Vicinae before `t3 app`.
start_only=false
case "${1:-}" in
    --start-only) start_only=true ;;
    "") ;;
    *) echo "Usage: t3-code-launch.sh [--start-only]" >&2; exit 1 ;;
esac

# Native Wayland builds use the desktop app ID; older builds use t3code.
# Character classes keep the regex valid inside the dispatcher's Lua string.
class_pattern='^(t3code|com[.]t3tools[.]T3Code)$'

window_present() {
    hyprctl clients -j 2>/dev/null | jq -e --arg pattern "$class_pattern" \
        'any(.[]; (.class // "") | test($pattern))' >/dev/null
}

active_is_t3() {
    hyprctl activewindow -j 2>/dev/null | jq -e --arg pattern "$class_pattern" \
        '(.class // "") | test($pattern)' >/dev/null
}

# Classic dispatcher syntax prints a lua error and still exits 0 on this
# Hyprland (lua config), so the `hl.dsp.*` form is the only one that works —
# and the exit code can never be trusted to tell us it did.
raise() {
    hyprctl dispatch "hl.dsp.focus({ window = \"class:${class_pattern}\" })" >/dev/null 2>&1 || true
}

if ! window_present; then
    # Launch through the desktop entry `t3fork install` registers, never the
    # AppImage path directly — the entry is what carries the icon and the
    # t3code:// handler, and it is the one thing guaranteed to point at the
    # fork build. Exactly once: the wait below is what replaces retrying.
    # Electron must not inherit capture()'s pipes and keep Vicinae waiting for
    # EOF until the app exits. Preserve startup errors in a file instead.
    launch_log="${XDG_STATE_HOME:-$HOME/.local/state}/dots/t3-code-launch.log"
    mkdir -p "$(dirname "$launch_log")"
    if ! setsid --wait gtk-launch t3-code </dev/null >>"$launch_log" 2>&1; then
        tail -n 20 "$launch_log" >&2
        exit 1
    fi
    for _ in $(seq 120); do
        window_present && break
        sleep 0.25
    done
    window_present || { echo "t3-code-launch: no T3 Code window after 30s; see $launch_log" >&2; exit 1; }
fi

$start_only && exit 0

# Raise, then check it stuck, and raise again while it has not.
#
# One raise is not enough when something else is mid-dismissal: a vicinae action
# still owns the keyboard while it runs, and the compositor hands focus back to
# whatever vicinae took it from as it closes, silently undoing the raise.
# Measured: the thread opened correctly and the browser stayed in front.
#
# This loop only works because callers reach it *detached* — while the caller is
# still blocking the dismissal it is waiting for, `active_is_t3` can never
# become true and the loop is guaranteed to burn its whole budget (1.3s,
# measured) for nothing. Run it in the foreground only when nothing is closing
# behind you, which is the by-hand case; the ordinary path exits on the first
# check.
for _ in $(seq 10); do
    active_is_t3 && exit 0
    raise
    sleep 0.12
done

# Never fatal. The link has already been delivered, so the thread is open on the
# screen it is on; only the raise lost, and saying so is better than a caller
# treating a focus race as a failed navigation.
active_is_t3 || echo "t3-code-launch: T3 Code did not take focus" >&2
