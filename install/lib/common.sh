#!/bin/bash
# Common utility functions

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Every status tag pads to the width of the longest — [SUCCESS] and [WARNING], at
# 9 — so the message text starts in the same column whatever the level. A log is
# read down the message column, and unpadded tags step that column in and out by
# up to three characters on every line.
TAG_WIDTH=9

# The width applies to the bare tag: the colour is a separate `%b` conversion, so
# its escape bytes never count towards the field. (They would if colour and tag
# were one argument to one field — then the width is spent on the escapes and no
# padding is emitted at all.)
#
# `%s` for the message, not `echo -e`'s implicit unescaping — which switching to
# printf for the field width is what makes possible in the first place. Nothing
# should reinterpret a backslash that arrived in a path or a command's output.
_print_tag() {
    local color="$1" tag="$2" msg="$3"
    printf '%b%-*s%b %s\n' "$color" "$TAG_WIDTH" "$tag" "$NC" "$msg"
}

# Print colored messages
print_info() {
    _print_tag "$BLUE" "[INFO]" "$1"
}

print_success() {
    _print_tag "$GREEN" "[SUCCESS]" "$1"
}

print_warning() {
    _print_tag "$YELLOW" "[WARNING]" "$1"
}

# Print warning and track it for the end-of-install summary
track_warning() {
    print_warning "$1"
    INSTALL_WARNINGS+=("$1")
}

print_error() {
    _print_tag "$RED" "[ERROR]" "$1"
}

# Install a SIGINT/SIGTERM trap so Ctrl+C cleanly exits interactive scripts
# even when gum (or any child) absorbs the signal first. Idempotent via an
# exported marker: child processes inherit it and skip installing a second
# trap, so Ctrl+C only prints one "Interrupted." line across the tree.
install_interrupt_trap() {
    [ -n "${_INTERRUPT_TRAP_OWNER:-}" ] && return 0
    export _INTERRUPT_TRAP_OWNER=$$
    trap 'echo; print_warning "Interrupted."; exit 130' INT TERM
}

# Test whether a group is in SELECTED_GROUP_NAMES.
group_selected() {
    [[ " ${SELECTED_GROUP_NAMES[*]} " == *" $1 "* ]]
}

