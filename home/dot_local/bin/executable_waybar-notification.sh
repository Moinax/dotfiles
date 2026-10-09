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

# Waybar closes our stdout when it tears a bar down. Untrapped, SIGPIPE kills us
# outright and the EXIT trap never runs, which is what left swaync-client
# subscribers orphaned on systemd for days.
trap 'exit 0' INT TERM PIPE
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

# swaync-client survives a SwayNC restart, but its subscription stays attached to
# the dead D-Bus owner and goes silent. Exit when that daemon disappears and let
# the module's restart-interval respawn us against the new owner. Waybar owns the
# supervision either way: a bar teardown kills this script, and nothing here can
# resurrect it — that is how the bell used to freeze on a two-day-old count.
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
        exit 0
    elif ((daemon_pid == 0)); then
        daemon_pid=$(systemctl --user show --property MainPID --value \
            swaync.service 2>/dev/null) || daemon_pid=0
    elif ! kill -0 "$daemon_pid" 2>/dev/null; then
        exit 0
    fi
done
