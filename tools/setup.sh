#!/bin/bash
# Dotfiles Setup - Bootstrap Script
# This script detects your distribution, installs dependencies, and runs the installer
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# Get script directory and repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source distro detection helpers (provides detect_distro, get_distro_family, is_supported_distro)
source "$REPO_DIR/install/lib/detect.sh"

# Show banner
echo ""
echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${PURPLE}            🏠 Dotfiles Setup - Bootstrap${NC}"
echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

DISTRO=$(detect_distro)
print_info "Detected distribution: $DISTRO"

# Check if distro is supported
if is_supported_distro "$DISTRO"; then
    print_success "Distribution is supported"
else
    print_error "Unsupported distribution: $DISTRO"
    print_info "Supported distributions: $(get_supported_distros)"
    exit 1
fi

# Install gum (interactive prompt tool)
install_gum() {
    if command -v gum &> /dev/null; then
        print_info "gum is already installed"
        return 0
    fi

    print_info "Installing gum (interactive prompt tool)..."

    if command -v paru &> /dev/null; then
        paru -S --needed --noconfirm gum
    elif command -v yay &> /dev/null; then
        yay -S --needed --noconfirm gum
    else
        # Install from official repos or AUR
        sudo pacman -S --needed --noconfirm gum 2>/dev/null || {
            print_info "Installing paru first..."
            sudo pacman -S --needed --noconfirm git base-devel
            git clone https://aur.archlinux.org/paru.git /tmp/paru-build
            (cd /tmp/paru-build && makepkg -si --noconfirm)
            rm -rf /tmp/paru-build
            paru -S --needed --noconfirm gum
        }
    fi

    if command -v gum &> /dev/null; then
        print_success "gum installed successfully"
    else
        print_error "Failed to install gum"
        exit 1
    fi
}

# Install git if not present
install_git() {
    if command -v git &> /dev/null; then
        return 0
    fi

    print_info "Installing git..."
    sudo pacman -S --needed --noconfirm git
}

# Main
print_info "Installing dependencies..."
install_git
install_gum

# Make installer executable
chmod +x "$REPO_DIR/install/installer.sh"
chmod +x "$REPO_DIR/install/distros/"*.sh
chmod +x "$REPO_DIR/install/lib/"*.sh

# Run the main installer
print_info "Starting interactive installer..."
echo ""
exec "$REPO_DIR/install/installer.sh"
