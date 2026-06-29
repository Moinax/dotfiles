#!/usr/bin/env bash
# Exit 0 when vibewatch is installed and its version matches the latest release
# tag (vX.Y.Z) of the upstream repo (or the remote is unreachable / has no tags,
# in which case we trust the local install). Exit 1 otherwise.
#
# With --print-version, writes the installed version to stdout so callers can
# reuse it without re-spawning `vibewatch --version`. Used as the `check` field
# in packages/groups/ai.yaml (silent) and as the gate in `do_update`.
set -u

REPO=https://github.com/Moinax/vibewatch.git

print_version=false
[ "${1:-}" = "--print-version" ] && print_version=true

command -v vibewatch >/dev/null 2>&1 || exit 1

# `vibewatch --version` → "vibewatch 0.2.0 (abc123)"; take the semver field.
local_ver=$(vibewatch --version 2>/dev/null | awk '{print $2}')
[ -n "$local_ver" ] || exit 1
$print_version && echo "$local_ver"

latest_tag=$(git ls-remote --tags --refs "$REPO" 2>/dev/null \
    | awk -F/ '{print $NF}' | grep '^v[0-9]' | sort -V | tail -1)
# No tags yet or remote unreachable → trust the local install.
[ -z "$latest_tag" ] && exit 0

[ "v$local_ver" = "$latest_tag" ]
