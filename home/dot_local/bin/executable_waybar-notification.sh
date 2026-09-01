#!/bin/bash
# Waybar notification module wrapper for SwayNC
# Shows only the bell icon when count is 0, bell + count otherwise

BELL=$'\U000f009a'
subscriber_pid=
stream_fd=

stop_subscriber() {
    if [[ -n $subscriber_pid ]]; then
        kill "$subscriber_pid" 2>/dev/null || true
        wait "$subscriber_pid" 2>/dev/null || true
        subscriber_pid=
    fi

    if [[ -n $stream_fd ]]; then
        exec {stream_fd}<&- 2>/dev/null || true
        stream_fd=
    fi
}

trap 'exit 0' INT TERM
trap stop_subscriber EXIT

format_line() {
    local line=$1 count matched replacement

    if [[ ! $line =~ \"text\":\ *\"([^\"]*)\" ]]; then
        printf '%s\n' "$line"
        return
    fi

    matched=${BASH_REMATCH[0]}
    count=${BASH_REMATCH[1]}
    if [[ $count == 0 ]]; then
        replacement="\"text\": \"$BELL\""
    else
        replacement="\"text\": \"$BELL $count\""
    fi

    printf '%s\n' "${line/"$matched"/"$replacement"}"
}

# swaync-client survives a SwayNC crash, but its subscription remains attached
# to the old D-Bus owner. Track that daemon process and replace the client when
# the owner disappears so Waybar receives the new daemon's initial count.
while true; do
    daemon_pid=$(systemctl --user show --property MainPID --value \
        swaync.service 2>/dev/null) || daemon_pid=0

    exec {stream_fd}< <(exec swaync-client -swb)
    subscriber_pid=$!

    while true; do
        IFS= read -r -t 1 -u "$stream_fd" line
        read_status=$?
        if ((read_status == 0)); then
            format_line "$line"
        elif ((read_status == 1)); then
            # EOF means the client itself died. A timeout is greater than 128.
            break
        elif ((daemon_pid == 0)); then
            daemon_pid=$(systemctl --user show --property MainPID --value \
                swaync.service 2>/dev/null) || daemon_pid=0
        elif ! kill -0 "$daemon_pid" 2>/dev/null; then
            break
        fi
    done

    stop_subscriber
    sleep 0.1
done
