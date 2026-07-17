#!/bin/bash
# Dotfiles Setup - Bootstrap Script
# This script detects your distribution, installs dependencies, and runs the installer
set -e

# Get script directory and repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Shared print helpers + distro detection
source "$REPO_DIR/install/lib/common.sh"
source "$REPO_DIR/install/lib/detect.sh"

print_header "🏠 Dotfiles Setup - Bootstrap"

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

# Package-manager wrappers (ensure_paru, install_gum, ...) for this family —
# the same bootstrap the installer itself uses, not a second copy.
source "$REPO_DIR/install/distros/$(get_distro_family "$DISTRO").sh"

print_info "Installing dependencies..."
command_exists git || install_pacman_packages git
install_gum

# Enable the repo's git hooks (shellcheck on staged shell scripts)
git -C "$REPO_DIR" config core.hooksPath .githooks

# Make installer executable
chmod +x "$REPO_DIR/install/installer.sh"
chmod +x "$REPO_DIR/install/distros/"*.sh
chmod +x "$REPO_DIR/install/lib/"*.sh

# Run the main installer
print_info "Starting interactive installer..."
echo ""
exec "$REPO_DIR/install/installer.sh"
