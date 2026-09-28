#!/usr/bin/env bash
# Dispatch coverage for the codiff launcher.
#
# The launcher routes each invocation one of three ways, and every branch has
# already been wrong once:
#
#   - text-only flags must reach the bundled Node entry, or they print nothing
#     and exit 0 (--completions did exactly that);
#   - --plan and --share must stay in the foreground wherever they sit in the
#     argument list, or the plan handoff never blocks and the share URL is
#     discarded ("$1"-only matching missed `codiff HEAD --share`);
#   - everything else detaches with ELECTRON_RUN_AS_NODE cleared, or an agent
#     shell inside T3 Code — which exports it — starts the Electron binary as
#     plain Node and it dies trying to exec its first argument as a script.
#
# Run: bash tests/test_codiff.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="$SCRIPT_DIR/../home/dot_local/bin/executable_codiff"
SPAWN_LIB="$SCRIPT_DIR/../home/dot_local/lib/spawn.sh"

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
app="$test_home/.local/share/codiff"
trap 'rm -rf "$fixtures"' EXIT

mkdir -p "$app/resources/app/bin" "$test_home/.local/lib" "$test_bin"
cp "$SPAWN_LIB" "$test_home/.local/lib/spawn.sh"

# The app itself: records how it was invoked and what it inherited.
cat > "$app/codiff" <<'STUB'
#!/bin/sh
printf 'argv:%s\nnode:%s\n' "$*" "${ELECTRON_RUN_AS_NODE:-unset}" > "$CODIFF_LOG"
STUB
chmod +x "$app/codiff"
: > "$app/resources/app/bin/codiff.js"

# No systemd here: force spawn_detached onto its setsid fallback, and log the
# fallback's own argv rather than really detaching, so the check stays sync.
# shellcheck disable=SC2016  # the stub body must keep $* and $SYSTEMD_RUN_LOG literal
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" > "$SYSTEMD_RUN_LOG"' 'exit 1' > "$test_bin/systemd-run"
# shellcheck disable=SC2016  # the stub body must keep $* and $SETSID_LOG literal
printf '%s\n' '#!/bin/sh' 'printf "setsid:%s\n" "$*" > "$SETSID_LOG"' > "$test_bin/setsid"
chmod +x "$test_bin/systemd-run" "$test_bin/setsid"

run() {
    : > "$fixtures/codiff.log"
    : > "$fixtures/setsid.log"
    : > "$fixtures/systemd-run.log"
    HOME="$test_home" \
    CODIFF_LOG="$fixtures/codiff.log" \
    SETSID_LOG="$fixtures/setsid.log" \
    SYSTEMD_RUN_LOG="$fixtures/systemd-run.log" \
    PATH="$test_bin:$PATH" \
        sh "$LAUNCHER" "$@" >"$fixtures/stdout" 2>"$fixtures/stderr"
    echo "$?"
}

echo "Missing install is an error, not a silent no-op"
mv "$app/codiff" "$app/codiff.hidden"
rc=$(run --version)
check "exit code" "127" "$rc"
check "explains itself on stderr" "yes" \
    "$(grep -q 'not installed' "$fixtures/stderr" && echo yes || echo no)"
mv "$app/codiff.hidden" "$app/codiff"

echo "Text-only flags reach the Node entry"
for flag in --help -h --version -v --walkthrough-guide --completions; do
    run "$flag" >/dev/null
    check "$flag runs as node" "1" "$(sed -n 's/^node://p' "$fixtures/codiff.log")"
    check "$flag gets the js entry" "yes" \
        "$(grep -q 'codiff.js' "$fixtures/codiff.log" && echo yes || echo no)"
done
# Wherever they sit, on the same rule as --plan/--share: a text flag behind a
# positional used to reach the detached branch and print into /dev/null.
run HEAD --help >/dev/null
check "[HEAD --help] runs as node" "1" "$(sed -n 's/^node://p' "$fixtures/codiff.log")"
check "[HEAD --help] not detached" "" "$(cat "$fixtures/setsid.log")"

echo "--plan and --share stay in the foreground, wherever they sit"
for args in "--plan a.md" "--plan=a.md" "--share" "HEAD --share" "--plan a.md --share"; do
    # shellcheck disable=SC2086  # deliberate word splitting of the arg fixture
    run $args >/dev/null
    check "[$args] not detached" "" "$(cat "$fixtures/setsid.log")"
    check "[$args] node mode cleared" "unset" "$(sed -n 's/^node://p' "$fixtures/codiff.log")"
done

echo "Everything else detaches with the Electron/Node variable cleared"
ELECTRON_RUN_AS_NODE=1 run "HEAD~1" >/dev/null
check "went through setsid" "yes" \
    "$(grep -q '^setsid:' "$fixtures/setsid.log" && echo yes || echo no)"
check "cleared the variable" "yes" \
    "$(grep -q 'env -u ELECTRON_RUN_AS_NODE' "$fixtures/setsid.log" && echo yes || echo no)"
check "passed the argument through" "yes" \
    "$(grep -q 'HEAD~1' "$fixtures/setsid.log" && echo yes || echo no)"
check "systemd-run keeps the caller's directory" "yes" \
    "$(grep -q -- '--same-dir' "$fixtures/systemd-run.log" && echo yes || echo no)"
# Asserted on the branch that actually runs on a systemd machine, not only on
# the fallback: the lib says both clear it, so both are checked.
check "systemd-run cleared the variable" "yes" \
    "$(grep -q 'env -u ELECTRON_RUN_AS_NODE' "$fixtures/systemd-run.log" && echo yes || echo no)"

echo ""
if [ "$failures" -eq 0 ]; then
    echo "All checks passed"
else
    echo "$failures check(s) failed"
fi
exit $((failures > 0))
