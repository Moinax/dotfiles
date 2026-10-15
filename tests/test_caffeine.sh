#!/usr/bin/env bash
# Regression coverage for the caffeine startup handshake.
#
# Run: bash tests/test_caffeine.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOGGLE="$SCRIPT_DIR/../home/dot_local/bin/executable_toggle-caffeine.sh"
PYTHON_INHIBITOR="$SCRIPT_DIR/../home/dot_local/bin/executable_wayland-idle-inhibitor.py"

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

fixtures=$(mktemp -d)
test_home="$fixtures/home"
runtime_dir="$fixtures/runtime"
test_bin="$fixtures/bin"
inhibitor="$test_home/.local/bin/wayland-idle-inhibitor.py"
mkdir -p "$test_home/.local/bin" "$test_home/.local/lib" "$runtime_dir" "$test_bin"

cleanup() {
    # One pattern for everything the run can leave behind — the fixture
    # inhibitor and the real one below both live under $fixtures. A leaked idle
    # inhibitor is the expensive kind of leak: the session stops locking.
    pkill -f "$fixtures" 2>/dev/null || true
    rm -rf "$fixtures"
}
trap cleanup EXIT

printf '%s\n' 'is_hyprland() { return 0; }' > "$test_home/.local/lib/compositor.sh"
printf '%s\n' '#!/bin/bash' 'printf "%s\\n" "$*" >> "$NOTIFY_LOG"' \
    > "$test_bin/notify-send"
chmod +x "$test_bin/notify-send"

run_toggle() {
    HOME="$test_home" \
    XDG_RUNTIME_DIR="$runtime_dir" \
    NOTIFY_LOG="$fixtures/notifications" \
    PATH="$test_bin:$PATH" \
        bash "$TOGGLE"
}

echo "PyWayland imports"
if python3 - "$PYTHON_INHIBITOR" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("wayland_idle_inhibitor", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
PY
then
    import_result=loaded
else
    import_result=failed
fi
check "installed PyWayland API loads" "loaded" "$import_result"

echo "successful startup"
# The inhibitor owns the state file: writing "on" is the readiness signal the
# toggle waits for, and writing "off" on the way out is what keeps the waybar
# icon from claiming caffeine after the inhibition is gone.
cat > "$inhibitor" <<'FIXTURE'
#!/bin/bash
trap 'echo off > "$CAFFEINE_STATE_FILE"; exit 0' TERM INT
echo on > "$CAFFEINE_STATE_FILE"
# `sleep 1 & wait`, not `sleep 1`: bash defers a trap until the foreground
# command returns, so a plain sleep would answer SIGTERM up to a second late —
# the toggle gives it exactly one second before calling the stop a failure.
while :; do sleep 1 & wait; done
FIXTURE
chmod +x "$inhibitor"

run_toggle
check "state turns on after readiness" "on" "$(cat "$runtime_dir/caffeine-state")"
check "ready process gets a PID file" "yes" \
    "$([ -s "$runtime_dir/caffeine-inhibitor.pid" ] && echo yes || echo no)"
pgrep -f "$inhibitor" >/dev/null && running=yes || running=no
check "ready inhibitor remains alive" "yes" "$running"

run_toggle
check "second toggle turns state off" "off" "$(cat "$runtime_dir/caffeine-state")"
check "second toggle removes PID file" "no" \
    "$([ -e "$runtime_dir/caffeine-inhibitor.pid" ] && echo yes || echo no)"
pgrep -f "$inhibitor" >/dev/null && running=yes || running=no
check "second toggle stops inhibitor" "no" "$running"

echo "stale on from a killed inhibitor"
# The state file is the readiness handshake now, so an "on" left by an inhibitor
# that was SIGKILLed must not satisfy it — this is the only check that fails if
# the toggle stops clearing the file before launching.
cat > "$inhibitor" <<'FIXTURE'
#!/bin/bash
trap 'exit 0' TERM INT
while :; do sleep 1 & wait; done
FIXTURE
chmod +x "$inhibitor"
echo on > "$runtime_dir/caffeine-state"

run_toggle >/dev/null 2>&1 && status=0 || status=$?
check "stale on does not pass the handshake" "1" "$status"
check "stale on ends off" "off" "$(cat "$runtime_dir/caffeine-state")"
check "stale on leaves no PID file" "no" \
    "$([ -e "$runtime_dir/caffeine-inhibitor.pid" ] && echo yes || echo no)"

echo "failed startup"
# Writes "on" before failing: without it the state assertion below is vacuous,
# since the toggle already cleared the file before the launch.
printf '%s\n' '#!/bin/bash' 'echo on > "$CAFFEINE_STATE_FILE"' \
    'echo "simulated import failure" >&2' 'exit 1' \
    > "$inhibitor"
chmod +x "$inhibitor"

run_toggle >/dev/null 2>&1 && status=0 || status=$?
check "startup failure is returned" "1" "$status"
check "failed startup leaves state off" "off" "$(cat "$runtime_dir/caffeine-state")"
# The notification is backgrounded (-A makes notify-send wait for the click), so
# it can land just after the toggle exits.
for _ in {1..50}; do
    case "$(tail -n 1 "$fixtures/notifications")" in
        *"simulated import failure") break ;;
    esac
    sleep 0.02
done
check "failure reaches notification" \
    "-u critical -A default=Open -c x-open -h string:x-open-path:$runtime_dir/caffeine-inhibitor.log Caffeine simulated import failure" \
    "$(tail -n 1 "$fixtures/notifications")"

echo "state file ownership, real inhibitor"
# Nothing else proves the contract the toggle now relies on, and it only holds
# against a live compositor — the run inhibits idle for the second it lasts.
# From a copy named like the installed script, because both the toggle and
# hypridle's suspend gate match on `.../wayland-idle-inhibitor.py`: a leak
# running under the `executable_` source name would inhibit idle while being
# invisible to every control that can stop it.
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    real_inhibitor="$fixtures/wayland-idle-inhibitor.py"
    cp "$PYTHON_INHIBITOR" "$real_inhibitor"
    real_state="$fixtures/real-state"
    echo off > "$real_state"
    CAFFEINE_STATE_FILE="$real_state" \
        python3 "$real_inhibitor" > "$fixtures/real.log" 2>&1 &
    real_pid=$!
    for _ in {1..100}; do
        [ "$(cat "$real_state")" = on ] && break
        kill -0 "$real_pid" 2>/dev/null || break
        sleep 0.05
    done
    check "live inhibitor writes on" "on" "$(cat "$real_state")"

    # Bounded on the contract, then SIGKILL: an inhibitor that cannot answer
    # SIGTERM is the bug under test, and a bare `wait` would hang the suite on it.
    kill "$real_pid" 2>/dev/null
    for _ in {1..20}; do
        [ "$(cat "$real_state")" = off ] && break
        sleep 0.05
    done
    kill -9 "$real_pid" 2>/dev/null
    wait "$real_pid" 2>/dev/null
    check "dying inhibitor writes off" "off" "$(cat "$real_state")"
else
    echo "  skip (no WAYLAND_DISPLAY)"
fi

echo
if [ "$failures" -eq 0 ]; then
    echo "all checks passed"
else
    echo "$failures check(s) failed"
fi
exit "$failures"
