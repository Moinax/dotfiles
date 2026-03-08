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

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source distro detection helpers (provides detect_distro, get_distro_family, is_supported_distro)
source "$SCRIPT_DIR/install/lib/detect.sh"

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

# Install gum based on distro
install_gum() {
    if command -v gum &> /dev/null; then
        print_info "gum is already installed"
        return 0
    fi
    
    print_info "Installing gum (interactive prompt tool)..."
    
    case "$(get_distro_family "$DISTRO")" in
        arch)
            # Check if paru is installed
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
            ;;
        fedora)
            # Try dnf first, then COPR
            sudo dnf install -y gum 2>/dev/null || {
                print_info "Adding COPR repository for gum..."
                sudo dnf copr enable -y atim/gum
                sudo dnf install -y gum
            }
            ;;
        debian)
            # Add Charm apt repository and install gum
            print_info "Adding Charm apt repository for gum..."
            sudo mkdir -p /etc/apt/keyrings
            curl -fsSL https://repo.charm.sh/apt/gpg.key \
                | sudo gpg --yes --dearmor -o /etc/apt/keyrings/charm.gpg
            echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
                | sudo tee /etc/apt/sources.list.d/charm.list > /dev/null
            sudo apt update && sudo apt install -y gum
            ;;
        *)
            print_error "Unsupported distribution: $DISTRO"
            exit 1
            ;;
    esac
    
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
    
    case "$(get_distro_family "$DISTRO")" in
        arch)
            sudo pacman -S --needed --noconfirm git
            ;;
        fedora)
            sudo dnf install -y git
            ;;
        debian)
            sudo apt update && sudo apt install -y git
            ;;
        *)
            print_error "Unsupported distribution: $DISTRO"
            exit 1
            ;;
    esac
}

# Main
print_info "Installing dependencies..."
install_git
install_gum

# Make installer executable
chmod +x "$SCRIPT_DIR/install/installer.sh"
chmod +x "$SCRIPT_DIR/install/distros/"*.sh
chmod +x "$SCRIPT_DIR/install/lib/"*.sh

# Run the main installer
print_info "Starting interactive installer..."
echo ""
exec "$SCRIPT_DIR/install/installer.sh"
