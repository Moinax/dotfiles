# shellcheck shell=sh
# Detaching a GUI from a script that must not outlive it.
# Source from ~/.local/bin/* scripts:
#   . "$HOME/.local/lib/spawn.sh"
#   spawn_detached "$app/binary" "$@"
#
# The desktop launches T3 Code into a systemd scope (`app-t3code-N.scope`), and
# everything started from inside it — a script, an agent's shell, whatever they
# spawn — inherits that cgroup. When the app goes down systemd tears the scope
# down and kills every process still in it, so a GUI started with plain `setsid`
# dies with the app that launched it: `setsid` makes a new POSIX session, which
# is not a new cgroup.
#
# `systemd-run --user` puts it in a transient unit of its own instead, and
# `--same-dir` keeps the caller's working directory, which it would otherwise
# swap for $HOME (a bare `codiff` then opened some other repository). The flip
# side is the caller's to handle: the directory it spawns from is the one the
# app — and every terminal the app opens — inherits, so spawn from where the app
# should start. setsid remains the fallback for a machine with no systemd, where
# nothing tears a cgroup down and it is sufficient.
#
# `ELECTRON_RUN_AS_NODE` is dropped on the way out: T3 Code exports it to every
# process it spawns, so an agent shell inside it hands the variable to whatever
# it launches — and an Electron app started with it set runs as plain Node and
# tries to execute its first argument as a script. systemd-run happens to dodge
# this by starting from the user manager's environment rather than ours, but the
# setsid fallback would inherit it — so both branches clear it rather than one
# relying on a property of the other.
spawn_detached() {
    if command -v systemd-run >/dev/null 2>&1; then
        systemd-run --user --collect --quiet --same-dir \
            -- env -u ELECTRON_RUN_AS_NODE "$@" >/dev/null 2>&1 && return
    fi
    setsid -f env -u ELECTRON_RUN_AS_NODE "$@" >/dev/null 2>&1 </dev/null
}