print_header() {
    echo ""
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${PURPLE}  $1${NC}"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Verify required commands exist; report every missing one at once.
# Usage: require_tools age tar git || return 1
require_tools() {
    local missing=() tool
    for tool in "$@"; do
        command_exists "$tool" || missing+=("$tool")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Missing required tools: ${missing[*]}"
        print_info "Install with: sudo pacman -S ${missing[*]}"
        return 1
    fi
}

# Source the distro-family helpers for this machine, or fail with a message.
# Requires $DOTFILES_DIR set and lib/detect.sh already sourced; leaves DISTRO
# and DISTRO_FAMILY set for callers that branch on them. Every tool entry point
# needs exactly this, so the detect-then-source dance lives here, not in each one.
load_distro_lib() {
    DISTRO=$(detect_distro)
    DISTRO_FAMILY=$(get_distro_family "$DISTRO")

    local lib="$DOTFILES_DIR/install/distros/$DISTRO_FAMILY.sh"
    if [ ! -f "$lib" ]; then
        print_error "Unsupported distribution family: $DISTRO_FAMILY"
        return 1
    fi
    source "$lib"
}

# Escape a string for embedding in a JSON string literal.
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

# ── Spinners ─────────────────────────────────────────────────────────────────
# A single, consistent loader for silent multi-second work (catalogue builds,
# downloads, extraction). Do NOT wrap commands that print their own progress
# (pacman/apt/dnf, curl install scripts, chezmoi apply) — that hides output the
# user needs to see. gum draws the spinner on stderr, so it still animates when
# stdout is captured (e.g. inside `$(...)`); we gate on stderr being a TTY and
# otherwise run the command plainly. set -e safe: the command's exit status is
# captured, never left as a bare failing command.

# Core: run "$@" with stdout redirected to OUTFILE while a spinner titled TITLE
# shows, then return the command's exit status. Works for shell functions and
# external commands alike (the command runs in a background job we poll).
_spin_core() {
    local title="$1" outfile="$2"
    shift 2
    local rc=0
    if command_exists gum && [ -t 2 ]; then
        ( "$@" >"$outfile" 2>/dev/null ) &
        local pid=$!
        gum spin --spinner dot --title "$title" -- \
            bash -c "while kill -0 ${pid} 2>/dev/null; do sleep 0.1; done" || true
        wait "$pid" || rc=$?
    else
        "$@" >"$outfile" 2>/dev/null || rc=$?
    fi
    return "$rc"
}

# Capture CMD's stdout into the variable named VAR while showing a spinner.
# Usage: spin_capture result "Loading packages..." build_json arg1 arg2
spin_capture() {
    local __var="$1" __title="$2"
    shift 2
    local __tmp __rc=0
    __tmp=$(mktemp)
    _spin_core "$__title" "$__tmp" "$@" || __rc=$?
    printf -v "$__var" '%s' "$(cat "$__tmp")"
    rm -f "$__tmp"
    return "$__rc"
}

# Run CMD (output discarded) while showing a spinner; returns CMD's exit status.
# Usage: spin_run "Cloning theme..." git clone --depth 1 "$repo" "$dest"
spin_run() {
    local __title="$1"
    shift
    _spin_core "$__title" /dev/null "$@"
}

# Wait for a keypress before returning to a menu, so the output the user just
# produced isn't immediately scrolled away by the menu redraw.
pause_for_user() {
    echo ""
    read -rsn1 -p "Press any key to continue..."
    echo ""
}

# Get the script directory
get_script_dir() {
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

# Get the dotfiles root directory
get_dotfiles_dir() {
    local script_dir
    script_dir="$(get_script_dir)"
    # Go up two levels from install/lib to get to dotfiles root
    cd "$script_dir/../.." && pwd
}

# Parse YAML file and extract package list for a distro
# Usage: parse_packages "file.yaml" "arch"
parse_packages() {
    local file="$1"
    local distro="$2"
    
    if command_exists yq; then
        # grep exits non-zero when a group has no matching lines; tolerate it so
        # callers running under `set -o pipefail` don't abort on an empty group.
        yq -r ".packages.${distro}[]? // \"\"" "$file" 2>/dev/null | grep -v "^#" | grep -v "^$" || true
    else
        # Fallback: simple grep-based parsing
        local in_section=false
        local indent=""
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*${distro}:[[:space:]]*$ ]]; then
                in_section=true
                indent=$(echo "$line" | grep -o "^[[:space:]]*")
                continue
            fi
            if $in_section; then
                # Check if we've exited the section
                if [[ "$line" =~ ^[[:space:]]*[a-z_]+:[[:space:]]*$ ]] && [[ ! "$line" =~ ^${indent}[[:space:]] ]]; then
                    break
                fi
                # Extract package name
                if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*(.+)$ ]]; then
                    echo "${BASH_REMATCH[1]}" | sed 's/#.*//' | xargs
                fi
            fi
        done < "$file"
    fi
}

# Parse YAML descriptions map and output "package=description" lines
# Usage: parse_descriptions "file.yaml"
parse_descriptions() {
    local file="$1"

    if command_exists yq; then
        yq -r '.descriptions // {} | to_entries[] | .key + "=" + .value' "$file" 2>/dev/null
    else
        # Fallback: simple grep-based parsing
        local in_section=false
        while IFS= read -r line; do
            if [[ "$line" =~ ^descriptions:[[:space:]]*$ ]]; then
                in_section=true
                continue
            fi
            if $in_section; then
                # Exit when hitting another top-level key
                if [[ "$line" =~ ^[a-z] ]]; then
                    break
                fi
                # Match "  package_name: some description"
                if [[ "$line" =~ ^[[:space:]]+([^:]+):[[:space:]]+(.+)$ ]]; then
                    local pkg="${BASH_REMATCH[1]}"
                    local desc="${BASH_REMATCH[2]}"
                    # Strip surrounding quotes if present
                    desc="${desc#\"}"
                    desc="${desc%\"}"
                    desc="${desc#\'}"
                    desc="${desc%\'}"
                    echo "${pkg}=${desc}"
                fi
            fi
        done < "$file"
    fi
}

