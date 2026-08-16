#!/usr/bin/env bash
# What a scoped restore has to get right, and what it must never do.
#
# The droplet restores `--only labs,o27`: mbrella's secrets must not land on a
# machine that has no business holding them, and the repos left out must not
# then be reported as "absent from the backup" and offered for the trash — the
# scoped manifest describes part of the machine, not all of it.
#
# Run: bash tests/test_backup_scope.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../tools/backup-projects.sh"

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

make_stage() {
    local stage
    stage=$(mktemp -d)
    mkdir -p "$stage/manifest" \
             "$stage/projects/labs/fairbalance" \
             "$stage/projects/o27/socle" \
             "$stage/projects/mbrella/jacket"
    printf 'labs/fairbalance\thttps://github.com/Moinax/fairbalance.git\tmain\n' \
           > "$stage/manifest/repos.tsv"
    printf 'o27/socle\tssh://forgejo@git.postula.io/o27/socle.git\tmain\n' \
           >> "$stage/manifest/repos.tsv"
    printf 'mbrella/jacket\thttps://github.com/mbrella-eu/jacket.git\tmain\n' \
           >> "$stage/manifest/repos.tsv"
    # A repo sitting directly in ~/Projects, with no directory above it. Its
    # first `/` is the remote's, so anything deriving the scope from the whole
    # row instead of the first field reads "loose<TAB>https:" and drops it.
    mkdir -p "$stage/projects/loose"
    printf 'loose\thttps://github.com/Moinax/loose.git\tmain\n' \
           >> "$stage/manifest/repos.tsv"
    touch "$stage/projects/loose/.env"
    touch "$stage/projects/labs/fairbalance/.env.local" \
          "$stage/projects/o27/socle/.env" \
          "$stage/projects/mbrella/jacket/.env"
    printf '%s\n' "$stage"
}

echo "scope_of / scope_in_list"
check "top-level segment" "o27" "$(scope_of o27/socle)"
check "nested path still maps to its top level" "labs" "$(scope_of labs/t3code/apps/server)"
scope_in_list o27 "labs,o27" && r=yes || r=no
check "listed scope matches" "yes" "$r"
scope_in_list mbrella "labs,o27" && r=yes || r=no
check "unlisted scope does not match" "no" "$r"
# An empty list is "no opinion": it must never match, or an unset --exclude
# would reject every repo.
scope_in_list labs "" && r=yes || r=no
check "empty list matches nothing" "no" "$r"
# Substring must not count, or "o2" would match "o27".
scope_in_list o2 "o27" && r=yes || r=no
check "prefix is not a match" "no" "$r"

echo "prune_stage_to_scope --only labs,o27"
stage=$(make_stage)
prune_stage_to_scope "$stage" "labs,o27" ""
check "manifest keeps 2 repos" "2" "$(wc -l < "$stage/manifest/repos.tsv")"
check "top-level repo dropped by --only" "0" "$(grep -c '^loose' "$stage/manifest/repos.tsv")"
check "mbrella gone from manifest" "0" "$(grep -c mbrella "$stage/manifest/repos.tsv")"
check "o27 secrets kept" "yes" "$([ -f "$stage/projects/o27/socle/.env" ] && echo yes || echo no)"
check "mbrella secrets pruned" "no" "$([ -d "$stage/projects/mbrella" ] && echo yes || echo no)"
rm -rf "$stage"

echo "prune_stage_to_scope --exclude mbrella"
stage=$(make_stage)
prune_stage_to_scope "$stage" "" "mbrella"
check "manifest keeps 3 repos" "3" "$(wc -l < "$stage/manifest/repos.tsv")"
check "top-level repo kept by --exclude" "1" "$(grep -c '^loose' "$stage/manifest/repos.tsv")"
check "its secrets kept too" "yes" "$([ -f "$stage/projects/loose/.env" ] && echo yes || echo no)"
check "labs secrets kept" "yes" "$([ -f "$stage/projects/labs/fairbalance/.env.local" ] && echo yes || echo no)"
check "mbrella secrets pruned" "no" "$([ -d "$stage/projects/mbrella" ] && echo yes || echo no)"
rm -rf "$stage"

echo "argument validation"
do_restore --home-only --no-home >/dev/null 2>&1 && r=accepted || r=rejected
check "--home-only with --no-home" "rejected" "$r"
do_restore --only labs --exclude mbrella >/dev/null 2>&1 && r=accepted || r=rejected
check "--only with --exclude" "rejected" "$r"
do_restore --home-only --only labs >/dev/null 2>&1 && r=accepted || r=rejected
check "--home-only with a scope" "rejected" "$r"

echo ""
if [ "$failures" -eq 0 ]; then
    echo "all checks passed"
else
    echo "$failures check(s) failed"
    exit 1
fi
