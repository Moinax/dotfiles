#!/bin/bash
# Debian/Ubuntu specific package management functions

# Source common functions (use local var to avoid overwriting parent's SCRIPT_DIR)
_DISTRO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_DISTRO_DIR/../lib/common.sh"

# Update the system
update_system() {
    print_info "Updating system..."
    sudo apt update && sudo apt upgrade -y
}

# Install packages using apt
install_packages() {
    local packages=("$@")

    if [ ${#packages[@]} -eq 0 ]; then
        return 0
    fi

    print_info "Installing ${#packages[@]} packages..."
    # Use --no-install-recommends to keep the install lean
    sudo apt install -y --no-install-recommends "${packages[@]}" || {
        print_warning "Some packages may not have been installed. Check the output above."
    }
}

# Remove packages using apt
remove_packages() {
    local packages=("$@")

    if [ ${#packages[@]} -eq 0 ]; then
        return 0
    fi

    print_info "Removing packages: ${packages[*]}"
    sudo apt remove -y "${packages[@]}"
}

# Enable a PPA repository (Ubuntu only; skipped gracefully on pure Debian)
enable_ppa() {
    local ppa="$1"

    # Pure Debian does not ship add-apt-repository / PPAs
    if ! command_exists add-apt-repository; then
        print_warning "add-apt-repository not available (pure Debian?). Skipping PPA: $ppa"
        return 1
    fi

    print_info "Enabling PPA: $ppa"
    if sudo add-apt-repository -y "ppa:$ppa"; then
        sudo apt update
        return 0
    else
        print_warning "Failed to enable PPA: $ppa"
        return 1
    fi
}

# Add the Charm apt repository (provides gum, etc.)
add_charm_repo() {
    if [ -f /etc/apt/sources.list.d/charm.list ]; then
        print_info "Charm repository already configured"
        return 0
    fi

    print_info "Adding Charm apt repository..."
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key \
        | sudo gpg --yes --dearmor -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
        | sudo tee /etc/apt/sources.list.d/charm.list > /dev/null
    sudo apt update
    print_success "Charm repository added"
}

# Add the GitHub CLI apt repository
add_gh_repo() {
    if [ -f /etc/apt/sources.list.d/github-cli.list ]; then
        print_info "GitHub CLI repository already configured"
        return 0
    fi

    print_info "Adding GitHub CLI apt repository..."
    sudo mkdir -p /usr/share/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    sudo apt update
    print_success "GitHub CLI repository added"
}

# Add the Docker CE apt repository
add_docker_repo() {
    if [ -f /etc/apt/sources.list.d/docker.list ]; then
        print_info "Docker repository already configured"
        return 0
    fi

    print_info "Adding Docker CE apt repository..."
    local distro_id docker_distro
    distro_id=$(. /etc/os-release && echo "$ID")
    case "$distro_id" in
        ubuntu|linuxmint|pop|elementary|neon|zorin) docker_distro="ubuntu" ;;
        *) docker_distro="debian" ;;
    esac
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${docker_distro}/gpg" \
        | sudo gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    local codename
    codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null)}}")
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${docker_distro} $codename stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update
    print_success "Docker repository added"
}

# Add the Tailscale apt repository
add_tailscale_repo() {
    if [ -f /etc/apt/sources.list.d/tailscale.list ]; then
        print_info "Tailscale repository already configured"
        return 0
    fi

    print_info "Adding Tailscale apt repository..."
    local distro_id ts_distro codename
    distro_id=$(. /etc/os-release && echo "$ID")
    case "$distro_id" in
        ubuntu|linuxmint|pop|elementary|neon|zorin) ts_distro="ubuntu" ;;
        *) ts_distro="debian" ;;
    esac
    codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null)}}")
    curl -fsSL "https://pkgs.tailscale.com/stable/${ts_distro}/${codename}.noarch.gpg" \
        | sudo gpg --yes --dearmor -o /etc/apt/keyrings/tailscale.gpg 2>/dev/null || \
    curl -fsSL "https://pkgs.tailscale.com/stable/${ts_distro}/jammy.noarch.gpg" \
        | sudo gpg --yes --dearmor -o /etc/apt/keyrings/tailscale.gpg
    echo "deb [signed-by=/etc/apt/keyrings/tailscale.gpg] https://pkgs.tailscale.com/stable/${ts_distro} ${codename} main" \
        | sudo tee /etc/apt/sources.list.d/tailscale.list > /dev/null
    sudo apt update
    print_success "Tailscale repository added"
}

# Check if a package is installed
is_package_installed() {
    local package="$1"
    dpkg -l "$package" 2>/dev/null | grep -q "^ii"
}

