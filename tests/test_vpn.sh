#!/usr/bin/env bash
# Regression coverage for the VPN switch: the TSV contract two independent
# consumers parse (waybar-vpn.sh and exact_lib/system.ts), and the mutual
# exclusion that keeps NetBird's 100.64/10 routes off Tailscale's peers.
#
# Run: bash tests/test_vpn.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOGGLE="$SCRIPT_DIR/../home/dot_local/bin/executable_toggle-vpn.sh"
MODULE="$SCRIPT_DIR/../home/dot_local/bin/executable_waybar-vpn.sh"

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
test_bin="$fixtures/bin"
test_home="$fixtures/home"
mkdir -p "$test_bin" "$test_home/.local/bin"
trap 'rm -rf "$fixtures"' EXIT

# The module shells out to $HOME/.local/bin/toggle-vpn.sh — the applied copy —
# so the fake HOME gets the script under test under its applied name.
cp "$TOGGLE" "$test_home/.local/bin/toggle-vpn.sh"
chmod +x "$test_home/.local/bin/toggle-vpn.sh"

# Stub daemons. Each reads its up/down state from a file so a `down` in one
# invocation is visible to the `status` of the next, and appends every call to
# CALL_LOG so the ordering assertions below have something to read.
cat > "$test_bin/tailscale" <<'STUB'
#!/bin/bash
echo "tailscale $*" >> "$CALL_LOG"
case "$1" in
    status)
        [ -f "$STATE_DIR/ts" ] || exit 1
        echo "100.64.0.1     moinax-desktop  jerome@  linux   -"
        ;;
    up)   touch "$STATE_DIR/ts" ;;
    down) rm -f "$STATE_DIR/ts" ;;
esac
STUB
cat > "$test_bin/netbird" <<'STUB'
#!/bin/bash
echo "netbird $*" >> "$CALL_LOG"
case "$1" in
    status)
        if [ -f "$STATE_DIR/nb" ]; then
            echo "Management: Connected"
            echo "FQDN: moinax-desktop.o27.lan"
            echo "NetBird IP: 100.81.212.251/16"
        else
            echo "Daemon status: NeedsLogin"
        fi
        ;;
    # The gate is what the switching block below uses to hold a switch open the
    # way a browser SSO login does. Nothing creates $STATE_DIR/block until then,
    # so every earlier test sees a plain `up`.
    up)   while [ -f "$STATE_DIR/block" ]; do sleep 0.05; done; touch "$STATE_DIR/nb" ;;
    down) rm -f "$STATE_DIR/nb" ;;
esac
STUB
printf '#!/bin/bash\nexit 0\n' > "$test_bin/pkill"
# Unstubbed, the failure paths below would fire real desktop notifications — and
# logged, it is the only thing that can assert on them: a detached switch reports
# a failure here and nowhere else.
printf '#!/bin/bash\necho "notify-send $*" >> "$CALL_LOG"\nexit 0\n' > "$test_bin/notify-send"
chmod +x "$test_bin/tailscale" "$test_bin/netbird" "$test_bin/pkill" "$test_bin/notify-send"

state="$fixtures/state"
mkdir -p "$state"
run() {
    : > "$fixtures/calls"
    HOME="$test_home" PATH="$test_bin:$PATH" \
        STATE_DIR="$state" CALL_LOG="$fixtures/calls" \
        XDG_RUNTIME_DIR="$fixtures" \
        bash "$@"
}
marker="$fixtures/vpn-switching"
calls() { tr '\n' '|' < "$fixtures/calls" | sed 's/|$//'; }

