#!/bin/bash
# Toggle Hyprland DPMS for all monitors.
#
# Hyprland's plain "dpms off" bind can leave input wake unreliable because the
# manual bind bypasses hypridle's on-resume hook. Use a one-shot swayidle
# instance so the next mouse/key event explicitly powers outputs back on.
set -euo pipefail

runtime_dir="${XDG_RUNTIME_DIR:-/tmp}"
pidfile="${runtime_dir}/toggle-dpms-wakeup.pid"

stop_wakeup_listener() {
    if [[ -f "$pidfile" ]]; then
        pid="$(<"$pidfile")"
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
        rm -f "$pidfile"
    fi
}

state="$(hyprctl monitors -j)"

if jq -e 'length > 0 and all(.[]; .dpmsStatus == false)' >/dev/null <<<"$state"; then
    stop_wakeup_listener
    exec hyprctl dispatch 'hl.dsp.dpms("on")'
fi

stop_wakeup_listener

if command -v swayidle >/dev/null 2>&1; then
    (
        echo "$BASHPID" > "$pidfile"
        trap 'rm -f "$pidfile"' EXIT
        swayidle -w \
            timeout 1 "hyprctl dispatch 'hl.dsp.dpms(\"off\")'" \
            resume "hyprctl dispatch 'hl.dsp.dpms(\"on\")'; kill -TERM \"\$PPID\""
    ) >/dev/null 2>&1 &
    disown
    exit 0
fi

exec hyprctl dispatch 'hl.dsp.dpms("off")'
