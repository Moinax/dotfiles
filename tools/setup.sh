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

install_interrupt_trap

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
# Through _install_with_db_recovery, not bare pacman: this is the first package
# command on a fresh machine, so it is the most likely one to meet a sync
# database older than the mirrors — which 404s on every mirror and cannot be
# fixed by retrying. install_gum and install_yq below already go through it.
command_exists git || _install_with_db_recovery sudo pacman -S --needed --noconfirm git
install_gum
# yq before the installer, not inside it: the package-selection TUI parses every
# YAML in packages/ before install_base_packages would have run, so installing it
# there left the first-install parse — and only that one — without a YAML parser.
install_yq

# Enable the repo's git hooks (shellcheck on staged shell scripts)
git -C "$REPO_DIR" config core.hooksPath .githooks

# Make installer executable
chmod +x "$REPO_DIR/install/installer.sh"
chmod +x "$REPO_DIR/install/distros/"*.sh
chmod +x "$REPO_DIR/install/lib/"*.sh

# Run the main installer
print_info "Starting interactive installer..."
echo ""
exec "$REPO_DIR/install/installer.sh" "$@"