# Parse YAML file and extract dotfiles list
parse_dotfiles() {
    local file="$1"
    
    if command_exists yq; then
        yq -r '.dotfiles[]? // ""' "$file" 2>/dev/null
    else
        # Fallback: simple parsing
        local in_section=false
        while IFS= read -r line; do
            if [[ "$line" =~ ^dotfiles:[[:space:]]*$ ]]; then
                in_section=true
                continue
            fi
            if $in_section; then
                if [[ "$line" =~ ^[a-z] ]]; then
                    break
                fi
                if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*(.+)$ ]]; then
                    echo "${BASH_REMATCH[1]}" | xargs
                fi
            fi
        done < "$file"
    fi
}

# Parse services from YAML
parse_services() {
    local file="$1"
    
    if command_exists yq; then
        yq -r '.services[]? // ""' "$file" 2>/dev/null
    else
        local in_section=false
        while IFS= read -r line; do
            if [[ "$line" =~ ^services:[[:space:]]*$ ]]; then
                in_section=true
                continue
            fi
            if $in_section; then
                if [[ "$line" =~ ^[a-z] ]]; then
                    break
                fi
                if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*(.+)$ ]]; then
                    echo "${BASH_REMATCH[1]}" | xargs
                fi
            fi
        done < "$file"
    fi
}

# Parse desktop_only list from YAML
# Usage: parse_desktop_only "file.yaml"
parse_desktop_only() {
    local file="$1"

    if command_exists yq; then
        yq -r '.desktop_only[]? // ""' "$file" 2>/dev/null | grep -v "^$" || true
    else
        local in_section=false
        while IFS= read -r line; do
            if [[ "$line" =~ ^desktop_only:[[:space:]]*$ ]]; then
                in_section=true
                continue
            fi
            if $in_section; then
                if [[ "$line" =~ ^[a-z] ]]; then
                    break
                fi
                if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*(.+)$ ]]; then
                    echo "${BASH_REMATCH[1]}" | sed 's/#.*//' | xargs
                fi
            fi
        done < "$file"
    fi
}

# Read a group's declared hardware requirement (the `requires_hardware:` field),
# or empty when none is declared. This is a single top-level scalar, so we grep
# it directly rather than spawning yq — it runs once per group during the
# pre-selection scan, where yq's startup cost is otherwise visible.
# Usage: parse_requires_hardware "file.yaml"
parse_requires_hardware() {
    local file="$1"
    local val
    val=$(grep -m1 '^requires_hardware:' "$file" 2>/dev/null \
        | sed 's/^requires_hardware:[[:space:]]*//; s/[[:space:]]*#.*$//; s/[[:space:]]*$//')
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    printf '%s' "$val"
}

# Whether the hardware a group requires is present. Groups without a
# `requires_hardware:` field (or with an unrecognised value) are always
# available. This is the single gate the installer and the package manager
# both consult, so hardware-specific groups (e.g. biometric → fingerprint
# reader) appear in exactly the same machines everywhere.
# Usage: group_hardware_available "file.yaml"  (returns 0 = available)
group_hardware_available() {
    local file="$1"
    local req
    req=$(parse_requires_hardware "$file")
    case "$req" in
        "" | none)   return 0 ;;
        fingerprint) has_fingerprint_reader ;;
        *)           return 0 ;;
    esac
}

# ── Entry sections ───────────────────────────────────────────────────────────
# `custom_install:` (group files) and `tools:` (common.yaml) are the same shape
# — a list of maps keyed by `name` under a top-level key — so one parser family
# serves both, taking the section as an argument. Each entry's fields are
# documented where the yaml declares them (packages/common.yaml).

# Names of every entry in a section, one per line.
# Usage: parse_entry_names "file.yaml" "custom_install"
parse_entry_names() {
    local file="$1" section="$2"

    if command_exists yq; then
        yq -r "(.${section} // [])[].name" "$file" 2>/dev/null | grep -v "^$" || true
    else
        # Fallback: simple parsing
        local in_section=false line
        while IFS= read -r line; do
            if [[ "$line" =~ ^${section}:[[:space:]]*$ ]]; then
                in_section=true
                continue
            fi
            if $in_section; then
                # Exit when hitting another top-level key
                [[ "$line" =~ ^[a-z] ]] && break
                if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*(.+)$ ]]; then
                    echo "${BASH_REMATCH[1]}"
                fi
            fi
        done < "$file"
    fi
}

