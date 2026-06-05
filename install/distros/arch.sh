#!/bin/bash
# Arch Linux specific package management functions

# Source common functions (use local var to avoid overwriting parent's SCRIPT_DIR)
_DISTRO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_DISTRO_DIR/../lib/common.sh"

# Run a pacman/paru command, converting "up to date" messages to info and
# suppressing boilerplate noise. Output is filtered in real time via a pipe
# so that download/install progress remains visible.
_run_pkg_cmd() {
    "$@" 2>&1 | while IFS= read -r line; do
        if [[ "$line" =~ ^warning:\ (.+)\ is\ up\ to\ date\ --\ skipping$ ]]; then
            print_info "Already installed: ${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^::\ (.+)\ is\ up\ to\ date\ --\ skipping$ ]]; then
            print_info "Already installed: ${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^\ *there\ is\ nothing\ to\ do\ *$ ]]; then
            :
        elif [[ "$line" =~ ^::\ (Resolving\ dependencies|Calculating\ (inner\ )?conflicts)\.\.\. ]]; then
            :
        else
            echo "$line"
        fi
    done
    return "${PIPESTATUS[0]}"
}

# Drop packages pinned via pacman's IgnorePkg. An explicit `pacman -S --noconfirm`
# would otherwise auto-answer the "install anyway?" prompt and override the pin.
# Echoes the surviving packages, one per line.
_strip_ignored_pkgs() {
    local ignored
    ignored="$(pacman-conf IgnorePkg 2>/dev/null)" || { printf '%s\n' "$@"; return; }
    local pkg
    for pkg in "$@"; do
        if grep -qxF -- "$pkg" <<<"$ignored"; then
            print_warning "Skipping pinned package (IgnorePkg): $pkg" >&2
        else
            printf '%s\n' "$pkg"
        fi
    done
}

# Check if paru is installed, install if not
ensure_paru() {
    if command_exists paru; then
        print_info "paru is already installed"
        return 0
    fi
    
    print_info "Installing paru (AUR helper)..."
    
    # Ensure base-devel and git are installed
    _run_pkg_cmd sudo pacman -S --needed --noconfirm git base-devel
    
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

# Update the system. With "confirm", the package list is shown and confirmed
# before applying; otherwise it runs non-interactively (used by the installer).
# Prefer paru so AUR packages are updated alongside repo ones (consistent with
# install_packages); paru escalates privileges itself, so it takes no sudo. Fall
# back to pacman (repo only) if paru isn't installed.
update_system() {
    local mgr=(sudo pacman) scope=""
    if command_exists paru; then
        mgr=(paru)
        scope=" (repo + AUR)"
    fi

    if [ "${1:-}" = "confirm" ]; then
        print_info "Checking for system updates${scope}..."
        "${mgr[@]}" -Syu
    else
        print_info "Updating system${scope}..."
        "${mgr[@]}" -Syu --noconfirm
    fi
}

# Install packages using pacman
install_pacman_packages() {
    local packages=("$@")
    
    if [ ${#packages[@]} -eq 0 ]; then
        return 0
    fi

    mapfile -t packages < <(_strip_ignored_pkgs "${packages[@]}")
    if [ ${#packages[@]} -eq 0 ]; then
        return 0
    fi

    print_info "Installing ${#packages[@]} packages with pacman..."
    _run_pkg_cmd sudo pacman -S --needed --noconfirm "${packages[@]}"
}

# Install packages using paru (for AUR packages)
install_paru_packages() {
    local packages=("$@")
    
    if [ ${#packages[@]} -eq 0 ]; then
        return 0
    fi

    mapfile -t packages < <(_strip_ignored_pkgs "${packages[@]}")
    if [ ${#packages[@]} -eq 0 ]; then
        return 0
    fi

    ensure_paru

    print_info "Installing ${#packages[@]} packages with paru..."
    _run_pkg_cmd paru -S --needed --noconfirm "${packages[@]}"
}

# Install all packages (handles both official and AUR)
install_packages() {
    local packages=("$@")
    
    if [ ${#packages[@]} -eq 0 ]; then
        return 0
    fi

    mapfile -t packages < <(_strip_ignored_pkgs "${packages[@]}")
    if [ ${#packages[@]} -eq 0 ]; then
        return 0
    fi

    ensure_paru

    print_info "Installing ${#packages[@]} packages..."
    _run_pkg_cmd paru -S --needed --noconfirm "${packages[@]}"
}

# Remove packages
remove_packages() {
    local packages=("$@")

    if [ ${#packages[@]} -eq 0 ]; then
        return 0
    fi

    print_info "Removing packages: ${packages[*]}"
    sudo pacman -Rns --noconfirm "${packages[@]}"
}

# Check if a package is installed
is_package_installed() {
    local package="$1"
    pacman -Qi "$package" &>/dev/null
}

# List every installed package name, one per line. Used to build an in-memory
# index so callers can test many packages without forking pacman per package.
#
# Beyond the real package names (pacman -Qq), this also emits everything those
# packages Provide/Replace, so virtual or renamed packages resolve the same way
# a per-package `pacman -Qi <name>` would (e.g. `rofi` provides `rofi-wayland`).
list_installed_packages() {
    pacman -Qq 2>/dev/null
    LC_ALL=C pacman -Qi 2>/dev/null | awk -F': ' '
        /^(Provides|Replaces)[[:space:]]*:/ {
            n = split($2, a, /[[:space:]]+/)
            for (i = 1; i <= n; i++) {
                p = a[i]
                sub(/[<>=].*$/, "", p)   # strip version constraints (foo=1.2)
                if (p != "" && p != "None") print p
            }
        }'
}

# Install gum for interactive prompts
install_gum() {
    if command_exists gum; then
        print_info "gum is already installed"
        return 0
    fi
    
    print_info "Installing gum..."
    ensure_paru
    _run_pkg_cmd paru -S --needed --noconfirm gum
}

# Install chezmoi
install_chezmoi() {
    if command_exists chezmoi; then
        print_info "chezmoi is already installed"
        return 0
    fi
    
    print_info "Installing chezmoi..."
    ensure_paru
    _run_pkg_cmd paru -S --needed --noconfirm chezmoi
}

# Install yq for YAML parsing
install_yq() {
    if command_exists yq; then
        print_info "yq is already installed"
        return 0
    fi
    
    print_info "Installing yq..."
    _run_pkg_cmd sudo pacman -S --needed --noconfirm yq
}

# Install AppImage runtime support
install_appimage_support() {
    if is_package_installed fuse2; then
        print_info "AppImage runtime support is already installed via fuse2"
        return 0
    fi

    print_info "Installing AppImage runtime support via fuse2..."
    install_packages fuse2
}
