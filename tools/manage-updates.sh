#!/bin/bash
# Update Manager — refresh the tools the system package manager doesn't own.
#
# Deliberately NOT a system updater: pacman and AUR packages belong to
# cachy-update (arch-update), which already notifies and applies them. This
# covers only what it cannot see — curl-installed binaries, global npm
# packages, the fnm-managed Node, cargo/git installs, and tracked external
# apps — so the two never fight over the same file.
#
# Anything whose binary turns out to be owned by a pacman/AUR package is
# reported as managed and skipped rather than refreshed: several entries here
# also exist as distro packages, and re-running their curl installer would
# shadow the packaged copy with a stale one we'd then have to maintain.
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGES_DIR="$DOTFILES_DIR/packages"
GROUPS_DIR="$PACKAGES_DIR/groups"
COMMON_YAML="$PACKAGES_DIR/common.yaml"
APPS_TOOL="$DOTFILES_DIR/tools/manage-external-apps.py"

source "$DOTFILES_DIR/install/lib/common.sh"
source "$DOTFILES_DIR/install/lib/detect.sh"

install_interrupt_trap

load_distro_lib || exit 1

# Field separator for candidate/report records — the same Unit Separator the
# yaml parsers join with, so a value read from yaml can be re-joined here
# without re-checking that the two agree. Chosen because shell snippets in the
# yaml contain tabs, pipes and quotes.
US="$YAML_FIELD_SEP"
RS=$'\x1e'

# Both emitters join their fields with US rather than positionally, so a record
# can gain a field without every emitter having to count arguments.
#
# Candidates are terminated with a Record Separator because they carry the
# yaml's command fields verbatim, and those are multi-line shell snippets — a
# newline-terminated candidate would split one entry across several records.
# The report is newline-terminated so it can be filtered with grep; it never
# carries a command (see payload).
emit_candidate() {
    local IFS="$US"
    printf '%s%s' "$*" "$RS"
}

emit_row() {
    local IFS="$US"
    printf '%s\n' "$*"
}

# ── Environment ──────────────────────────────────────────────────────────────

# Put the fnm-managed Node on PATH so npm-based checks work under bash, where
# the interactive shell's fnm hook never ran. Memoised because several rows call
# it and `fnm env` is a subprocess; activate_fnm_node itself installs nothing,
# so a missing Node just means the npm rows report as unavailable. Not memoised
# inside activate_fnm_node: the installer re-activates on purpose after making a
# newly installed Node the default.
activate_node() {
    [ "${NODE_ACTIVATED:-false}" = true ] && return 0
    NODE_ACTIVATED=true
    activate_fnm_node
}

# ── Version handling ─────────────────────────────────────────────────────────