# One field of one entry, empty when unset.
# Usage: parse_entry_field "file.yaml" "custom_install" "claude-code" "install"
parse_entry_field() {
    local file="$1" section="$2" name="$3" field="$4"

    if command_exists yq; then
        yq -r "(.${section} // [])[] | select(.name == \"$name\") | .${field} // \"\"" "$file" 2>/dev/null
    else
        local in_section=false found=false line
        while IFS= read -r line; do
            if [[ "$line" =~ ^${section}:[[:space:]]*$ ]]; then
                in_section=true
                continue
            fi
            if $in_section; then
                [[ "$line" =~ ^[a-z] ]] && break
                if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*${name}[[:space:]]*$ ]]; then
                    found=true
                    continue
                fi
                if $found && [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name: ]]; then
                    break
                fi
                if $found && [[ "$line" =~ ^[[:space:]]*${field}:[[:space:]]*(.+)$ ]]; then
                    _unquote_yaml_scalar "${BASH_REMATCH[1]}"
                    return 0
                fi
            fi
        done < "$file"
    fi
}

# Strip the quotes off a YAML scalar, so the fallback parser returns what yq
# would. Without this a quoted value comes back with its quotes attached and
# eval'ing it looks for a command literally named `'[ -x "$HOME/..." ]'`.
_unquote_yaml_scalar() {
    local value="$1"
    if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
        value="${BASH_REMATCH[1]}"
    fi
    printf '%s\n' "$value"
}

# Several fields of one entry in a single yq call — reading them one at a time
# costs a yq process per field, which dominates a whole-repo scan.
#
# Values are joined with $YAML_FIELD_SEP (Unit Separator) rather than newlines
# because the command-bearing fields hold multi-line shell snippets. A trailing
# empty field absorbs yq's final newline, so no real value picks it up; split it
# off with `mapfile -d "$YAML_FIELD_SEP" -t` and ignore the last element.
# Usage: mapfile -d "$YAML_FIELD_SEP" -t f \
#            < <(parse_entry_fields common.yaml tools eza binary source)
YAML_FIELD_SEP=$'\x1f'
parse_entry_fields() {
    local file="$1" section="$2" name="$3"
    shift 3
    local field

    if command_exists yq; then
        local list=""
        for field in "$@"; do
            list+="(.${field} // \"\" | tostring),"
        done
        yq -r "(.${section} // [])[] | select(.name == \"$name\") | [${list}\"\"] | join(\"$YAML_FIELD_SEP\")" \
            "$file" 2>/dev/null
    else
        for field in "$@"; do
            printf '%s%s' "$(parse_entry_field "$file" "$section" "$name" "$field")" "$YAML_FIELD_SEP"
        done
        echo ""
    fi
}

# Every value of one field across a section, one per line, skipping entries that
# don't declare it. A query rather than a name loop: reading the field per entry
# costs a yq process each, and callers want the whole column.
# Usage: parse_entry_field_values "common.yaml" "tools" "npm"
parse_entry_field_values() {
    local file="$1" section="$2" field="$3"

    if command_exists yq; then
        yq -r "(.${section} // [])[] | select(.${field}) | .${field}" "$file" 2>/dev/null \
            | grep -v "^$" || true
    else
        local name value
        while IFS= read -r name; do
            value=$(parse_entry_field "$file" "$section" "$name" "$field")
            if [ -n "$value" ]; then printf '%s\n' "$value"; fi
        done < <(parse_entry_names "$file" "$section")
    fi
}

parse_custom_install_names() { parse_entry_names "$1" "custom_install"; }
parse_custom_install_cmd() { parse_entry_field "$1" "custom_install" "$2" "install"; }
parse_custom_install_check() { parse_entry_field "$1" "custom_install" "$2" "check"; }
parse_custom_install_requires() { parse_entry_field "$1" "custom_install" "$2" "requires"; }

