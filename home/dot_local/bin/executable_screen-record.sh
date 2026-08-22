#!/bin/bash

# Toggle a wf-recorder capture selected with slurp.
#
# Any start chord stops and keeps an existing recording. `cancel` stops it and
# removes the file. State lives in XDG_RUNTIME_DIR: it cannot become a stale
# recording across reboots, and the process name check prevents a recycled PID
# from ever being signalled.

set -u

runtime="${XDG_RUNTIME_DIR:-/tmp}"
state="$runtime/screen-record-${UID}.state"
recordings="${XDG_VIDEOS_DIR:-$HOME/Videos}/Recordings"

active_recording() {
    [ -r "$state" ] || return 1
    IFS=$'\t' read -r recorder_pid output_file < "$state" || return 1
    [ -n "${recorder_pid:-}" ] && [ -n "${output_file:-}" ] || return 1
    [ -r "/proc/$recorder_pid/comm" ] || return 1
    [ "$(< "/proc/$recorder_pid/comm")" = wf-recorder ]
}

finish() {
    local disposition="$1"
    if ! active_recording; then
        rm -f -- "$state"
        [ "$disposition" = cancel ] && notify-send -u low "Screen recording" "No recording is running."
        return 1
    fi

    kill -INT "$recorder_pid" 2>/dev/null || true
    for _ in {1..50}; do
        kill -0 "$recorder_pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$recorder_pid" 2>/dev/null; then
        notify-send -u critical "Screen recording could not stop" \
            "wf-recorder is still running; the recording was left untouched."
        return 1
    fi
    rm -f -- "$state"

    if [ "$disposition" = cancel ]; then
        rm -f -- "$output_file"
        notify-send -u low "Screen recording cancelled" "The unfinished video was deleted."
    elif [ -f "$output_file" ]; then
        notify-send -a "Screen recorder" -i "$output_file" -t 8000 \
            -A default=Open -c x-open -h "string:x-open-path:$output_file" \
            "Screen recording saved" "Video saved in <i>${output_file}</i>." >/dev/null 2>&1 &
    fi
}

select_geometry() {
    case "$1" in
        output)
            slurp -o -f '%x,%y %wx%h'
            ;;
        region)
            slurp -d
            ;;
        window)
            local visible_ids boxes
            visible_ids="$(hyprctl monitors -j | jq -c \
                '[.[] | .activeWorkspace.id, .specialWorkspace.id | select(. != 0)] | unique')" || return 1
            boxes="$(hyprctl clients -j | jq -r --argjson visible "$visible_ids" \
                '.[] | select(.workspace.id as $id | $visible | index($id)) |
                 "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"')" || return 1
            [ -n "$boxes" ] || return 1
            slurp -r <<< "$boxes"
            ;;
        *)
            return 2
            ;;
    esac
}

case "${1:-}" in
    cancel)
        finish cancel
        ;;
    toggle)
        if active_recording; then
            finish save
            exit
        fi
        rm -f -- "$state"
        mode="${2:-}"
        geometry="$(select_geometry "$mode")" || exit 0 # Escape cancels selection.
        mkdir -p -- "$recordings"
        output_file="$recordings/$(date +'%Y-%m-%d-%H%M%S_recording.mp4')"
        setsid wf-recorder -g "$geometry" -f "$output_file" \
            >"$runtime/screen-record-${UID}.log" 2>&1 &
        recorder_pid=$!
        sleep 0.2
        if ! kill -0 "$recorder_pid" 2>/dev/null; then
            notify-send -u critical "Screen recording failed" "wf-recorder could not start."
            exit 1
        fi
        printf '%s\t%s\n' "$recorder_pid" "$output_file" > "$state"
        # Progress state, not history: display it without retaining it in SwayNC.
        notify-send -e -u low -t 2500 "Screen recording started" \
            "Press any recording shortcut again to save, or Mod+Ctrl+R to cancel."
        ;;
    *)
        printf 'usage: %s toggle <output|window|region> | cancel\n' "$0" >&2
        exit 2
        ;;
esac
