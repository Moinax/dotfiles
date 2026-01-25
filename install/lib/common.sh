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
