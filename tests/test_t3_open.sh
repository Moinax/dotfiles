#!/usr/bin/env bash
# Exercise cold/warm draft opening without launching Electron or touching T3 state.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
export T3_TEST_STAGE="$stage"
export T3CODE_REPO="$stage/cli"
export XDG_STATE_HOME="$stage/state"
mkdir -p "$stage/bin" "$stage/cli/apps/server/dist" "$stage/repo with spaces"
cp "$repo/home/dot_local/bin/executable_t3-code-launch.sh" "$stage/bin/t3-code-launch.sh"

cat > "$stage/bin/hyprctl" <<'SH'
#!/usr/bin/env bash
case "$1" in
    clients)
        if [[ -f "$T3_TEST_STAGE/window" ]]; then
            jq -nc --arg c "$T3_TEST_CLASS" '[{class:$c}]'
        else
            echo '[]'
        fi ;;
    activewindow) jq -nc --arg c "$T3_TEST_CLASS" '{class:$c}' ;;
    *) echo 'Unexpected compositor interaction' >&2; exit 1 ;;
esac
SH
cat > "$stage/bin/gtk-launch" <<'SH'
#!/usr/bin/env bash
echo launch >> "$T3_TEST_STAGE/events"
if [[ -f "$T3_TEST_STAGE/launch-fails" ]]; then
    echo 'simulated desktop-entry failure' >&2
    exit 1
fi
[[ -f "$T3_TEST_STAGE/no-window" ]] || touch "$T3_TEST_STAGE/window"
SH
cat > "$stage/bin/setsid" <<'SH'
#!/usr/bin/env bash
case "$1" in
    --wait) shift; exec "$@" ;;
    -f) echo raise >> "$T3_TEST_STAGE/events" ;;
    *) exit 1 ;;
esac
SH
cat > "$stage/bin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$stage/cli/apps/server/dist/bin.mjs" <<'JS'
import { appendFileSync, existsSync, unlinkSync } from 'node:fs';
const stage = process.env.T3_TEST_STAGE;
if (!existsSync(`${stage}/window`)) throw new Error('CLI called before startup');
appendFileSync(`${stage}/events`, `${JSON.stringify(process.argv.slice(2))}\n`);
if (existsSync(`${stage}/draft-race`)) {
  unlinkSync(`${stage}/draft-race`);
  console.error('T3 Code could not open the project (thread-open-failed).');
  process.exit(1);
}
if (existsSync(`${stage}/cli-fails`)) {
  console.error('simulated draft failure');
  process.exit(1);
}
JS
chmod +x "$stage/bin/"*
export PATH="$stage/bin:$PATH"
export T3_TEST_CLASS=com.t3tools.T3Code
open_draft() { bash "$repo/home/dot_local/bin/executable_t3-thread" open "$stage/repo with spaces"; }
expected_cli="$(jq -nc --arg p "$stage/repo with spaces" '["app",$p]')"

open_draft
[[ "$(< "$stage/events")" == $'launch\n'"$expected_cli"$'\nraise' ]]
echo 'ok: cold startup precedes native draft opening; path stays one argument'

: > "$stage/events"
open_draft
[[ "$(< "$stage/events")" == "$expected_cli"$'\nraise' ]]
echo 'ok: warm opening does not launch another app'

export T3_TEST_CLASS=t3code
: > "$stage/events"
open_draft
[[ "$(< "$stage/events")" == "$expected_cli"$'\nraise' ]]
echo 'ok: older t3code window class remains supported'
export T3_TEST_CLASS=com.t3tools.T3Code

# Check focus detection through the real launcher, not the detached-call mock.
bash "$repo/home/dot_local/bin/executable_t3-code-launch.sh"
echo 'ok: current Wayland window is recognized as focused'

touch "$stage/draft-race"
: > "$stage/events"
open_draft
[[ "$(< "$stage/events")" == "$expected_cli"$'\n'"$expected_cli"$'\nraise' ]]
rg -q 'thread-open-failed' "$stage/state/dots/t3-thread.log"
echo 'ok: cancelled draft navigation retries once and records the original failure'

touch "$stage/cli-fails"
: > "$stage/events"
if open_draft 2> "$stage/error"; then exit 1; fi
[[ "$(< "$stage/events")" == "$expected_cli" ]]
rg -q 'simulated draft failure' "$stage/error"
echo 'ok: CLI failure reaches the picker and prevents focus handoff'
rm "$stage/cli-fails" "$stage/window"

touch "$stage/launch-fails"
: > "$stage/events"
if open_draft 2> "$stage/error"; then exit 1; fi
[[ "$(< "$stage/events")" == launch ]]
rg -q 'simulated desktop-entry failure' "$stage/error"
echo 'ok: launch failure is reported before any draft request'
rm "$stage/launch-fails"

touch "$stage/no-window"
: > "$stage/events"
if open_draft 2> "$stage/error"; then exit 1; fi
[[ "$(< "$stage/events")" == launch ]]
rg -q 'no T3 Code window after 30s' "$stage/error"
echo 'ok: startup timeout does not dispatch a draft request'
