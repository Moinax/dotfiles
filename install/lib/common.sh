#!/bin/bash
# Common utility functions

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Print colored messages
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Print warning and track it for the end-of-install summary
track_warning() {
    print_warning "$1"
    INSTALL_WARNINGS+=("$1")
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
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

# Install the latest Node LTS, make it fnm's default and put it on PATH. Shared
# with './manage.sh update', which refreshes Node exactly the way the installer
# first provisions it, so the two can't drift.
install_node_lts() {
    fnm install --lts && fnm default lts-latest && activate_fnm_node
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

# ── Package install helpers ──────────────────────────────────────────────────

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
