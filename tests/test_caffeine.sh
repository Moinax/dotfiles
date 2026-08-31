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
    pkill -f "$inhibitor" 2>/dev/null || true
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
printf '%s\n' \
    '#!/bin/bash' \
    'touch "$CAFFEINE_READY_FILE"' \
    "trap 'exit 0' TERM INT" \
    'while :; do sleep 1; done' \
    > "$inhibitor"
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

echo "failed startup"
printf '%s\n' '#!/bin/bash' 'echo "simulated import failure" >&2' 'exit 1' \
    > "$inhibitor"
chmod +x "$inhibitor"

run_toggle >/dev/null 2>&1 && status=0 || status=$?
check "startup failure is returned" "1" "$status"
check "failed startup leaves state off" "off" "$(cat "$runtime_dir/caffeine-state")"
check "failure reaches notification" "-u critical Caffeine simulated import failure" \
    "$(tail -n 1 "$fixtures/notifications")"

echo
if [ "$failures" -eq 0 ]; then
    echo "all checks passed"
else
    echo "$failures check(s) failed"
fi
exit "$failures"