# Run an entry's `check` command. Only the exit code matters: stdin is detached
# and all output silenced so a misbehaving check (one that launches an app or
# reads stdin) can't hang a scan or bleed text into a captured stdout stream.
# An entry with no check counts as not installed.
run_entry_check() {
    local check_cmd="$1"
    [ -n "$check_cmd" ] && eval "$check_cmd" </dev/null >/dev/null 2>&1
}

is_custom_install_installed() {
    run_entry_check "$(parse_custom_install_check "$1" "$2")"
}

# ── Node toolchain ───────────────────────────────────────────────────────────

# Where fnm's installer (--skip-shell) drops the binary. Not on a script's PATH,
# and the shell hook that would add it only runs for interactive shells.
FNM_BIN_DIR="$HOME/.local/share/fnm"

# Put the fnm-managed Node on PATH for the current shell. Installs nothing: a
# missing fnm just leaves node/npm absent, which callers report as unavailable.
# Idempotent — safe to call from several places in one run.
activate_fnm_node() {
    case ":$PATH:" in
        *":$FNM_BIN_DIR:"*) ;;
        *) [ -d "$FNM_BIN_DIR" ] && export PATH="$FNM_BIN_DIR:$PATH" ;;
    esac

    if command_exists fnm; then
        eval "$(fnm env --use-on-cd --shell bash 2>/dev/null)" || true
        hash -r 2>/dev/null || true
    fi
    return 0
}

# Where a global npm package lands: inside the Node version's own tree, reached
# through fnm's `default` alias. That is why moving Node strands every one of
# them — the new version starts with an empty node_modules. The path is stable
# while what it points at moves, which is what lets one constant name both the
# version being left and the one being landed on.
FNM_GLOBALS_DIR="$FNM_BIN_DIR/aliases/default/lib/node_modules"