# First dotted-numeric run in a version string, so the many shapes upstream
# tools print all reduce to something comparable:
#   "television 0.15.9" / "v4.25.2" / "codex-cli 0.145.0"
#   "vibewatch 0.3.0 (2ebfa3ee)" / "2.1.219 (Claude Code)"
# Always succeeds: an unparseable string yields empty output. A non-zero return
# here would abort the scan through `set -e`, since every caller assigns it
# with a command substitution.
normalize_version() {
    local raw="$1"
    if [[ "$raw" =~ ([0-9]+(\.[0-9]+)+) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
    return 0
}

# Run a version command with stdin detached, so a probe that misbehaves can't
# consume the caller's input or leak stderr into the report.
#
# The whole output is matched, not just the first line: plenty of tools print a
# banner before the number (`eza --version` puts it on line 2), and the regex
# picks the first dotted-numeric run wherever it falls. Bounded to 5 lines so an
# unrelated digit deep in a usage dump can't be mistaken for a version when the
# probe is simply the wrong command.
probe_version() {
    local out
    out=$(eval "$1" </dev/null 2>/dev/null | head -5) || true
    normalize_version "$out"
}

# True when `latest` is genuinely newer than `cur`. Ordered with sort -V rather
# than compared for inequality, so an installed version that is *ahead* of the
# latest release (a prerelease, or a tag that lags its own binary) reads as
# current instead of as an update the user can apply but never clear.
version_is_outdated() {
    local cur="$1" latest="$2"
    [ -n "$cur" ] && [ -n "$latest" ] && [ "$cur" != "$latest" ] || return 1
    [ "$(printf '%s\n%s\n' "$cur" "$latest" | sort -V | tail -1)" = "$latest" ]
}

# ── Candidate collection ─────────────────────────────────────────────────────
#
# One record per updatable thing. The metadata fields are requested from yq in
# record order, so the batched read's output *is* the tail of the record and
# nothing has to count arguments: adding a field means adding it here and
# nowhere else. Every reader splits with CANDIDATE_FIELDS as its variable names.
#
# `update` is only ever a command; `updated_by` is only ever one of the closed
# set documented in packages/common.yaml. External apps are not collected here —
# they have their own updater, queried directly in build_report.
CANDIDATE_META=(binary npm updated_by version source update requires install check)
# kind ∈ tool | custom | npm | node | gap; `section` is the yaml key the entry
# came from, carried rather than derived from kind so no reader has to know the
# mapping.
CANDIDATE_FIELDS=(kind name file section "${CANDIDATE_META[@]}")

# Restrict the scan to named yaml entries. Empty means "everything", which is
# what `dots update` does; the installer's post-install refresh passes the
# entries it skipped as already installed, so a setup re-run offers to move
# those and nothing else — not the global npm packages, not Node, not the
# external apps, none of which setup put there.
declare -A ONLY_NAMES=()
ONLY_FILTER=false

set_only_filter() {
    local name
    for name in "$@"; do
        [ -n "$name" ] || continue
        ONLY_NAMES["$name"]=1
        ONLY_FILTER=true
    done
}

# `tools:` in common.yaml and `custom_install:` in a group file declare the same
# update metadata, so one collector reads both; only the kind label differs.
collect_section_candidates() {
    local file="$1" section="$2" kind="$3"
    [ -f "$file" ] || return 0

    local entry entry_kind fields=() i
    local "${CANDIDATE_META[@]}"
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue

        # Filter on the name before anything else: the yq read below is what
        # makes a scan slow, so a two-entry refresh must not pay for twenty.
        if $ONLY_FILTER && [ -z "${ONLY_NAMES[$entry]:-}" ]; then
            continue
        fi

        # One yq call per entry rather than one per field: the metadata reads
        # otherwise dominate the whole scan.
        mapfile -d "$YAML_FIELD_SEP" -t fields \
            < <(parse_entry_fields "$file" "$section" "$entry" "${CANDIDATE_META[@]}")
        for i in "${!CANDIDATE_META[@]}"; do
            printf -v "${CANDIDATE_META[$i]}" '%s' "${fields[$i]:-}"
        done

        case "$updated_by" in
            # Installed and tracked by the external-apps tool, which build_report
            # queries directly — listing it here too would double-report it
            # against the same release source.
            app) continue ;;
            # A deliberate opt-out (rofi-themes): nothing to compare, and the
            # only "update" would clobber hand-edited files.
            none) continue ;;
        esac

        # No metadata at all is a forgotten declaration, not an opt-out — say so
        # instead of dropping the entry, or the tool silently goes stale forever.
        if [ -z "$binary" ] && [ -z "$npm" ] && [ -z "$version" ] \
           && [ -z "$update" ] && [ -z "$updated_by" ]; then
            emit_candidate gap "$entry" "$file" "$section"
            continue
        fi

        # A global npm package resolves its versions through npm rather than a
        # binary probe; everything else about the entry still applies.
        entry_kind="$kind"
        [ -n "$npm" ] && entry_kind=npm
        emit_candidate "$entry_kind" "$entry" "$file" "$section" \
            "${fields[@]:0:${#CANDIDATE_META[@]}}"
    done < <(parse_entry_names "$file" "$section")
}

