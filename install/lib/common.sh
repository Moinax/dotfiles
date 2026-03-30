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
        yq -r ".packages.$distro[]? // \"\"" "$file" 2>/dev/null | grep -v "^#" | grep -v "^$"
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
        yq -r '.desktop_only[]? // ""' "$file" 2>/dev/null | grep -v "^$"
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

# Parse custom_install entries and output their names (filtered by distro).
# Usage: parse_custom_install_names "file.yaml" "debian"
parse_custom_install_names() {
    local file="$1"
    local distro="$2"

    if command_exists yq; then
        yq -r "(.custom_install // [])[] | select((.distro_skip // []) | contains([\"$distro\"]) | not) | .name" "$file" 2>/dev/null | grep -v "^$"
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

# Parse a nested list from the top-level packages: map in YAML.
# Usage: parse_package_nested_list "file.yaml" "fedora_copr"
parse_package_nested_list() {
    local file="$1"
    local key="$2"
    local in_packages=false
    local in_list=false
    local packages_indent=-1
    local list_indent=-1

    while IFS= read -r line; do
        local trimmed="${line#"${line%%[![:space:]]*}"}"
        local indent=$(( ${#line} - ${#trimmed} ))

        if ! $in_packages; then
            if [[ "$line" =~ ^[[:space:]]*packages:[[:space:]]*$ ]]; then
                in_packages=true
                packages_indent=$indent
            fi
            continue
        fi

        if [ -n "$trimmed" ] && [ "$indent" -le "$packages_indent" ]; then
            break
        fi

        if ! $in_list; then
            if [[ "$line" =~ ^[[:space:]]*${key}:[[:space:]]*$ ]]; then
                in_list=true
                list_indent=$indent
            fi
            continue
        fi

        if [ -n "$trimmed" ] && [ "$indent" -le "$list_indent" ] && [[ ! "$trimmed" =~ ^- ]]; then
            break
        fi

        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*(.+)$ ]]; then
            echo "${BASH_REMATCH[1]}" | sed 's/#.*//' | xargs
        fi
    done < "$file"
}

# Parse COPR repositories from YAML
# Usage: parse_copr_repos "file.yaml"
parse_copr_repos() {
    local file="$1"

    if command_exists yq; then
        yq -r '.packages.fedora_copr[]? // ""' "$file" 2>/dev/null | grep -v "^$"
    else
        parse_package_nested_list "$file" "fedora_copr"
    fi
}

# Parse PPA repositories from YAML
# Usage: parse_ppas "file.yaml"
parse_ppas() {
    local file="$1"

    if command_exists yq; then
        yq -r '.packages.debian_ppa[]? // ""' "$file" 2>/dev/null | grep -v "^$"
    else
        parse_package_nested_list "$file" "debian_ppa"
    fi
}

# Enable any extra repositories needed by a package group on the current distro.
# Uses existing distro-specific helpers when available and is best-effort by design.
setup_group_repos() {
    local group_file="$1"
    local group="$2"

    case "${DISTRO_FAMILY:-}" in
        fedora)
            local repo
            while IFS= read -r repo; do
                [ -n "$repo" ] && enable_copr "$repo" || true
            done < <(parse_copr_repos "$group_file")

            case "$group" in
                hyprland) setup_hyprland_repos 2>/dev/null || true ;;
                gaming) setup_gaming_repos 2>/dev/null || true ;;
                multimedia) setup_multimedia_repos 2>/dev/null || true ;;
                productivity) setup_productivity_repos 2>/dev/null || true ;;
            esac
            ;;
        debian)
            local repo
            while IFS= read -r repo; do
                [ -n "$repo" ] && enable_ppa "$repo" || true
            done < <(parse_ppas "$group_file")

            case "$group" in
                hyprland) setup_hyprland_repos 2>/dev/null || true ;;
                gaming) setup_gaming_repos 2>/dev/null || true ;;
                multimedia) setup_multimedia_repos 2>/dev/null || true ;;
                productivity) setup_productivity_repos 2>/dev/null || true ;;
                development) setup_development_repos 2>/dev/null || true ;;
            esac
            ;;
    esac
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