# The global packages installed against the Node currently in use, one name per
# line, ready to hand back to `npm install -g`. npm and corepack ship with Node
# itself, so they are never ours to reinstall.
#
# A scope directory is not a package — its children are, so the two depths are
# globbed separately rather than walked and then descended into. Trimming the
# root off the whole path, instead of taking the basename, is what makes a scoped
# entry come back out as `@scope/name`.
list_global_npm_packages() {
    local path name
    [ -d "$FNM_GLOBALS_DIR" ] || return 0

    for path in "$FNM_GLOBALS_DIR"/[^@]* "$FNM_GLOBALS_DIR"/@*/*; do
        [ -d "$path" ] || continue
        name="${path#"$FNM_GLOBALS_DIR"/}"
        case "$name" in npm|corepack) continue ;; esac
        printf '%s\n' "$name"
    done
    return 0
}

# Reinstall the named globals that the Node now in use is missing. Never fatal:
# Node itself did move, so a package npm can't fetch is reported and left for
# the user rather than rolling the version change back.
reinstall_global_npm_packages() {
    local pkg missing=() stranded=()
    for pkg in "$@"; do
        [ -d "$FNM_GLOBALS_DIR/$pkg" ] || missing+=("$pkg")
    done
    # Nothing to carry covers the no-argument call too, so this is the only guard
    # needed — and it comes before the npm probe so the common case forks nothing.
    [ "${#missing[@]}" -gt 0 ] || return 0
    command_exists npm || return 0

    print_info "Carrying ${#missing[@]} global npm package(s) over: ${missing[*]}"
    for pkg in "${missing[@]}"; do
        npm install -g "$pkg" || stranded+=("$pkg")
    done

    if [ "${#stranded[@]}" -gt 0 ]; then
        print_warning "Left behind by the Node move: ${stranded[*]}"
        print_info "Reinstall by hand with 'npm install -g ${stranded[*]}'"
        return 0
    fi
    print_success "Global npm packages carried over"
    return 0
}

# Install the latest Node LTS, make it fnm's default and put it on PATH. Shared
# with 'dots update', which refreshes Node exactly the way the installer
# first provisions it, so the two can't drift.
#
# The carry-over lives here rather than in the updater's apply path because it
# belongs welded to the `fnm default` that causes the stranding: any future
# caller that moves Node gets the repair whether it thought about it or not.
# `dots update` is the only caller that can trigger it today — the installer
# reaches this function solely when fnm has no versions at all, where there is
# nothing to carry and the read costs one stat.
install_node_lts() {
    local carried=()
    mapfile -t carried < <(list_global_npm_packages)

    fnm install --lts && fnm default lts-latest && activate_fnm_node || return 1

    reinstall_global_npm_packages "${carried[@]}"
}

# ── Groups ───────────────────────────────────────────────────────────────────

# Group ID from its filename (packages/groups/development.yaml -> development)
get_group_id() {
    basename "$1" .yaml
}

# The chezmoi flag recording whether a group was selected (development ->
# install_development). The naming convention lives here and nowhere else.
get_chezmoi_flag() {
    echo "install_$1"
}

# True when the group defined by a yaml file is enabled in chezmoi's data.
group_enabled() {
    [ "$(chezmoi_data_get "$(get_chezmoi_flag "$(get_group_id "$1")")")" = "true" ]
}

# Fallback parser for requires_packages (used when yq is unavailable).
# Emits one package per line for the given distro family. Supports inline
# list form only (e.g. `arch: [rust, cargo]`) — which is what the yaml uses.
_parse_custom_install_requires_packages_fallback() {
    local file="$1" pkg_name="$2" family="$3"
    local in_section=false
    local found=false
    local in_req_pkgs=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^custom_install:[[:space:]]*$ ]]; then
            in_section=true
            continue
        fi
        if $in_section; then
            if [[ "$line" =~ ^[a-z] ]]; then
                break
            fi
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*${pkg_name}[[:space:]]*$ ]]; then
                found=true
                in_req_pkgs=false
                continue
            fi
            if $found && [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name: ]]; then
                break
            fi
            if $found && [[ "$line" =~ ^[[:space:]]*requires_packages:[[:space:]]*$ ]]; then
                in_req_pkgs=true
                continue
            fi
            if $found && $in_req_pkgs; then
                # Leaving the map when a line is not further indented under it.
                if [[ "$line" =~ ^[[:space:]]{0,4}[a-zA-Z_]+: ]] && ! [[ "$line" =~ ^[[:space:]]{6,} ]]; then
                    in_req_pkgs=false
                    continue
                fi
                if [[ "$line" =~ ^[[:space:]]*${family}:[[:space:]]*\[(.+)\][[:space:]]*$ ]]; then
                    local list="${BASH_REMATCH[1]}"
                    # Split on comma, trim whitespace and quotes.
                    local IFS=','
                    for item in $list; do
                        item="${item#"${item%%[![:space:]]*}"}"
                        item="${item%"${item##*[![:space:]]}"}"
                        item="${item%\"}"; item="${item#\"}"
                        item="${item%\'}"; item="${item#\'}"
                        [ -n "$item" ] && echo "$item"
                    done
                    return 0
                fi
            fi
        fi
    done < "$file"
}

# Get the packages to auto-install when a custom_install entry's `requires`
# command is missing. Resolves DISTRO_FAMILY (arch) and emits one package per
# line; empty output if nothing is declared for this family.
parse_custom_install_requires_packages() {
    local file="$1" pkg_name="$2"
    local family="${DISTRO_FAMILY:-}"
    [ -z "$family" ] && return 0

    if command_exists yq; then
        yq -r "(.custom_install // [])[] | select(.name == \"$pkg_name\") | .requires_packages.$family // [] | .[]" "$file" 2>/dev/null
    else
        _parse_custom_install_requires_packages_fallback "$file" "$pkg_name" "$family"
    fi
}

# ── Chezmoi data helpers ─────────────────────────────────────────────────────

CHEZMOI_CONF="$HOME/.config/chezmoi/chezmoi.toml"

# Read a key's value from chezmoi.toml's [data] section (quotes stripped).
chezmoi_data_get() {
    local key="$1"
    [ -f "$CHEZMOI_CONF" ] || return 0
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$CHEZMOI_CONF" 2>/dev/null | head -1 \
        | sed 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//; s/^"\(.*\)"$/\1/'
}

# Upsert a key in chezmoi.toml's [data] section. true/false are written bare,
# everything else quoted.
chezmoi_data_set() {
    local key="$1" value="$2"
    if [ ! -f "$CHEZMOI_CONF" ]; then
        print_warning "chezmoi.toml not found, skipping $key update"
        return 0
    fi
    local rendered="\"$value\""
    case "$value" in true|false) rendered="$value" ;; esac
    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$CHEZMOI_CONF"; then
        sed -i "s/^[[:space:]]*${key}[[:space:]]*=.*/    ${key} = ${rendered}/" "$CHEZMOI_CONF"
    else
        sed -i "/^\[data\]/a\\    ${key} = ${rendered}" "$CHEZMOI_CONF"
    fi
}