collect_candidates() {
    collect_section_candidates "$COMMON_YAML" tools tool

    local file
    for file in "$GROUPS_DIR"/*.yaml; do
        group_enabled "$file" || continue
        collect_section_candidates "$file" custom_install custom
    done

    # Node itself: fnm's default version vs the latest LTS. Never part of a
    # filtered scan — a setup re-run offers the entries setup skipped, and the
    # whole toolchain underneath them is not one of those.
    if ! $ONLY_FILTER; then
        command_exists fnm && emit_candidate node "node (LTS)"
    fi
    return 0
}

# ── Version lookups ──────────────────────────────────────────────────────────

declare -A OWNER=()        # binary -> "package US version", distro-owned only
declare -A LATEST_TAG=()   # owner/repo -> latest release tag
declare -A NPM_LATEST=()   # npm package -> latest version
declare -A NPM_CURRENT=()  # npm package -> installed version
NODE_LATEST=""             # latest Node LTS fnm offers
APP_ROWS=""                # `apps check-updates --porcelain` output
RATE_LIMIT_RESET=""        # epoch the GitHub quota frees up, if it was hit

# Which of the scan's binaries a distro package owns — those are cachy-update's
# job, not ours. One readlink and one pacman query for the whole scan (-Qo is a
# full database lookup), and resolved before any upstream lookup so an owned
# tool never spends rate-limited GitHub quota on a version we would discard.
resolve_owners() {
    local binary path names=() links=()
    for binary in "$@"; do
        [ -n "$binary" ] || continue
        # Symlinks are resolved below: ~/.local/bin/foo may point into /usr/bin.
        if path=$(command -v "$binary" 2>/dev/null) && [ -n "$path" ]; then
            names+=("$binary")
            links+=("$path")
        fi
    done
    [ ${#links[@]} -gt 0 ] || return 0

    # -m, not -f: it always prints one line per argument, so `reals` stays
    # index-aligned with `names` even if a path can't be canonicalised.
    local reals=()
    mapfile -t reals < <(readlink -m "${links[@]}")

    # Keyed by path, then looked up per name, so two entries whose binaries
    # resolve to the same file both learn about their owner.
    local -A owner_of=()
    local p pkg version
    while IFS=$'\t' read -r p pkg version; do
        if [ -n "$p" ]; then owner_of["$p"]="${pkg}${US}${version}"; fi
    done < <(package_owners "${reals[@]}")

    local i
    for i in "${!names[@]}"; do
        if [ -n "${owner_of[${reals[$i]}]:-}" ]; then
            OWNER["${names[$i]}"]="${owner_of[${reals[$i]}]}"
        fi
    done
    return 0
}

# Everything the scan needs from outside this machine, fetched at once. The five
# lookups are independent and each is dominated by network latency (0.2–1.7s),
# so running them one after another cost their sum instead of the slowest one.
#
# Each writes to its own file — a background job can't populate the parent's
# associative arrays — and the parsers below read them back after `wait`.
# GitHub releases go through the app tool, which fetches a whole batch
# concurrently through one cache: that is what keeps a scan inside the
# unauthenticated 60-requests/hour rate limit.
resolve_upstream() {
    local repos=("$@")
    activate_node

    local dir f
    dir=$(mktemp -d)
    for f in tags apps npm_outdated npm_installed node_lts; do : >"$dir/$f"; done

    if [ -x "$APPS_TOOL" ]; then
        if [ ${#repos[@]} -gt 0 ]; then
            printf '%s\n' "${repos[@]}" | sort -u \
                | xargs "$APPS_TOOL" latest-release >"$dir/tags" 2>/dev/null &
        fi
        # External apps are `dots apps`' own inventory, never a yaml entry, so
        # a filtered scan can't report them — and this check costs GitHub quota
        # the filtered lookups above still need.
        if ! $ONLY_FILTER; then
            "$APPS_TOOL" check-updates --porcelain >"$dir/apps" 2>/dev/null &
        fi
    fi
    if command_exists npm; then
        npm outdated -g --json 2>/dev/null \
            | jq -r 'to_entries[] | [.key, (.value.current // ""), (.value.latest // "")] | @tsv' \
            >"$dir/npm_outdated" 2>/dev/null &
        npm ls -g --depth=0 --json 2>/dev/null \
            | jq -r '(.dependencies // {}) | to_entries[] | [.key, (.value.version // "")] | @tsv' \
            >"$dir/npm_installed" 2>/dev/null &
    fi
    if ! $ONLY_FILTER && command_exists fnm; then
        fnm ls-remote --lts >"$dir/node_lts" 2>/dev/null &
    fi
    wait

    local repo tag
    while IFS=$'\t' read -r repo tag; do
        [ -n "$repo" ] || continue
        # Marker line, never a valid repo: the quota ran out, so the empty tags
        # in this batch mean "not checked" rather than "no release".
        if [ "$repo" = "#ratelimit" ]; then
            RATE_LIMIT_RESET="$tag"
            continue
        fi
        LATEST_TAG["$repo"]="$tag"
    done < "$dir/tags"

    # `npm outdated -g` only lists packages that are behind, so absence there
    # means up to date; the installed version of the rest comes from `npm ls -g`.
    local pkg cur latest
    while IFS=$'\t' read -r pkg cur latest; do
        [ -n "$pkg" ] || continue
        NPM_CURRENT["$pkg"]="$cur"
        NPM_LATEST["$pkg"]="$latest"
    done < "$dir/npm_outdated"
    while IFS=$'\t' read -r pkg cur; do
        [ -n "$pkg" ] || continue
        [ -n "${NPM_CURRENT[$pkg]:-}" ] || NPM_CURRENT["$pkg"]="$cur"
    done < "$dir/npm_installed"

    NODE_LATEST=$(normalize_version "$(tail -1 "$dir/node_lts" | awk '{print $1}')")
    APP_ROWS=$(<"$dir/apps")
    rm -rf "$dir"
    return 0
}

# ── Report building ──────────────────────────────────────────────────────────
#
# One report row per candidate. `file` and `payload` are what apply_row needs to
# act on the row: an npm package, an app name, or the yaml section the entry was
# declared in — never a command, so a multi-line install snippet can't split a
# newline-delimited row.
#
# `missing` and `absent` both mean "declared but not installed here", split
# because only one of them is fixable from this tool: a global npm package's
# whole install command is `npm install -g`, which apply_row already runs, while
# an absent binary entry needs its yaml `install:` and belongs to
# `dots packages sync`. Keeping them one status would have made actionable_rows
# either miss the recoverable half or offer the other half an action it cannot
# carry out.
REPORT_FIELDS=(status name cur latest detail kind file payload)
STATUS_ORDER=(outdated missing refresh unavailable self ok managed absent)

# Split one candidate record into variables named after CANDIDATE_FIELDS — the
# caller declares them local, so they land in its scope. The terminator is
# re-appended so `read` consumes the whole record: reading up to a newline would
# stop inside a multi-line command field.
read_candidate() {
    IFS="$US" read -r -d "$RS" "${CANDIDATE_FIELDS[@]}" <<< "$1$RS"
}

build_report() {
    local candidates record
    candidates=$(collect_candidates)
    local "${CANDIDATE_FIELDS[@]}"

    # Ownership first: it is one local query, and it decides which candidates are
    # worth a rate-limited GitHub lookup at all.
    local binaries=()
    while IFS="$US" read -r -d "$RS" "${CANDIDATE_FIELDS[@]}"; do
        [ -n "$binary" ] && binaries+=("$binary")
    done <<< "$candidates"
    resolve_owners ${binaries[@]+"${binaries[@]}"}

    # Then one batched lookup for every GitHub source still in play.
    local repos=()
    while IFS="$US" read -r -d "$RS" "${CANDIDATE_FIELDS[@]}"; do
        # An empty subscript is an error on an associative array, and entries
        # without a binary (gh-dash) can never be distro-owned anyway.
        if [ -n "$source" ] && { [ -z "$binary" ] || [ -z "${OWNER[$binary]:-}" ]; }; then
            repos+=("$source")
        fi
    done <<< "$candidates"
    resolve_upstream ${repos[@]+"${repos[@]}"}

    while IFS= read -r -d "$RS" record; do
        read_candidate "$record"
        [ -n "$name" ] || continue
        case "$kind" in
            node) build_node_row "$name" ;;
            npm)  build_npm_row "$record" ;;
            gap)  emit_row unavailable "$name" "?" "?" \
                      "no update metadata in $(basename "$file") — see packages/common.yaml" \
                      "$kind" "" "" ;;
            *)    build_binary_row "$record" ;;
        esac
    done <<< "$candidates"

    # External apps, straight from the tool that tracks them. Apps that are
    # current emit nothing; failures come through as FAIL rows so a check that
    # never completed is never mistaken for "up to date".
    local app installed latest
    while IFS='|' read -r app installed latest; do
        [ -n "$app" ] || continue
        case "$app" in
            '#ratelimit')
                RATE_LIMIT_RESET="$installed"
                ;;
            FAIL)
                emit_row unavailable "$installed" "?" "?" "could not reach ${latest}" app "" "$installed"
                ;;
            *)
                emit_row outdated "$app" "$installed" "$latest" "external app" app "" "$app"
                ;;
        esac
    done <<< "$APP_ROWS"

    # Carried out of the subshell build_report runs in as a marker row, for the
    # caller to warn about after rendering. Inert to every other reader: they
    # either walk STATUS_ORDER or filter by status.
    [ -n "$RATE_LIMIT_RESET" ] && printf '%s\n' "#ratelimit${US}${RATE_LIMIT_RESET}"
    return 0
}

# Self-updating tools are reported (a version diff is still useful) but never
# touched — their own updater owns the install directory.
emit_self_row() {
    local name="$1" cur="$2" latest="$3" kind="$4"
    local detail="self-updating"
    version_is_outdated "$cur" "$latest" && detail="self-updating — ${latest} available"
    emit_row self "$name" "${cur:-?}" "${latest:-—}" "$detail" "$kind" "" ""
}

# Emits a `managed` row and succeeds when a distro package owns the binary —
# then the tool is cachy-update's job, not ours. The package's version is used
# as the current one: it is already in hand from the ownership query, so no
# process is spawned, and some tools have no usable local probe anyway
# (hyprvoice only reports a protocol version, and only to a running daemon).
emit_managed_row() {
    local name="$1" binary="$2" kind="$3" vercmd="$4"
    local owner=""
    [ -n "$binary" ] && owner="${OWNER[$binary]:-}"
    [ -n "$owner" ] || return 1

    local cur
    cur=$(normalize_version "${owner#*"$US"}")
    [ -n "$cur" ] || cur=$(probe_version "${vercmd:-$binary --version}")
    emit_row managed "$name" "${cur:-?}" "—" "pacman: ${owner%%"$US"*}" "$kind" "" ""
    return 0
}

# Node itself, via fnm rather than a binary probe.
build_node_row() {
    local name="$1" cur
    activate_node
    cur=$(normalize_version "$(fnm current 2>/dev/null || true)")

    if [ -z "$cur" ] || [ -z "$NODE_LATEST" ]; then
        emit_row unavailable "$name" "${cur:-?}" "?" "fnm could not resolve versions" node "" ""
    elif version_is_outdated "$cur" "$NODE_LATEST"; then
        emit_row outdated "$name" "$cur" "$NODE_LATEST" "fnm — carries global npm packages over" node "" ""
    else
        emit_row ok "$name" "$cur" "$NODE_LATEST" "fnm" node "" ""
    fi
}

# Global npm packages: `npm outdated -g` already resolved both versions.
build_npm_row() {
    local "${CANDIDATE_FIELDS[@]}"
    read_candidate "$1"

    # Declaring `npm:` doesn't exempt an entry from the ownership rule: if a
    # distro package owns the binary, npm-installing over it is exactly the
    # collision the rule exists to prevent.
    emit_managed_row "$name" "$binary" npm "$version" && return 0

    activate_node
    if ! command_exists npm; then
        emit_row unavailable "$name" "?" "?" "npm not on PATH" npm "" "$npm"
        return 0
    fi

    # Neither lookup lists a package that isn't installed, so there is no version
    # to show on either side — and none is needed: the row's action is the same
    # `npm install -g` an up-to-date one would refresh with. This is the state a
    # Node version bump used to strand tools in (see install_node_lts), and the
    # one an actionable row makes recoverable on a machine already in it.
    local cur="${NPM_CURRENT[$npm]:-}" latest="${NPM_LATEST[$npm]:-}"
    if [ -z "$cur" ]; then
        emit_row missing "$name" "—" "—" "npm global ${npm} not installed here" npm "" "$npm"
    elif [ "$updated_by" = "self" ]; then
        emit_self_row "$name" "$cur" "$latest" npm
    elif version_is_outdated "$cur" "$latest"; then
        emit_row outdated "$name" "$cur" "$latest" "npm global" npm "" "$npm"
    else
        emit_row ok "$name" "$cur" "$cur" "npm global" npm "" "$npm"
    fi
}

# A tool with a binary on PATH: `tools:` and `custom_install:` entries alike.
build_binary_row() {
    local "${CANDIDATE_FIELDS[@]}"
    read_candidate "$1"

    # Is it even installed here? A declared `check` is the entry's own answer —
    # the same one `packages sync` gates on — and every custom_install entry has
    # one; failing that, a declared binary has to be on PATH.
    if { [ -n "$check" ] && ! run_entry_check "$check"; } \
       || { [ -z "$check" ] && [ -n "$binary" ] && ! command_exists "$binary"; }; then
        emit_row absent "$name" "—" "—" "not installed (dots packages sync)" "$kind" "" ""
        return 0
    fi

    # Owned by a distro package? Then it is cachy-update's job, not ours.
    emit_managed_row "$name" "$binary" "$kind" "$version" && return 0

    local cur latest=""
    cur=$(probe_version "${version:-$binary --version}")
    [ -n "$source" ] && latest=$(normalize_version "${LATEST_TAG[$source]:-}")

    if [ "$updated_by" = "self" ]; then
        emit_self_row "$name" "$cur" "$latest" "$kind"
        return 0
    fi

    # An actionable row carries where it was declared, not the command itself;
    # apply_row reads the command back from the yaml (see entry_update_command).
    if [ -z "${update:-$install}" ]; then
        emit_row unavailable "$name" "${cur:-?}" "${latest:-?}" "no update command declared" "$kind" "" ""
    elif [ -n "$requires" ] && ! command_exists "$requires"; then
        # The declared prerequisite is what `packages sync` gates the installer
        # on; an update runs the same kind of command, so gate it the same way
        # instead of letting it fail halfway through.
        emit_row unavailable "$name" "${cur:-?}" "${latest:-?}" \
            "requires ${requires}, which is not installed" "$kind" "" ""
    elif [ -n "$source" ] && [ -z "$latest" ]; then
        # A declared source that didn't resolve is NOT the same as having no
        # source: reporting it as a plain refresh would hide a failed check, and
        # refreshing anyway would reinstall blind. Say so and stay non-actionable.
        emit_row unavailable "$name" "${cur:-?}" "?" "could not resolve latest release of ${source}" "$kind" "" ""
    elif [ -z "$cur" ]; then
        emit_row unavailable "$name" "?" "${latest:-?}" "could not read the installed version" "$kind" "" ""
    elif [ -z "$latest" ]; then
        # No upstream version to compare against — offer a refresh, don't
        # invent a diff.
        emit_row refresh "$name" "$cur" "—" "no version source — refresh only" "$kind" "$file" "$section"
    elif version_is_outdated "$cur" "$latest"; then
        emit_row outdated "$name" "$cur" "$latest" "$source" "$kind" "$file" "$section"
    else
        emit_row ok "$name" "$cur" "$latest" "$source" "$kind" "$file" "$section"
    fi
}

# ── Rendering ────────────────────────────────────────────────────────────────

STATUS_COL=9
VERSION_COL=22
# Where a row's name starts: 2 indent + status + space + version + space.
DETAIL_INDENT=$((2 + STATUS_COL + 1 + VERSION_COL + 1))

# printf's %-Ns pads to a byte count, which drifts on the multi-byte glyphs the
# version column uses (→ between versions, — for "not applicable"). bash counts
# characters in ${#s} under a UTF-8 locale, so pad on that instead.
pad() {
    local s="$1" width="$2"
    local n=$(( width - ${#s} ))
    (( n < 0 )) && n=0
    printf '%s%*s' "$s" "$n" ""
}

# Colour and label per status. Kept as data: the label is padded separately from
# the colour so the escape sequence doesn't count towards the column width.
declare -A STATUS_COLOR=(
    [outdated]="$YELLOW" [refresh]="$BLUE"   [ok]="$GREEN"    [managed]="$PURPLE"
    [self]="$PURPLE"     [absent]="$YELLOW"  [unavailable]="$RED"
    [missing]="$YELLOW"
)
declare -A STATUS_LABEL=(
    [outdated]=update    [refresh]=refresh   [ok]=current     [managed]=pacman
    [self]=self          [absent]=absent     [unavailable]=unknown
    [missing]=install
)

# Print the report grouped by status, most actionable first.
# The row's fields are read into variables named by REPORT_FIELDS, a dynamic
# read the linter below cannot follow.
# shellcheck disable=SC2154
render_report() {
    local report="$1"
    local group group_rows any=false version_col
    local "${REPORT_FIELDS[@]}"

    for group in "${STATUS_ORDER[@]}"; do
        group_rows=$(grep "^${group}${US}" <<< "$report") || continue
        any=true
        echo ""
        while IFS="$US" read -r "${REPORT_FIELDS[@]}"; do
            version_col="$cur"
            [ "$status" = "outdated" ] && version_col="${cur} → ${latest}"

            # The status label is plain ASCII, so printf can pad it; the version
            # column needs pad() for its multi-byte glyphs.
            printf '  %b%-*s%b %s %s\n' \
                "${STATUS_COLOR[$status]:-$NC}" "$STATUS_COL" "${STATUS_LABEL[$status]:-$status}" "$NC" \
                "$(pad "$version_col" "$VERSION_COL")" "$name"
            [ -n "$detail" ] && printf '%*s↳ %s\n' "$DETAIL_INDENT" "" "$detail"
        done <<< "$group_rows"
    done

    [ "$any" = true ] || print_info "Nothing to report."
    return 0
}

# ── Applying ─────────────────────────────────────────────────────────────────

# How an entry refreshes itself: what `update:` declares, else re-running the
# (idempotent) `install:`. Read at apply time from the yaml the row came from, so
# no shell snippet ever has to survive a trip through the report.
entry_update_command() {
    local fields=()
    mapfile -d "$YAML_FIELD_SEP" -t fields \
        < <(parse_entry_fields "$1" "$2" "$3" update install)
    printf '%s' "${fields[0]:-${fields[1]:-}}"
}

apply_row() {
    local name="$1" kind="$2" file="$3" payload="$4"
    local argv=()

    case "$kind" in
        node)
            activate_node
            # Shared with the installer, so a refresh lands the same Node the
            # first setup would have — and carries the global npm packages over,
            # which nothing downstream of here would have done.
            argv=(install_node_lts)
            ;;
        npm)
            activate_node
            # One command for both an outdated row and a missing one: npm treats
            # install-over and install-fresh alike, which is what lets a `missing`
            # row be actionable without a second apply path.
            argv=(npm install -g "${payload}@latest")
            ;;
        app)
            argv=("$APPS_TOOL" update --name "$payload")
            ;;
        *)
            # A declared command, run through bash -c so one that cd's or exits
            # can't derail the rest of the run. DOTFILES_DIR is passed in because
            # some install commands reference it (helium's install-github call).
            argv=(env "DOTFILES_DIR=$DOTFILES_DIR" bash -c \
                  "$(entry_update_command "$file" "$payload" "$name")")
            ;;
    esac

    print_info "Updating $name..."
    if ! "${argv[@]}"; then
        print_error "Failed to update $name"
        return 1
    fi
    print_success "$name updated"
    return 0
}

# ── Commands ─────────────────────────────────────────────────────────────────

# Rows the user can actually act on, in the order they were reported. Matched by
# status rather than re-assembled field by field, so the row format can gain a
# column without this needing to know.
actionable_rows() {
    grep -E "^(outdated|missing|refresh)${US}" <<< "$1" || true
}

rate_limit_footer() {
    local marker
    marker=$(grep -m1 "^#ratelimit${US}" <<< "$1" || true)
    [ -n "$marker" ] || return 0

    local when
    when=$(date -d "@${marker#*"$US"}" +%H:%M 2>/dev/null) || when=""
    print_warning "GitHub API rate limit reached${when:+ (resets at $when)} — versions marked 'unknown' could not be checked"
    if ! gh auth token >/dev/null 2>&1; then
        print_info "Logging in with 'gh auth login' raises the limit from 60 to 5000 requests/hour"
    fi
}

managed_footer() {
    local n
    n=$(grep -c "^managed${US}" <<< "$1" || true)
    [ "${n:-0}" -gt 0 ] || return 0
    print_info "${n} tool(s) are pacman/AUR packages here — cachy-update keeps those current."
}

# What holds for the whole report regardless of what the user then does with it.
footers() {
    rate_limit_footer "$1"
    managed_footer "$1"
}

# "Nothing to update" is only true if every check actually completed — rows that
# failed to resolve are called out instead of being folded into a clean bill.
report_summary() {
    local report="$1"
    local n_action n_unknown
    n_action=$(actionable_rows "$report" | grep -c . || true)
    n_unknown=$(grep -c "^unavailable${US}" <<< "$report" || true)

    if [ "${n_action:-0}" -gt 0 ]; then
        print_info "${n_action} item(s) can be updated or installed — run 'dots update' to pick"
    elif [ "${n_unknown:-0}" -gt 0 ]; then
        print_warning "Nothing to update among the items that could be checked; ${n_unknown} could not be checked"
    else
        print_success "Everything we manage is up to date"
    fi

    footers "$report"
}

# Both commands open the same way. The report is left in REPORT rather than
# returned, so the caller can act on the rows it just showed.
REPORT=""
scan_report() {
    spin_capture REPORT "Checking for updates..." build_report

    print_header "Updates"
    render_report "$REPORT"
    echo ""
}

do_check() {
    scan_report
    report_summary "$REPORT"
}

# Interactive: report, then let the user pick what to apply.
do_update() {
    local apply_all=false
    [ "${1:-}" = "--all" ] && apply_all=true

    scan_report

    local rows=()
    mapfile -t rows < <(actionable_rows "$REPORT")

    if [ ${#rows[@]} -eq 0 ]; then
        report_summary "$REPORT"
        return 0
    fi

    # Selection labels, kept parallel to rows so a choice maps back by index.
    local labels=() row
    local "${REPORT_FIELDS[@]}"
    for row in "${rows[@]}"; do
        IFS="$US" read -r "${REPORT_FIELDS[@]}" <<< "$row"
        case "$status" in
            outdated) labels+=("$name  ${cur} → ${latest}") ;;
            # No version on either side to render, and "refresh" would misname
            # what applying it does. The verb comes from STATUS_LABEL so the
            # picker can't drift from the word the report already used.
            missing)  labels+=("$name  ${STATUS_LABEL[$status]}") ;;
            *)        labels+=("$name  refresh (${cur})") ;;
        esac
    done

    local selected
    if [ "$apply_all" = true ]; then
        selected=$(printf '%s\n' "${labels[@]}")
    else
        selected=$(printf '%s\n' "${labels[@]}" \
            | gum choose --no-limit --cursor.foreground="212" \
                --header "Select updates to apply (space to select, enter to confirm):") || {
            echo "Cancelled."
            return 0
        }
    fi

    if [ -z "$selected" ]; then
        print_info "Nothing selected"
        return 0
    fi

    # gum returns the chosen labels, so each is matched back to its row by text.
    # Matched indices are consumed, so two rows that happen to render the same
    # label (a name declared in both common.yaml and a group) apply once each
    # instead of applying the first one twice.
    local -A used=()
    local failed=0 applied=0 label i
    while IFS= read -r label; do
        [ -n "$label" ] || continue
        for i in "${!labels[@]}"; do
            [ "${labels[$i]}" = "$label" ] || continue
            [ -n "${used[$i]:-}" ] && continue
            used["$i"]=1
            IFS="$US" read -r "${REPORT_FIELDS[@]}" <<< "${rows[$i]}"
            echo ""
            if apply_row "$name" "$kind" "$file" "$payload"; then
                applied=$((applied + 1))
            else
                failed=$((failed + 1))
            fi
            break
        done
    done <<< "$selected"

    echo ""
    if [ "$failed" -gt 0 ]; then
        print_warning "${applied} updated, ${failed} failed"
        return 1
    fi
    print_success "${applied} item(s) updated"
    footers "$REPORT"
}

# The installer's post-install pass, over the entries it skipped as already
# installed. Setup only ever fills gaps — a tool whose `check` passes keeps
# whatever build it was first installed with, so a machine set up months ago
# still ran that month's binary after a fresh `dots setup`. Everything needed to
# do better was already declared in the yaml (`binary:` + `source:`/`npm:`) and
# already understood here; it was simply never consulted outside `dots update`.
#
# Confirmed rather than automatic, and as one prompt rather than one per tool:
# a setup re-run started for an unrelated reason should not silently spend
# several minutes on a `cargo install --git` nobody asked for.
do_refresh() {
    set_only_filter "$@"
    $ONLY_FILTER || return 0

    scan_report

    local rows=()
    mapfile -t rows < <(actionable_rows "$REPORT")

    if [ ${#rows[@]} -eq 0 ]; then
        report_summary "$REPORT"
        return 0
    fi

    if ! gum confirm "Update ${#rows[@]} already-installed tool(s) now?"; then
        print_info "Keeping the installed versions — 'dots update' applies them later"
        footers "$REPORT"
        return 0
    fi

    local row failed=0 applied=0
    for row in "${rows[@]}"; do
        IFS="$US" read -r "${REPORT_FIELDS[@]}" <<< "$row"
        echo ""
        if apply_row "$name" "$kind" "$file" "$payload"; then
            applied=$((applied + 1))
        else
            failed=$((failed + 1))
        fi
    done

    echo ""
    if [ "$failed" -gt 0 ]; then
        print_warning "${applied} updated, ${failed} failed"
        return 1
    fi
    print_success "${applied} tool(s) updated"
    footers "$REPORT"
}

usage() {
    cat <<'EOF'
Usage: dots update tools [command]

Updates what the system package manager does not own: curl-installed binaries,
global npm packages, the fnm-managed Node, cargo/git installs, and tracked
external apps. Pacman and AUR packages are left to cachy-update, and anything
found to be owned by a distro package is reported as such instead of refreshed.

Commands:
  (none)         Check, then pick which updates to apply
  check          Report only, change nothing
  all            Apply every available update without prompting
  refresh NAME…  Check only the named packages/*.yaml entries, then offer to
                 update them in one prompt. What the installer runs over the
                 tools it found already installed; Node and external apps are
                 out of scope here.
  help           Show this help message
EOF
}

case "${1:-}" in
    ""|update)      do_update ;;
    check|--check)  do_check ;;
    all|--all)      do_update --all ;;
    refresh)        shift; do_refresh "$@" ;;
    help|--help|-h) usage ;;
    *)              usage; exit 1 ;;
esac
