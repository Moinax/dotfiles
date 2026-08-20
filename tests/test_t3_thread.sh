#!/usr/bin/env bash
# The one thing t3-thread has to get right about a cold app: a runtime file is
# not a running server.
#
# `server-runtime.json` outlives a kill, and a reboot — the way it goes stale in
# practice — hands its pid straight back out from the bottom of the range. Read
# as "is it running?", it sends a dispatch to a dead port and reports it three
# calls later as a refused connection; read as a pid alone, it believes whatever
# process inherited the number.
#
# Run: bash tests/test_t3_thread.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The script under test sets -e for its own run; sourcing it would carry that
# into this one, where the first failing check would end the suite instead of
# counting.
source "$SCRIPT_DIR/../home/dot_local/bin/executable_t3-thread"
set +e

failures=0
check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ok   $label"
    else
        echo "  FAIL $label: expected '$expected', got '$actual'"
        failures=$((failures + 1))
    fi
}

stage="$(mktemp -d)"
runtime="$stage/server-runtime.json"
trap 'rm -rf "$stage"; kill "${server:-}" "${impostor:-}" 2>/dev/null' EXIT

# `comm` is the name of the executable, so a copy under the app's name is a
# faithful stand-in for the real process — and the only way to exercise the
# "it is running" branch without an Electron.
cp "$(command -v sleep)" "$stage/t3code"
"$stage/t3code" 30 & server=$!
sleep 30 & impostor=$!

# Every case writes the same shape the app writes, differing only in the pid.
write_runtime() { printf '{"version":1,"pid":%s,"origin":"http://127.0.0.1:3773"}\n' "$1" > "$runtime"; }

write_runtime "$server"
server_up; check "a live t3code process is up" 0 $?

write_runtime "$impostor"
server_up; check "a live process that is not t3code is down" 1 $?

reaped=$(bash -c 'echo $$')
write_runtime "$reaped"
server_up; check "a reaped pid is down" 1 $?

printf '{"version":1,"origin":"http://127.0.0.1:3773"}\n' > "$runtime"
server_up; check "a runtime file with no pid is down" 1 $?

rm -f "$runtime"
server_up; check "no runtime file is down" 1 $?

# The warm path: a predicate that already answers must short-circuit, because
# everything past it starts an Electron and then waits 15s on it.
already_ready() { return 0; }
ensure_app already_ready; check "a ready predicate short-circuits" 0 $?

if [ "$failures" -eq 0 ]; then
    echo "t3-thread: all checks passed"
else
    echo "t3-thread: $failures check(s) failed" >&2
fi
exit "$((failures > 0))"
