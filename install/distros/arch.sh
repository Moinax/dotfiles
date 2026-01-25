#!/bin/bash
# Arch Linux specific package management functions

# Source common functions (use local var to avoid overwriting parent's SCRIPT_DIR)
_DISTRO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_DISTRO_DIR/../lib/common.sh"

# Check if paru is installed, install if not
ensure_paru() {
    if command_exists paru; then
        print_info "paru is already installed"
        return 0
    fi
    
    print_info "Installing paru (AUR helper)..."
    
    # Ensure base-devel and git are installed
    sudo pacman -S --needed --noconfirm git base-devel
    
    # Clone and build paru
    local temp_dir="/tmp/paru-build"
    rm -rf "$temp_dir"
    git clone https://aur.archlinux.org/paru.git "$temp_dir"
    
    (
        cd "$temp_dir" || exit 1
        makepkg -si --noconfirm
    )
    
    rm -rf "$temp_dir"
    
    if command_exists paru; then
        print_success "paru installed successfully"
        return 0
    else
        print_error "Failed to install paru"
        return 1
    fi
}

# Update the system
update_system() {
    print_info "Updating system..."
    sudo pacman -Syu --noconfirm
}

# Install packages using pacman
install_pacman_packages() {
    local packages=("$@")
    
    if [ ${#packages[@]} -eq 0 ]; then
        return 0
    fi
    
    print_info "Installing packages with pacman: ${packages[*]}"
    sudo pacman -S --needed --noconfirm "${packages[@]}"
}

# Install packages using paru (for AUR packages)
install_paru_packages() {
    local packages=("$@")
    
    if [ ${#packages[@]} -eq 0 ]; then
        return 0
    fi
    
    ensure_paru
    
    print_info "Installing packages with paru: ${packages[*]}"
    paru -S --needed --noconfirm "${packages[@]}"
}

# Install all packages (handles both official and AUR)
install_packages() {
    local packages=("$@")
    
    if [ ${#packages[@]} -eq 0 ]; then
        return 0
    fi
    
    ensure_paru
    
    print_info "Installing packages: ${packages[*]}"
    paru -S --needed --noconfirm "${packages[@]}"
}

# Check if a package is installed
is_package_installed() {
    local package="$1"
    pacman -Qi "$package" &>/dev/null
}

# Install gum for interactive prompts
install_gum() {
    if command_exists gum; then
        print_info "gum is already installed"
        return 0
    fi
    
    print_info "Installing gum..."
    ensure_paru
    paru -S --needed --noconfirm gum
}

# Install chezmoi
install_chezmoi() {
    if command_exists chezmoi; then
        print_info "chezmoi is already installed"
        return 0
    fi
    
    print_info "Installing chezmoi..."
    ensure_paru
    paru -S --needed --noconfirm chezmoi
}

# Install yq for YAML parsing
install_yq() {
    if command_exists yq; then
        print_info "yq is already installed"
        return 0
    fi
    
    print_info "Installing yq..."
    sudo pacman -S --needed --noconfirm yq
}
