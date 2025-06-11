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
    sudo pacman -S --needed git base-devel
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si
    cd -
    rm -rf yay
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

# Install zoxide
echo "Installing zoxide..."
if ! command -v zoxide &> /dev/null; then
    curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh || {
        echo "Failed to install zoxide"
        exit 1
    }
    echo "zoxide installation complete."
else
    echo "zoxide is already installed."
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
    stow cursor dunst git hypr kitty nvim pnpm rofi starship tmux wallpapers waybar yazi zsh
fi

# Setup SSH key
echo "Setting up SSH key..."
SSH_DIR="$HOME/.ssh"
SSH_KEY="$SSH_DIR/id_ed25519"

if [ ! -f "$SSH_KEY" ]; then
    echo "No SSH key found. Generating new ED25519 key..."
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    
    # Prompt for passphrase
    echo "Please enter a passphrase for your SSH key (or press Enter for no passphrase):"
    read -s PASSPHRASE
    echo "Please confirm your passphrase:"
    read -s PASSPHRASE_CONFIRM
    
    if [ "$PASSPHRASE" != "$PASSPHRASE_CONFIRM" ]; then
        echo "Passphrases do not match. Please try again."
        exit 1
    fi
    
    # Generate SSH key with passphrase
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "$PASSPHRASE" || {
        echo "Failed to generate SSH key"
        exit 1
    }
    chmod 600 "$SSH_KEY"
    echo "SSH key generated successfully."
    echo "Public key:"
    cat "$SSH_KEY.pub"
    echo "Please add this public key to your GitHub/GitLab account."
else
    echo "SSH key already exists."
fi

# Setup keychain
echo "Setting up keychain..."
if command -v keychain &> /dev/null; then
    keychain --eval ssh "$SSH_KEY" || {
        echo "Failed to setup keychain"
        exit 1
    }
    echo "Keychain setup complete."
else
    echo "Keychain not found. Skipping keychain setup."
fi

# Change default shell to zsh
echo "Changing default shell to zsh..."
ZSH_PATH=$(which zsh)
if [ -z "$ZSH_PATH" ]; then
    echo "Error: zsh not found"
    exit 1
fi

if [ "$SHELL" != "$ZSH_PATH" ]; then
    chsh -s "$ZSH_PATH" || {
        echo "Failed to change shell to zsh"
        exit 1
    }
    echo "Default shell changed to zsh. Please log out and log back in for the changes to take effect."
else
    echo "zsh is already the default shell."
fi

echo "Setup completed successfully!"
