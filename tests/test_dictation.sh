#!/usr/bin/env bash
# Regression coverage for the dictation scripts behind Mod+D.
#
#   * dictation-lang set: writes the config line and the remembered choice, and
#     refuses — config untouched — while a dictation is still in flight.
#   * toggle-dictation.sh: wakes a recorder the overlay paused (SIGSTOP) before
#     acting, and only the daemon's own — a pw-record stopped elsewhere stays.
#   * hyprvoice-widget.py: reads `[recording] timeout` as the Go duration the
#     daemon does, so the timer warns before the clip is dropped.
#
# Run: bash tests/test_dictation.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANG_SCRIPT="$SCRIPT_DIR/../home/dot_local/bin/executable_dictation-lang"
TOGGLE="$SCRIPT_DIR/../home/dot_local/bin/executable_toggle-dictation.sh"

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
test_bin="$fixtures/bin"
mkdir -p "$test_home/.config/hyprvoice" "$test_home/.local/state" "$test_bin"

cleanup() {
    # Everything the run starts lives under $fixtures; continue before killing
    # so a stopped fixture process can actually receive the TERM.
    pkill -CONT -f "$fixtures" 2>/dev/null || true
    pkill -f "$fixtures" 2>/dev/null || true
    rm -rf "$fixtures"
}
trap cleanup EXIT

# `hyprvoice` stub: status comes from $HV_STATUS ("down" = no daemon answers),
# every other command is logged.
cat >"$test_bin/hyprvoice" <<'EOF'
#!/bin/bash
case "$1" in
    status) [ "$HV_STATUS" = down ] || echo "status=$HV_STATUS" ;;
    *) echo "$1" >>"$HV_LOG" ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' >"$test_bin/notify-send"
chmod +x "$test_bin/hyprvoice" "$test_bin/notify-send"

config="$test_home/.config/hyprvoice/config.toml"
state="$test_home/.local/state/hyprvoice-lang"
printf '[transcription]\nlanguage = "fr"\nstreaming = false\n' >"$config"

run_lang() {
    HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" \
    XDG_STATE_HOME="$test_home/.local/state" HV_STATUS="$1" HV_LOG="$fixtures/calls" \
    PATH="$test_bin:$PATH" bash "$LANG_SCRIPT" set "$2" >/dev/null 2>&1
}

echo "dictation-lang set"
run_lang down en
check "applies with the daemon down" 0 "$?"
check "config line rewritten" 'language = "en"' "$(grep '^language' "$config")"
check "choice remembered" en "$(cat "$state")"
check "rest of the config kept" 'streaming = false' "$(grep '^streaming' "$config")"

run_lang down auto
check "auto writes an empty language" 'language = ""' "$(grep '^language' "$config")"

run_lang transcribing fr
check "refuses while a dictation is in flight" 1 "$?"
check "config untouched when refused" 'language = ""' "$(grep '^language' "$config")"
check "memory untouched when refused" auto "$(cat "$state")"

echo "toggle-dictation.sh wakes only the daemon's paused recorder"
# A fake daemon named `hyprvoice` with a pw-record child, and a stranger
# pw-record: both stopped, as the overlay's pause and a Ctrl+Z would leave them.
ln -s "$(command -v sleep)" "$test_bin/pw-record"
cat >"$fixtures/hyprvoice" <<EOF
#!/bin/bash
"$test_bin/pw-record" 300 &
wait
EOF
chmod +x "$fixtures/hyprvoice"
"$fixtures/hyprvoice" &
daemon=$!
"$test_bin/pw-record" 300 &
stranger=$!
for _ in $(seq 1 20); do
    ours=$(pgrep -x -P "$daemon" pw-record) && break
    sleep 0.05
done
kill -STOP "$ours" "$stranger"

proc_state() { awk '/^State:/ { print $2 }' "/proc/$1/status"; }
check "ours stopped before the press" T "$(proc_state "$ours")"

HOME="$test_home" HV_STATUS=transcribing HV_LOG="$fixtures/calls" \
    PATH="$test_bin:$PATH" bash "$TOGGLE" >/dev/null 2>&1
sleep 0.1
check "daemon's recorder woken" S "$(proc_state "$ours")"
check "stranger left stopped" T "$(proc_state "$stranger")"
check "then toggled" toggle "$(tail -n 1 "$fixtures/calls")"

kill -STOP "$ours"
HOME="$test_home" HV_STATUS=transcribing HV_LOG="$fixtures/calls" \
    PATH="$test_bin:$PATH" bash "$TOGGLE" --cancel >/dev/null 2>&1
sleep 0.1
check "--cancel wakes it too" S "$(proc_state "$ours")"
check "then cancels" cancel "$(tail -n 1 "$fixtures/calls")"

echo "hyprvoice-widget.py reads the daemon's recording deadline"
# The pill turns its timer orange off this value; a misread Go duration warns
# at the wrong time or never. Imported, not run: no display needed.
WIDGET="$SCRIPT_DIR/../home/dot_local/bin/executable_hyprvoice-widget.py"
for case in 12m=720.0 1m30s=90.0 1h=3600.0 500ms=0.5 =300.0 bogus=300.0; do
    raw="${case%%=*}" want="${case#*=}"
    got=$(HYPRVOICE_WIDGET_PRELOADED=1 python3 -I - "$WIDGET" "$raw" 2>/dev/null <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("hvw", sys.argv[1])
hvw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hvw)
hvw.hyprvoice_config = lambda: {"recording": {"timeout": sys.argv[2]}}
print(hvw.recording_limit_s())
EOF
)
    check "timeout \"$raw\"" "$want" "$got"
done

echo
if [ "$failures" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failures check(s) failed."
    exit 1
fi
