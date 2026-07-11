#!/bin/bash
# Common utility functions

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
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
    [[ " ${SELECTED_GROUP_NAMES[*]} " =~ " $1 " ]]
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
        yq -r ".packages.$distro[]? // \"\"" "$file" 2>/dev/null | grep -v "^#" | grep -v "^$" || true
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

# Parse custom_install entries and output their names (filtered by distro).
# Usage: parse_custom_install_names "file.yaml" "arch"
parse_custom_install_names() {
    local file="$1"
    local distro="$2"

    if command_exists yq; then
        yq -r "(.custom_install // [])[] | select((.distro_skip // []) | contains([\"$distro\"]) | not) | .name" "$file" 2>/dev/null | grep -v "^$" || true
    else
        # Fallback: simple parsing
        local in_section=false
        local current_name=""
        local skip=false
        while IFS= read -r line; do
            if [[ "$line" =~ ^custom_install:[[:space:]]*$ ]]; then
                in_section=true
                continue
            fi
            if $in_section; then
                # Exit when hitting another top-level key
                if [[ "$line" =~ ^[a-z] ]]; then
                    break
                fi
                # New entry
                if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*(.+)$ ]]; then
                    # Emit previous entry if valid
                    if [ -n "$current_name" ] && ! $skip; then
                        echo "$current_name"
                    fi
                    current_name="${BASH_REMATCH[1]}"
                    skip=false
                fi
                # Check distro_skip list
                if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*${distro}[[:space:]]*$ ]] && [ -n "$current_name" ]; then
                    skip=true
                fi
            fi
        done < "$file"
        # Emit last entry
        if [ -n "$current_name" ] && ! $skip; then
            echo "$current_name"
        fi
    fi
}

# Get a field from a custom_install entry by name.
# Usage: _parse_custom_install_field "file.yaml" "claude-code" "install"
_parse_custom_install_field() {
    local file="$1"
    local pkg_name="$2"
    local field="$3"

    if command_exists yq; then
        yq -r "(.custom_install // [])[] | select(.name == \"$pkg_name\") | .$field // \"\"" "$file" 2>/dev/null
    else
        local in_section=false
        local found=false
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
                    continue
                fi
                if $found && [[ "$line" =~ ^[[:space:]]*${field}:[[:space:]]*(.+)$ ]]; then
                    echo "${BASH_REMATCH[1]}"
                    return 0
                fi
                if $found && [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name: ]]; then
                    break
                fi
            fi
        done < "$file"
    fi
}

parse_custom_install_cmd() { _parse_custom_install_field "$1" "$2" "install"; }
parse_custom_install_check() { _parse_custom_install_field "$1" "$2" "check"; }
parse_custom_install_requires() { _parse_custom_install_field "$1" "$2" "requires"; }

# Fallback parser for requires_packages (used when yq is unavailable).
# Emits one package per line for the given distro family. Supports inline
# list form only (e.g. `fedora: [rust, cargo]`) — which is what the yaml uses.
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

# Available Groq whisper models (single source of truth)
GROQ_WHISPER_MODELS=(
    "whisper-large-v3-turbo - Faster with slight accuracy tradeoff"
    "whisper-large-v3 - Best accuracy; generous free tier"
)

# Ensure a Groq API key is configured. Checks env, then secrets.conf, then prompts.
# Returns 1 only if the user cancels or provides no key.
setup_groq_api_key() {
    local existing_key="${GROQ_API_KEY:-}"
    if [ -z "$existing_key" ] && [ -f "$SECRETS_CONF" ]; then
        existing_key=$(grep '^GROQ_API_KEY=' "$SECRETS_CONF" 2>/dev/null | cut -d= -f2- || true)
    fi

    if [ -n "$existing_key" ]; then
        local masked="${existing_key:0:8}...${existing_key: -4}"
        print_success "Groq API key found: $masked"
        if [ "${1:-}" = "--allow-change" ] && ! gum confirm "Keep current API key?"; then
            existing_key=""
        fi
    fi

    if [ -z "$existing_key" ]; then
        print_info "Get a free Groq API key at: https://console.groq.com/keys"
        local api_key
        api_key=$(gum input --placeholder "Paste your Groq API key (gsk_...)" --password \
            --header "Groq API Key:") || api_key=""

        if [ -z "$api_key" ]; then
            return 1
        fi

        set_secret "GROQ_API_KEY" "$api_key"
        print_success "Groq API key saved to $SECRETS_CONF"

        export GROQ_API_KEY="$api_key"
        systemctl --user import-environment GROQ_API_KEY 2>/dev/null || true
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