# Whether this machine's install_purpose matches (desktop | terminal).
install_purpose_is() {
    [ "$(chezmoi_data_get install_purpose)" = "$1" ]
}

# ── Machine profile state ────────────────────────────────────────────────────
#
# Written at the end of a *successful* setup or sync and nowhere else, which is
# the whole point: a run that died halfway must not leave the machine looking
# synced. chezmoi.toml cannot play this role — setup_dotfiles writes it in the
# middle of the install, so it exists long before the install has worked.
#
# SYNCED_COMMIT is the anchor `dots update` diffs against to know what the repo
# gained since this machine last agreed with it. Without it the only question
# available is "what is missing?", which cannot tell a new package from one the
# user removed on purpose — and so re-offers the removed one forever.
PROFILE_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/profile.env"

profile_get() {
    [ -f "$PROFILE_STATE" ] || return 0
    # profile_set is the only writer and always emits KEY='value', so one
    # pattern reads it — no second pass to peel the quotes back off.
    sed -n "s/^$1='\(.*\)'$/\1/p" "$PROFILE_STATE" 2>/dev/null | head -1
}

profile_set() {
    local key="$1" value="$2"
    mkdir -p "$(dirname "$PROFILE_STATE")"
    [ -f "$PROFILE_STATE" ] || : > "$PROFILE_STATE"
    if grep -q "^${key}=" "$PROFILE_STATE"; then
        sed -i "s|^${key}=.*|${key}='${value}'|" "$PROFILE_STATE"
    else
        printf "%s='%s'\n" "$key" "$value" >> "$PROFILE_STATE"
    fi
}

# Has this machine been through the installer? Setup refuses to re-run on one
# that has, and the package tree seeds its checkboxes from reality rather than
# offering the whole catalogue again.
machine_is_managed() {
    [ -f "$PROFILE_STATE" ] && return 0
    # Machines set up before the profile file existed: chezmoi.toml is written
    # by setup_dotfiles and by nothing else, so a [data] block means the
    # installer got at least that far. Their first `dots update` writes the
    # real marker.
    [ -f "$CHEZMOI_CONF" ] && grep -q '^\[data\]' "$CHEZMOI_CONF"
}

# Stamp the machine profile. One writer for the anchor the whole design rests
# on: both `dots setup` (at the very end of a run that worked) and `dots update`
# call this, so the next key added here cannot end up written by one and not the
# other. Requires $DOTFILES_DIR.
record_synced_state() {
    local head
    head=$(git -C "$DOTFILES_DIR" rev-parse HEAD 2>/dev/null) || head=""
    [ -n "$head" ] && profile_set SYNCED_COMMIT "$head"
    profile_set SYNCED_AT "$(date -Is)"
}

# ── Secrets & config helpers ─────────────────────────────────────────────────

SECRETS_CONF="$HOME/.config/environment.d/secrets.conf"

# Write a key=value pair to the secrets file (upsert)
set_secret() {
    local key="$1" value="$2"
    mkdir -p "$(dirname "$SECRETS_CONF")"
    if [ -f "$SECRETS_CONF" ] && grep -q "^${key}=" "$SECRETS_CONF"; then
        sed -i 's/^'"${key}"'=.*/'"${key}"'='"${value}"'/' "$SECRETS_CONF"
    else
        echo "${key}=${value}" >> "$SECRETS_CONF"
    fi
}

# ── Package list helpers ─────────────────────────────────────────────────────
#
# What a machine is *declared* to want. Every view that answers that question —
# the manage tree, `dots packages sync`, the `dots update` delta — goes through
# these two, so "declared" cannot come to mean three different things (it did:
# the update delta grew its own walk and read a packages/base.yaml that has
# never existed, silently emptying half its answer).

