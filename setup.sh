#!/bin/bash

# Exit on error
set -e

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Installing jq..."
    sudo pacman -S --noconfirm jq
fi

# Update system first
echo "Updating system..."
sudo pacman -Syu --noconfirm

# Check if yay is installed
if ! command -v yay &> /dev/null; then
    echo "Installing yay..."
    sudo pacman -S --noconfirm yay-git
fi

# Read packages from JSON file
if [ ! -f "packages.json" ]; then
    echo "Error: packages.json not found!"
    exit 1
fi

# Install all packages from the JSON file
echo "Installing packages..."
packages=$(jq -r '.packages[]' packages.json)
yay -S --noconfirm $packages

# Install extra tools 
echo "Installing tools..."

# Check if git is installed (needed for TPM)
if ! command -v git &> /dev/null; then
    echo "Installing git..."
    yay -S --noconfirm git
fi

# Install Volta
if ! command -v volta &> /dev/null; then
    echo "Installing Volta..."
    curl -fsSL https://get.volta.sh | bash || {
        echo "Failed to install Volta"
        exit 1
    }
    echo "Volta installation complete."
    echo "Please re-source your shell or open a new terminal to use Volta"
else
    echo "Volta is already installed."
fi

# Install Node.js and Package Managers with Volta
if command -v volta &> /dev/null; then
    echo "Installing Node.js and package managers with Volta..."
    volta install node npm yarn@1 pnpm || {
        echo "Failed to install Node.js or package managers"
        exit 1
    }
    echo "Volta installations complete."
else
    echo "Volta not found. Skipping Node.js and package manager installations with Volta."
fi

# Install Tmux Plugin Manager (TPM)
echo "Installing Tmux Plugin Manager (TPM)..."
if [ ! -d "$HOME/.tmux/plugins/tpm" ]; then
    git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm || {
        echo "Failed to install TPM"
        exit 1
    }
    echo "TPM installation complete."
else
    echo "TPM is already installed."
fi
echo "You should run tmux and type [CTRL+b I] to install all plugins."

echo "Extra tools installation complete."

# Enable and start services
echo "Enabling and starting services..."
sudo systemctl enable --now bluetooth
sudo systemctl enable --now docker
sudo systemctl enable --now NetworkManager

# If using Chezmoi:
# Assuming Chezmoi is already installed (now included in packages list for Linux, manual for brew)
# echo "Applying Chezmoi dotfiles..."
# chezmoi apply
# echo "Chezmoi apply complete."

# If using Stow:
# Assuming Stow is already installed (now included in packages list)

# Install dotfiles if they exist
if [ -d "$HOME/dotfiles" ]; then
    echo "Installing dotfiles..."
    cd "$HOME/dotfiles"
    stow .
fi

echo "Setup completed successfully!"