# Install AppImage runtime support using the libfuse2 variant available on the host
install_appimage_support() {
    local fuse_pkg=""

    if apt-cache show libfuse2t64 >/dev/null 2>&1; then
        fuse_pkg="libfuse2t64"
    elif apt-cache show libfuse2 >/dev/null 2>&1; then
        fuse_pkg="libfuse2"
    fi

    if [ -z "$fuse_pkg" ]; then
        print_warning "No supported AppImage runtime package found (libfuse2t64/libfuse2)"
        return 1
    fi

    if is_package_installed "$fuse_pkg"; then
        print_info "AppImage runtime support is already installed via $fuse_pkg"
        return 0
    fi

    print_info "Installing AppImage runtime support via $fuse_pkg..."
    sudo apt install -y --no-install-recommends "$fuse_pkg"
}

# Install gum for interactive prompts
install_gum() {
    if command_exists gum; then
        print_info "gum is already installed"
        return 0
    fi

    print_info "Installing gum..."
    # Try the Charm apt repo first
    if add_charm_repo && sudo apt install -y gum; then
        print_success "gum installed"
        return 0
    fi

    # Fallback: download binary from GitHub releases
    print_warning "apt install failed, falling back to binary download..."
    local version
    version=$(curl -s https://api.github.com/repos/charmbracelet/gum/releases/latest \
        | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
    local arch
    arch=$(dpkg --print-architecture)
    curl -sL "https://github.com/charmbracelet/gum/releases/latest/download/gum_${version}_linux_${arch}.tar.gz" \
        | sudo tar -xz -C /usr/local/bin --wildcards "*/gum" --strip-components=1 2>/dev/null || \
    curl -sL "https://github.com/charmbracelet/gum/releases/latest/download/gum_${version}_linux_${arch}.tar.gz" \
        | sudo tar -xz -C /tmp && sudo mv /tmp/gum /usr/local/bin/gum
    sudo chmod +x /usr/local/bin/gum
    print_success "gum installed (binary)"
}

# Install chezmoi
install_chezmoi() {
    if command_exists chezmoi; then
        print_info "chezmoi is already installed"
        return 0
    fi

    print_info "Installing chezmoi..."
    sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"
}

# Install yq for YAML parsing (binary — not available in apt)
install_yq() {
    if command_exists yq; then
        print_info "yq is already installed"
        return 0
    fi

    print_info "Installing yq (binary)..."
    local deb_arch yq_arch
    deb_arch=$(dpkg --print-architecture)
    case "$deb_arch" in
        amd64)  yq_arch="amd64" ;;
        arm64)  yq_arch="arm64" ;;
        armhf)  yq_arch="arm" ;;
        *)      yq_arch="$deb_arch" ;;
    esac
    sudo curl -sL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${yq_arch}" \
        -o /usr/local/bin/yq
    sudo chmod +x /usr/local/bin/yq
    print_success "yq installed"
}

# Install lazygit (not in apt — binary from GitHub releases)
install_lazygit() {
    if command_exists lazygit; then
        print_info "lazygit is already installed"
        return 0
    fi

    print_info "Installing lazygit (binary)..."
    local version goarch
    version=$(curl -s https://api.github.com/repos/jesseduffield/lazygit/releases/latest \
        | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
    case "$(uname -m)" in
        x86_64)  goarch="x86_64" ;;
        aarch64) goarch="arm64" ;;
        armv7l)  goarch="armv6" ;;
        *)       goarch="$(uname -m)" ;;
    esac
    curl -sL "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${version}_Linux_${goarch}.tar.gz" \
        | sudo tar -xz -C /usr/local/bin lazygit
    sudo chmod +x /usr/local/bin/lazygit
    print_success "lazygit installed"
}

# Install starship prompt (via official curl install script)
install_starship() {
    if command_exists starship; then
        print_info "starship is already installed"
        return 0
    fi

    print_info "Installing starship..."
    curl -sS https://starship.rs/install.sh | sudo sh -s -- --yes
    print_success "starship installed"
}

# Install fastfetch (via PPA on Ubuntu, .deb binary fallback)
install_fastfetch() {
    if command_exists fastfetch; then
        print_info "fastfetch is already installed"
        return 0
    fi

    print_info "Installing fastfetch..."
    # Try PPA first (Ubuntu only)
    if enable_ppa "zhangsongcui3371/fastfetch" 2>/dev/null; then
        sudo apt install -y fastfetch && {
            print_success "fastfetch installed"
            return 0
        }
    fi

    # Fallback: download .deb from GitHub releases
    print_info "Falling back to .deb download for fastfetch..."
    local arch tmp_deb="/tmp/fastfetch.deb"
    arch=$(dpkg --print-architecture)
    curl -sL "https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-${arch}.deb" \
        -o "$tmp_deb"
    sudo dpkg -i "$tmp_deb"
    rm -f "$tmp_deb"
    print_success "fastfetch installed"
}

