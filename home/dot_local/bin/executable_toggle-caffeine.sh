#!/bin/bash

# Toggle caffeine mode: prevent the session from going idle (lock/dpms/suspend).
#
# Hyprland: start a wl_surface-backed idle inhibitor; Hyprland honors it
# even when the surface is unmapped, so hypridle stops receiving idle events.

. "$HOME/.local/lib/compositor.sh"

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
STATE_FILE="$RUNTIME_DIR/caffeine-state"
PID_FILE="$RUNTIME_DIR/caffeine-inhibitor.pid"
INHIBITOR="$HOME/.local/bin/wayland-idle-inhibitor.py"

find_inhibitors() {
    local pid command_line

    if read -r pid 2>/dev/null < "$PID_FILE" \
        && [[ "$pid" =~ ^[0-9]+$ ]] \
        && kill -0 "$pid" 2>/dev/null; then
        command_line=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
        if [[ " $command_line " == *" $INHIBITOR "* ]]; then
            printf '%s\n' "$pid"
            return
        fi
    fi

    # Pick up an inhibitor started by the pre-PID-file version during an update.
    pgrep -f -x "python3 $INHIBITOR" 2>/dev/null || true
    pgrep -f -x "/usr/bin/python3 $INHIBITOR" 2>/dev/null || true
}

# Success is silent — the waybar caffeine module watches the state file and
# flips instantly; only failures notify.
if is_hyprland; then
    mapfile -t inhibitor_pids < <(find_inhibitors)
    if [ "${#inhibitor_pids[@]}" -gt 0 ]; then
        kill "${inhibitor_pids[@]}" 2>/dev/null || true
        for _ in {1..50}; do
            alive=false
            for pid in "${inhibitor_pids[@]}"; do
                kill -0 "$pid" 2>/dev/null && alive=true
            done
            "$alive" || break
            sleep 0.02
        done

        if "$alive"; then
            notify-send -u critical "Caffeine" "Idle inhibitor did not stop" || true
            exit 1
        fi

        rm -f "$PID_FILE"
        echo off > "$STATE_FILE"
    else
        rm -f "$PID_FILE"
        startup_dir=$(mktemp -d "$RUNTIME_DIR/caffeine-start.XXXXXX")
        ready_file="$startup_dir/ready"
        error_log="$startup_dir/error.log"

        cleanup_startup() {
            rm -f "$ready_file" "$error_log"
            rmdir "$startup_dir" 2>/dev/null || true
        }
        trap cleanup_startup EXIT

        CAFFEINE_READY_FILE="$ready_file" \
            nohup "$INHIBITOR" >"$error_log" 2>&1 &
        inhibitor_pid=$!

        for _ in {1..50}; do
            if [ -f "$ready_file" ] && kill -0 "$inhibitor_pid" 2>/dev/null; then
                echo "$inhibitor_pid" > "$PID_FILE"
                echo on > "$STATE_FILE"
                disown "$inhibitor_pid" 2>/dev/null || true
                exit 0
            fi
            kill -0 "$inhibitor_pid" 2>/dev/null || break
            sleep 0.02
        done

        kill "$inhibitor_pid" 2>/dev/null || true
        wait "$inhibitor_pid" 2>/dev/null || true
        echo off > "$STATE_FILE"

        error=$(tail -n 1 "$error_log")
        [ -n "$error" ] || error="Idle inhibitor did not become ready"
        notify-send -u critical "Caffeine" "$error" || true
        exit 1
    fi
else
    notify-send -u critical "Caffeine" "Unsupported compositor: ${XDG_CURRENT_DESKTOP:-unknown}" || true
    exit 1
fi
