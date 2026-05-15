#!/bin/bash
# Fedora specific package management functions

# Source common functions (use local var to avoid overwriting parent's SCRIPT_DIR)
_DISTRO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_DISTRO_DIR/../lib/common.sh"

# Update the system
update_system() {
    print_info "Updating system..."
    sudo dnf upgrade -y --refresh
}

# Install packages using dnf
install_packages() {
    local packages=("$@")
    
    if [ ${#packages[@]} -eq 0 ]; then
        return 0
    fi
    
    print_info "Installing ${#packages[@]} packages..."
    # --skip-unavailable: continue even if some packages aren't found
    # --allowerasing: allow replacing conflicting packages (e.g. ffmpeg-free → ffmpeg from RPM Fusion)
    sudo dnf install -y --skip-unavailable --allowerasing "${packages[@]}" || {
        print_warning "Some packages may not have been installed. Check the output above."
    }
}

# Remove packages using dnf
remove_packages() {
    local packages=("$@")

    if [ ${#packages[@]} -eq 0 ]; then
        return 0
    fi

    print_info "Removing packages: ${packages[*]}"
    sudo dnf remove -y "${packages[@]}"
}

# Enable a COPR repository
enable_copr() {
    local repo="$1"
    
    print_info "Enabling COPR repository: $repo"
    if ! sudo dnf copr enable -y "$repo" 2>/dev/null; then
        track_warning "Failed to enable COPR: $repo (may not exist for this Fedora version)"
        return 1
    fi
    return 0
}

# Enable RPM Fusion repositories
enable_rpmfusion() {
    print_info "Enabling RPM Fusion repositories..."
    
    # Free repository
    if ! rpm -q rpmfusion-free-release &>/dev/null; then
        sudo dnf install -y \
            "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
    fi
    
    # Non-free repository
    if ! rpm -q rpmfusion-nonfree-release &>/dev/null; then
        sudo dnf install -y \
            "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"
    fi
    
    print_success "RPM Fusion repositories enabled"
}

# Enable Google Chrome repository
enable_google_chrome_repo() {
    local repo_file="/etc/yum.repos.d/google-chrome.repo"
    
    if [ -f "$repo_file" ]; then
        print_info "Google Chrome repository already configured"
        return 0
    fi
    
    print_info "Adding Google Chrome repository..."
    sudo tee "$repo_file" > /dev/null << 'EOF'
[google-chrome]
name=google-chrome
baseurl=https://dl.google.com/linux/chrome/rpm/stable/x86_64
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
EOF
    
    print_success "Google Chrome repository added"
}

# Enable Slack repository
enable_slack_repo() {
    local repo_file="/etc/yum.repos.d/slack.repo"

    if [ -f "$repo_file" ]; then
        print_info "Slack repository already configured"
        return 0
    fi

    print_info "Adding Slack repository..."
    sudo tee "$repo_file" > /dev/null << 'EOF'
[slack]
name=slack
baseurl=https://packagecloud.io/slacktechnologies/slack/fedora/21/x86_64
enabled=1
gpgcheck=0
gpgkey=https://packagecloud.io/slacktechnologies/slack/gpgkey
EOF

    print_success "Slack repository added"
}

# Check if a package is installed
is_package_installed() {
    local package="$1"
    rpm -q "$package" &>/dev/null
}

# Install gum for interactive prompts
install_gum() {
    if command_exists gum; then
        print_info "gum is already installed"
        return 0
    fi
    
    print_info "Installing gum..."
    # Charm has a COPR for gum
    enable_copr "atim/gum" 2>/dev/null || true
    sudo dnf install -y gum
}

# Install chezmoi
install_chezmoi() {
    if command_exists chezmoi; then
        print_info "chezmoi is already installed"
        return 0
    fi
    
    print_info "Installing chezmoi..."
    sudo dnf install -y chezmoi || {
        # Fallback to official install script
        sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"
    }
}

# Install yq for YAML parsing
install_yq() {
    if command_exists yq; then
        print_info "yq is already installed"
        return 0
    fi
    
    print_info "Installing yq..."
    sudo dnf install -y yq || {
        # Fallback to binary installation
        local version="v4.40.5"
        sudo wget -qO /usr/local/bin/yq \
            "https://github.com/mikefarah/yq/releases/download/${version}/yq_linux_amd64"
        sudo chmod +x /usr/local/bin/yq
    }
}

# Install AppImage runtime support
install_appimage_support() {
    local runtime_packages=(fuse fuse-libs)

    if is_package_installed fuse || is_package_installed fuse-libs; then
        print_info "AppImage runtime support is already installed"
        return 0
    fi

    print_info "Installing AppImage runtime support..."
    install_packages "${runtime_packages[@]}" || {
        print_warning "Failed to install AppImage runtime packages"
        return 1
    }
    print_success "AppImage runtime support installed"
}

# Setup COPR repos for specific package groups
setup_hyprland_repos() {
    print_info "Setting up Hyprland COPR repositories..."
    enable_copr "solopasha/hyprland"
}

# Setup repos for gaming
setup_gaming_repos() {
    enable_rpmfusion
}

# Setup repos for multimedia
setup_multimedia_repos() {
    enable_rpmfusion
}

# Setup repos for productivity (Google Chrome, etc.)
# Note: grub-btrfs COPR is handled via fedora_copr key in productivity.yaml
setup_productivity_repos() {
    enable_google_chrome_repo
    enable_slack_repo
}