# Install yazi terminal file manager (binary from GitHub releases)
install_yazi() {
    if command_exists yazi; then
        print_info "yazi is already installed"
        return 0
    fi

    print_info "Installing yazi (binary)..."
    local goarch
    local tmp_zip="/tmp/yazi.zip"
    trap 'rm -rf "$tmp_zip" /tmp/yazi-extract' RETURN
    case "$(uname -m)" in
        x86_64)  goarch="x86_64" ;;
        aarch64) goarch="aarch64" ;;
        armv7l)  goarch="armv7" ;;
        *)       goarch="$(uname -m)" ;;
    esac
    curl -sL "https://github.com/sxyazi/yazi/releases/latest/download/yazi-${goarch}-unknown-linux-gnu.zip" \
        -o "$tmp_zip"
    unzip -q "$tmp_zip" -d /tmp/yazi-extract
    sudo mv "/tmp/yazi-extract/yazi-${goarch}-unknown-linux-gnu/yazi" /usr/local/bin/
    sudo chmod +x /usr/local/bin/yazi
    print_success "yazi installed"
}

# Install Flatpak and add Flathub remote
install_flatpak() {
    print_info "Installing Flatpak..."
    sudo apt install -y flatpak

    # Add Flathub remote
    if ! flatpak remotes 2>/dev/null | grep -q flathub; then
        print_info "Adding Flathub remote..."
        flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
        print_success "Flathub remote added"
    else
        print_info "Flathub remote already configured"
    fi
}

# Post-install alias check: on Debian/Ubuntu, bat is installed as 'batcat'
post_install_bat_alias() {
    if command_exists batcat && ! command_exists bat; then
        print_info "Note: 'bat' is installed as 'batcat' on Debian/Ubuntu"
        print_info "Creating 'bat' symlink in ~/.local/bin..."
        mkdir -p "$HOME/.local/bin"
        ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"
        print_success "bat alias created at ~/.local/bin/bat"
    fi
}

# Setup repos for Hyprland group (Ubuntu 24.04+ universe repository)
setup_hyprland_repos() {
    print_info "Setting up Hyprland repositories for Debian/Ubuntu..."
    # Hyprland is available in the Ubuntu 24.04 universe repository
    if command_exists add-apt-repository; then
        sudo add-apt-repository -y universe 2>/dev/null || true
        sudo apt update
    fi
}

# Setup repos for gaming (enable multiverse + i386 for Steam)
setup_gaming_repos() {
    print_info "Setting up gaming repositories..."
    if command_exists add-apt-repository; then
        sudo add-apt-repository -y multiverse 2>/dev/null || true
    fi
    # Enable 32-bit architecture required by Steam
    sudo dpkg --add-architecture i386
    sudo apt update
}

# Setup repos for multimedia (restricted + universe on Ubuntu)
setup_multimedia_repos() {
    print_info "Setting up multimedia repositories..."
    if command_exists add-apt-repository; then
        sudo add-apt-repository -y restricted 2>/dev/null || true
        sudo add-apt-repository -y universe 2>/dev/null || true
        sudo apt update
    fi
}

# Setup repos for productivity (Google Chrome, Slack, etc.)
setup_productivity_repos() {
    print_info "Setting up productivity repositories..."

    # Google Chrome
    if [ ! -f /etc/apt/sources.list.d/google-chrome.list ]; then
        print_info "Adding Google Chrome repository..."
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
            | sudo gpg --yes --dearmor -o /etc/apt/keyrings/google-chrome.gpg
        echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
            | sudo tee /etc/apt/sources.list.d/google-chrome.list > /dev/null
        sudo apt update
        print_success "Google Chrome repository added"
    fi

    # Slack
    if [ ! -f /etc/apt/sources.list.d/slack.list ]; then
        print_info "Adding Slack repository..."
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://packagecloud.io/slacktechnologies/slack/gpgkey \
            | sudo gpg --yes --dearmor -o /etc/apt/keyrings/slack.gpg
        echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/slack.gpg] https://packagecloud.io/slacktechnologies/slack/debian/ jessie main" \
            | sudo tee /etc/apt/sources.list.d/slack.list > /dev/null
        sudo apt update
        print_success "Slack repository added"
    fi

}

# Setup repos for development (GitHub CLI, Docker CE, Tailscale)
setup_development_repos() {
    add_gh_repo
    add_docker_repo
    add_tailscale_repo
}
