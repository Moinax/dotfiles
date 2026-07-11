# _zj_pick HEADER — fuzzy-pick a zellij session via television, print its
# name to stdout. Returns non-zero (printing nothing) when there's no list
# or no tv available.
function _zj_pick
    if not command -q tv
        zellij ls >&2
        return 1
    end
    set -l list (zellij ls -n 2>/dev/null | string collect)
    if test -z "$list"; or string match -q '*No active*' -- $list
        echo "No Zellij sessions." >&2
        return 1
    end
    # television reads keys from stdin, so feed the list via --source-command
    # (not a pipe) and hand it the tty; the chosen line prints to stdout.
    set -l sel (tv --source-command 'zellij ls -n' --inline --no-status-bar --input-header $argv[1] </dev/tty)
    or return 1
    test -n "$sel"; and string split -f1 ' ' -- $sel
end