# Every package a group declares for this machine: distro packages plus
# custom_install entries, minus the desktop-only ones on a terminal install.
# One package per line.
get_group_packages() {
    local file="$1"
    local all_packages
    all_packages=$({ parse_packages "$file" "$DISTRO_FAMILY"; parse_custom_install_names "$file"; } \
        | grep -v "^$" || true)

    if [ -z "$all_packages" ]; then
        return
    fi

    # Filter desktop_only packages when in terminal mode
    if install_purpose_is terminal; then
        local desktop_only_list
        desktop_only_list=$(parse_desktop_only "$file")
        if [ -n "$desktop_only_list" ]; then
            grep -vxFf <(printf '%s\n' "$desktop_only_list") <<< "$all_packages" || true
            return
        fi
    fi

    echo "$all_packages"
}

# Base packages this machine should have: core (+ aur), plus the desktop
# sections unless this is a terminal-only install. Takes the packages/ directory
# to read, so the same walk serves the current checkout and a worktree exported
# at an older commit; defaults to this machine's.
base_desired_packages() {
    local base_file="${1:-${PACKAGES_DIR:-}}/$DISTRO_FAMILY/base.yaml"
    [ -f "$base_file" ] || return 0
    parse_packages "$base_file" "core"
    parse_packages "$base_file" "aur"
    if ! install_purpose_is terminal; then
        parse_packages "$base_file" "desktop"
        parse_packages "$base_file" "desktop_aur"
    fi
}

# ── Package install helpers ──────────────────────────────────────────────────

# Build an in-memory set of every installed package (one query, not one per
# package). Populates the global INSTALLED_SET associative array.
#
# Shared by `dots packages` (which pre-checks what you have) and by the
# installer's selection tree (which seeds its checkboxes the same way on a
# machine that is already set up), so "already installed" cannot come to mean
# two different things in the two views.
# shellcheck disable=SC2034  # read by the callers this is declared -g for
build_installed_index() {
    declare -gA INSTALLED_SET=()
    local pkg
    while IFS= read -r pkg; do
        [ -n "$pkg" ] && INSTALLED_SET["$pkg"]=1
    done < <(list_installed_packages)
}

# build_installed_index unless a caller already built it this run. The query is
# ~0.3s over a few thousand packages, and a single command can want the index
# from two phases that neither install nor remove anything between them.
# Anything that *does* change what is installed must call build_installed_index.
ensure_installed_index() {
    [ "${#INSTALLED_SET[@]}" -gt 0 ] || build_installed_index
}

# Install one `custom_install:` entry using the command its yaml declares.
# A declared `requires:` that is absent is a skip, not a failure: the entry
# needs a toolchain this machine has not got, and saying so beats a build error.
install_custom_pkg() {
    local file="$1" pkg="$2"
    local install_cmd requires_cmd
    install_cmd=$(parse_custom_install_cmd "$file" "$pkg")
    requires_cmd=$(parse_custom_install_requires "$file" "$pkg")
    if [ -n "$requires_cmd" ] && ! command_exists "$requires_cmd"; then
        print_warning "$requires_cmd not found — skipping $pkg"
        return 0
    fi
    if [ -n "$install_cmd" ]; then
        install_curl_tool "$pkg" "$install_cmd" || print_warning "Failed to install $pkg"
    fi
}

# Install a tool via curl script
install_curl_tool() {
    local name="$1"
    local install_cmd="$2"
    
    print_info "Installing $name..."
    if eval "$install_cmd"; then
        print_success "$name installed successfully"
        return 0
    else
        print_error "Failed to install $name"
        return 1
    fi
}

# Clone a git repository
install_git_repo() {
    local name="$1"
    local url="$2"
    local dest="$3"
    
    # Expand ~ to $HOME
    dest="${dest/#\~/$HOME}"
    
    if [ -d "$dest" ]; then
        print_info "$name already exists at $dest"
        return 0
    fi
    
    print_info "Cloning $name to $dest..."
    mkdir -p "$(dirname "$dest")"
    if git clone "$url" "$dest"; then
        print_success "$name cloned successfully"
        return 0
    else
        print_error "Failed to clone $name"
        return 1
    fi
}
