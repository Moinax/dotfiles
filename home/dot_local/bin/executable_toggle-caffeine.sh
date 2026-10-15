#!/bin/bash

# Toggle caffeine mode: prevent the session from going idle (lock/dpms/suspend).
#
# Hyprland: start a wl_surface-backed idle inhibitor; Hyprland honors it
# even when the surface is unmapped, so hypridle stops receiving idle events.

. "$HOME/.local/lib/compositor.sh"

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
STATE_FILE="$RUNTIME_DIR/caffeine-state"
PID_FILE="$RUNTIME_DIR/caffeine-inhibitor.pid"
# Kept for the inhibitor's whole life, not just its startup. The startup-only
# version unlinked it on this script's exit, so an inhibitor that died hours
# later took its traceback down an unlinked fd and left nothing to explain a
# caffeine mode that had quietly stopped inhibiting. Truncated at each start, so
# it stays one run long.
LOG_FILE="$RUNTIME_DIR/caffeine-inhibitor.log"
INHIBITOR="$HOME/.local/bin/wayland-idle-inhibitor.py"

# One toggle at a time. Two instances from a double Mod+Alt+N tap both find no
# inhibitor, and the second one's state-file reset lands in the middle of the
# first one's readiness wait — which then times out, kills the inhibitor it had
# just started and notifies about a failure that did not happen. `9>&-` below
# keeps this fd out of the inhibitor, which outlives this script and would hold
# the lock for the rest of the session.
exec 9> "$RUNTIME_DIR/caffeine.lock"
flock 9

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
        # The inhibitor writes this itself on the way out; repeating it covers
        # the one started by a version that did not.
        echo off > "$STATE_FILE"
    else
        rm -f "$PID_FILE"
        # The inhibitor owns the state file: it writes "on" once the inhibition
        # exists and "off" however it dies, which is what stops the waybar icon
        # from claiming caffeine long after it stopped. Waiting for that write is
        # the readiness handshake, so a stale "on" left by an inhibitor that was
        # killed outright has to be cleared first, or the wait passes instantly.
        echo off > "$STATE_FILE"

        CAFFEINE_STATE_FILE="$STATE_FILE" \
            nohup "$INHIBITOR" >"$LOG_FILE" 2>&1 9>&- &
        inhibitor_pid=$!

        for _ in {1..50}; do
            if read -r state 2>/dev/null < "$STATE_FILE" \
                && [ "$state" = on ] \
                && kill -0 "$inhibitor_pid" 2>/dev/null; then
                echo "$inhibitor_pid" > "$PID_FILE"
                disown "$inhibitor_pid" 2>/dev/null || true
                exit 0
            fi
            kill -0 "$inhibitor_pid" 2>/dev/null || break
            sleep 0.02
        done

        # SIGTERM, a grace, then SIGKILL — never a bare `wait`. A python wedged
        # inside libwayland's own EINTR-retrying poll never acts on SIGTERM, and
        # waiting on it would hang this keybind for the rest of the session.
        kill "$inhibitor_pid" 2>/dev/null || true
        sleep 0.1
        kill -9 "$inhibitor_pid" 2>/dev/null || true
        wait "$inhibitor_pid" 2>/dev/null || true
        echo off > "$STATE_FILE"

        error=$(tail -n 1 "$LOG_FILE")
        [ -n "$error" ] || error="Idle inhibitor did not become ready"
        # Clickable through the generic swaync x-open hook, since the whole
        # traceback is in the log and the toast only carries its last line.
        # Backgrounded because -A makes notify-send wait for the click.
        notify-send -u critical \
            -A default=Open \
            -c x-open \
            -h "string:x-open-path:$LOG_FILE" \
            "Caffeine" "$error" >/dev/null 2>&1 &
        exit 1
    fi
else
    notify-send -u critical "Caffeine" "Unsupported compositor: ${XDG_CURRENT_DESKTOP:-unknown}" || true
    exit 1
fi