echo "list — the four-field contract"
rm -f "$state"/*
check "both off, two rows" \
    "tailscale	0	Tailscale	|netbird	0	NetBird (O27)	" \
    "$(run "$TOGGLE" list | tr '\n' '|' | sed 's/|$//')"

touch "$state/ts"
check "tailscale row carries host and IP" \
    "tailscale	1	Tailscale	moinax-desktop — 100.64.0.1" \
    "$(run "$TOGGLE" list | head -1)"

touch "$state/nb"
check "netbird row strips the prefix length" \
    "netbird	1	NetBird (O27)	moinax-desktop.o27.lan — 100.81.212.251" \
    "$(run "$TOGGLE" list | tail -1)"

echo "set — exclusive, and the other goes down first"
rm -f "$state"/*; touch "$state/ts"
run "$TOGGLE" set netbird >/dev/null 2>&1
check "tailscale down precedes netbird up" \
    "tailscale status|tailscale down|netbird up --disable-auto-connect" \
    "$(calls)"
check "only netbird remains up" "0 1" \
    "$([ -f "$state/ts" ] && echo -n 1 || echo -n 0; echo -n ' '; [ -f "$state/nb" ] && echo 1 || echo 0)"

run "$TOGGLE" set tailscale >/dev/null 2>&1
check "netbird goes down before tailscale up" \
    "netbird status|netbird down|tailscale up" "$(calls)"

echo "down — one tunnel only"
rm -f "$state"/*; touch "$state/ts" "$state/nb"
run "$TOGGLE" down netbird >/dev/null 2>&1
check "tailscale survives a single-VPN disconnect" "1 0" \
    "$([ -f "$state/ts" ] && echo -n 1 || echo -n 0; echo -n ' '; [ -f "$state/nb" ] && echo 1 || echo 0)"

echo "off — both, even when the first teardown fails"
rm -f "$state"/*; touch "$state/ts" "$state/nb"
run "$TOGGLE" off >/dev/null 2>&1
check "both down" "0 0" \
    "$([ -f "$state/ts" ] && echo -n 1 || echo -n 0; echo -n ' '; [ -f "$state/nb" ] && echo 1 || echo 0)"

touch "$state/ts" "$state/nb"
printf '#!/bin/bash\necho "tailscale $*" >> "$CALL_LOG"\n[ "$1" = status ] && exit 0\nexit 1\n' \
    > "$test_bin/tailscale"
chmod +x "$test_bin/tailscale"
run "$TOGGLE" off >/dev/null 2>&1
check "netbird still torn down after tailscale fails" "0" \
    "$([ -f "$state/nb" ] && echo 1 || echo 0)"

echo "waybar module — one class per state"
cat > "$test_bin/tailscale" <<'STUB'
#!/bin/bash
echo "tailscale $*" >> "$CALL_LOG"
case "$1" in
    status) [ -f "$STATE_DIR/ts" ] || exit 1; echo "100.64.0.1     moinax-desktop  jerome@  linux   -" ;;
    up)   touch "$STATE_DIR/ts" ;;
    down) rm -f "$STATE_DIR/ts" ;;
esac
STUB
chmod +x "$test_bin/tailscale"
class_of() { run "$MODULE" | sed -n 's/.*"class": "\([^"]*\)".*/\1/p'; }

rm -f "$state"/*
check "nothing up" "disconnected" "$(class_of)"
touch "$state/ts"; check "tailscale up" "tailscale" "$(class_of)"
rm -f "$state/ts"; touch "$state/nb"; check "netbird up" "netbird" "$(class_of)"
touch "$state/ts"; check "both up is a conflict" "conflict" "$(class_of)"

# The reader failing must never read as "no VPN connected" — the bar would be
# asserting a state it could not observe.
mv "$test_home/.local/bin/toggle-vpn.sh" "$test_home/.local/bin/toggle-vpn.sh.bak"
check "unreadable state is not 'disconnected'" "unknown" "$(class_of)"
mv "$test_home/.local/bin/toggle-vpn.sh.bak" "$test_home/.local/bin/toggle-vpn.sh"

echo "switching — the bar carries the progress, and only while a switch is live"
rm -f "$state"/* "$marker"
# $STATE_DIR/block holds the stub's `up` open the way an expired token holds the
# real one: the point of the marker is that the shield says "switching" for
# exactly as long as that login takes.
touch "$state/block"
run "$TOGGLE" set netbird >/dev/null 2>&1 &
switch_pid=$!
for _ in $(seq 40); do [ -f "$marker" ] && break; sleep 0.05; done
check "a switch in flight reports switching" "switching" "$(class_of)"
rm -f "$state/block"
wait "$switch_pid"
check "the marker is gone once the switch returns" "0" \
    "$([ -f "$marker" ] && echo 1 || echo 0)"
check "and the bar reports the tunnel it brought up" "netbird" "$(class_of)"

# A marker left by a switch that was killed outright: no trap ran, so only the
# pid inside it can tell the bar that nobody is switching any more. The pid has
# to be one that is really gone — pid_max is 4194304 here, so a hardcoded 999999
# is a pid the machine can hand out, and the check would pass for the wrong
# reason the day it does.
( : ) & dead_pid=$!; wait "$dead_pid"
echo "$dead_pid" > "$marker"
check "a marker whose process is gone is not switching" "netbird" "$(class_of)"
rm -f "$marker"

echo "unknown id — a usage error must not look like a switch"
rm -f "$state"/* "$marker"
run "$TOGGLE" set bogus >/dev/null 2>/dev/null
check "no marker, no waybar signal, no notification" "0 " \
    "$([ -f "$marker" ] && echo -n 1 || echo -n 0; echo -n ' '; calls)"

echo "failure — the notification is the only report a detached switch has"
rm -f "$state"/* "$marker"
printf '#!/bin/bash\necho "netbird $*" >> "$CALL_LOG"\n[ "$1" = status ] && { echo "Daemon status: NeedsLogin"; exit 0; }\necho "needs login" >&2\nexit 1\n' \
    > "$test_bin/netbird"
chmod +x "$test_bin/netbird"
run "$TOGGLE" set netbird >/dev/null 2>/dev/null
check "a failed switch notifies, with the daemon's own stderr" \
    "notify-send -u critical VPN: Connecting netbird failed needs login" \
    "$(grep '^notify-send' "$fixtures/calls")"
check "and the marker does not survive the failure" "0" \
    "$([ -f "$marker" ] && echo 1 || echo 0)"

echo ""
if [ "$failures" -eq 0 ]; then
    echo "All VPN switch checks passed"
else
    echo "$failures check(s) failed"
fi
exit "$((failures > 0))"
