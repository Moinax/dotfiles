#!/bin/bash
# Main installer script with gum interactive prompts
set -e

# Get script directory and dotfiles root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source library functions
source "$SCRIPT_DIR/lib/detect.sh"
source "$SCRIPT_DIR/lib/common.sh"

# Detect distro
DISTRO=$(detect_distro)
DISTRO_NAME=$(get_distro_name)

# Source distro-specific functions
if [ -f "$SCRIPT_DIR/distros/$DISTRO.sh" ]; then
    source "$SCRIPT_DIR/distros/$DISTRO.sh"
else
    print_error "Unsupported distribution: $DISTRO"
    print_info "Supported distributions: $(get_supported_distros)"
    exit 1
fi

# Check if gum is available
check_gum() {
    if ! command_exists gum; then
        print_error "gum is required but not installed"
        exit 1
    fi
}

# Display welcome banner
show_welcome() {
    clear
    gum style \
        --border double \
        --border-foreground 212 \
        --padding "1 2" \
        --margin "1" \
        "$(gum style --foreground 212 --bold '🏠 Dotfiles Installer')" \
        "" \
        "Detected: $(gum style --foreground 39 "$DISTRO_NAME")"
}

# Confirm distro detection
confirm_distro() {
    echo ""
    if gum confirm "Is this the correct distribution?"; then
        print_success "Distribution confirmed: $DISTRO"
        return 0
    else
        print_error "Please run this installer on a supported distribution"
        print_info "Supported: $(get_supported_distros)"
        exit 1
    fi
}

# Select package groups
select_groups() {
    echo ""
    gum style --foreground 212 --bold "Select package groups to install:"
    echo ""
    
    local groups_dir="$DOTFILES_DIR/packages/groups"
    local options=()
    local descriptions=()
    
    # Read available groups
    for group_file in "$groups_dir"/*.yaml; do
        if [ -f "$group_file" ]; then
            local name=$(basename "$group_file" .yaml)
            local desc=""
            local icon=""
            
            # Parse description and icon from YAML
            if command_exists yq; then
                desc=$(yq -r '.description // ""' "$group_file")
                icon=$(yq -r '.icon // ""' "$group_file")
            else
                desc=$(grep "^description:" "$group_file" | sed 's/description:[[:space:]]*//')
                icon=$(grep "^icon:" "$group_file" | sed 's/icon:[[:space:]]*//')
            fi
            
            options+=("$name")
            descriptions+=("$icon $name - $desc")
        fi
    done
    
    # Show multi-select with gum
    SELECTED_GROUPS=$(printf '%s\n' "${descriptions[@]}" | gum choose --no-limit --header "Space to select, Enter to confirm")
    
    # Extract just the group names from selections
    SELECTED_GROUP_NAMES=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            # Extract group name (second word after icon)
            local group_name=$(echo "$line" | awk '{print $2}')
            SELECTED_GROUP_NAMES+=("$group_name")
        fi
    done <<< "$SELECTED_GROUPS"
    
    if [ ${#SELECTED_GROUP_NAMES[@]} -eq 0 ]; then
        print_warning "No groups selected. Only base packages will be installed."
    else
        print_info "Selected groups: ${SELECTED_GROUP_NAMES[*]}"
    fi
}

# Confirm installation
confirm_installation() {
    echo ""
    gum style --foreground 212 --bold "Installation Summary:"
    echo ""
    echo "  • Distribution: $DISTRO_NAME"
    echo "  • Base packages: Yes"
    if [ ${#SELECTED_GROUP_NAMES[@]} -gt 0 ]; then
        echo "  • Groups: ${SELECTED_GROUP_NAMES[*]}"
    else
        echo "  • Groups: None"
    fi
    echo ""
    
    if gum confirm "Proceed with installation?"; then
        return 0
    else
        print_info "Installation cancelled"
        exit 0
    fi
}

# Install base packages
install_base_packages() {
    print_header "Installing Base Packages"
    
    local base_file="$DOTFILES_DIR/packages/$DISTRO/base.yaml"
    
    if [ ! -f "$base_file" ]; then
        print_error "Base package file not found: $base_file"
        return 1
    fi
    
    # Install yq first for better YAML parsing
    install_yq
    
    # Enable COPR repositories first (Fedora only)
    if [ "$DISTRO" = "fedora" ]; then
        print_info "Enabling COPR repositories..."
        local copr_repos=()
        while IFS= read -r repo; do
            [ -n "$repo" ] && copr_repos+=("$repo")
        done < <(yq -r '.packages.copr.repositories[]? // ""' "$base_file" 2>/dev/null | grep -v "^$")
        
        for repo in "${copr_repos[@]}"; do
            enable_copr "$repo" || true  # Continue even if COPR fails
        done
    fi
    
    # Parse and install core packages
    local packages=()
    while IFS= read -r pkg; do
        [ -n "$pkg" ] && packages+=("$pkg")
    done < <(parse_packages "$base_file" "core")
    
    if [ ${#packages[@]} -gt 0 ]; then
        install_packages "${packages[@]}" || print_warning "Some base packages failed to install"
    fi
    
    # Parse and install AUR packages (Arch only)
    if [ "$DISTRO" = "arch" ]; then
        packages=()
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && packages+=("$pkg")
        done < <(parse_packages "$base_file" "aur")
        
        if [ ${#packages[@]} -gt 0 ]; then
            install_packages "${packages[@]}" || print_warning "Some AUR packages failed to install"
        fi
    fi
    
    print_success "Base packages installed"
}

# Install group packages
install_group_packages() {
    if [ ${#SELECTED_GROUP_NAMES[@]} -eq 0 ]; then
        return 0
    fi
    
    print_header "Installing Group Packages"
    
    local groups_dir="$DOTFILES_DIR/packages/groups"
    
    for group in "${SELECTED_GROUP_NAMES[@]}"; do
        local group_file="$groups_dir/$group.yaml"
        
        if [ ! -f "$group_file" ]; then
            print_warning "Group file not found: $group_file"
            continue
        fi
        
        print_info "Installing $group group..."
        
        # Setup repos if needed (Fedora)
        if [ "$DISTRO" = "fedora" ]; then
            # Enable any COPR repos defined in the group file
            local copr_repos=()
            while IFS= read -r repo; do
                [ -n "$repo" ] && copr_repos+=("$repo")
            done < <(yq -r '.packages.fedora_copr[]? // ""' "$group_file" 2>/dev/null | grep -v "^$")
            
            for repo in "${copr_repos[@]}"; do
                enable_copr "$repo"
            done
            
            # Also run legacy setup functions
            case "$group" in
                hyprland) setup_hyprland_repos 2>/dev/null || true ;;
                gaming) setup_gaming_repos 2>/dev/null || true ;;
                multimedia) setup_multimedia_repos 2>/dev/null || true ;;
                productivity) setup_productivity_repos 2>/dev/null || true ;;
            esac
        fi
        
        # Parse and install packages
        local packages=()
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && packages+=("$pkg")
        done < <(parse_packages "$group_file" "$DISTRO")
        
        if [ ${#packages[@]} -gt 0 ]; then
            install_packages "${packages[@]}" || print_warning "Some packages from $group failed to install"
        fi
        
        # Collect services to enable
        while IFS= read -r service; do
            [ -n "$service" ] && SERVICES_TO_ENABLE+=("$service")
        done < <(parse_services "$group_file")
    done
    
    print_success "Group packages installed"
}

# Install common tools (cross-distro)
install_common_tools() {
    print_header "Installing Common Tools"
    
    local common_file="$DOTFILES_DIR/packages/common.yaml"
    
    if [ ! -f "$common_file" ]; then
        print_warning "Common tools file not found"
        return 0
    fi
    
    # Install zoxide
    if ! command_exists zoxide; then
        install_curl_tool "zoxide" \
            "curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh"
    else
        print_info "zoxide is already installed"
    fi
    
    # Install Volta
    if ! command_exists volta; then
        install_curl_tool "Volta" "curl -fsSL https://get.volta.sh | bash"
        # Source volta for this session
        export VOLTA_HOME="$HOME/.volta"
        export PATH="$VOLTA_HOME/bin:$PATH"
        
        # Install Node.js toolchain
        if command_exists volta; then
            print_info "Installing Node.js and package managers..."
            volta install node npm yarn@1 pnpm || print_warning "Failed to install Node.js tools"
        fi
    else
        print_info "Volta is already installed"
    fi
    
    # Install TPM (Tmux Plugin Manager)
    if [ ! -d "$HOME/.tmux/plugins/tpm" ]; then
        install_git_repo "TPM" "https://github.com/tmux-plugins/tpm" "$HOME/.tmux/plugins/tpm"
        print_info "Run tmux and press Ctrl+b I to install plugins"
    else
        print_info "TPM is already installed"
    fi
    
    # Install rofi themes (only if Hyprland is selected)
    if [[ " ${SELECTED_GROUP_NAMES[*]} " =~ " hyprland " ]]; then
        print_info "Installing Rofi themes collection..."
        local temp_dir="/tmp/rofi-themes-collection"
        local themes_dir="$HOME/.local/share/rofi/themes"
        
        rm -rf "$temp_dir"
        if git clone https://github.com/lr-tech/rofi-themes-collection.git "$temp_dir" 2>/dev/null; then
            # Remove existing symlink, file, or directory if it exists (clean install)
            if [ -L "$themes_dir" ] || [ -f "$themes_dir" ]; then
                rm -f "$themes_dir"
            elif [ -d "$themes_dir" ]; then
                rm -rf "$themes_dir"
            fi
            mkdir -p "$themes_dir"
            cp -r "$temp_dir/themes"/* "$themes_dir/" 2>/dev/null || true
            rm -rf "$temp_dir"
            print_success "Rofi themes installed"
        else
            print_warning "Failed to install Rofi themes"
        fi
    fi
    
    print_success "Common tools installed"
}

# Clean up old stow symlinks before applying chezmoi
cleanup_stow_symlinks() {
    print_info "Cleaning up old symlinks..."
    
    local stow_patterns=(
        "$HOME/.zshrc"
        "$HOME/.tmux.conf"
        "$HOME/.gitconfig"
        "$HOME/Wallpapers"
        "$HOME/completion-for-pnpm.bash"
        "$HOME/.config/hypr"
        "$HOME/.config/waybar"
        "$HOME/.config/rofi"
        "$HOME/.config/kitty"
        "$HOME/.config/nvim"
        "$HOME/.config/mako"
        "$HOME/.config/wlogout"
        "$HOME/.local/share/rofi/themes"
        "$HOME/.cursor/argv.json"
    )
    
    local removed_count=0
    for path in "${stow_patterns[@]}"; do
        if [ -L "$path" ]; then
            rm -f "$path"
            removed_count=$((removed_count + 1))
        fi
    done
    
    # Clean up broken symlinks in .cursor/extensions (from old stow setup)
    if [ -d "$HOME/.cursor/extensions" ]; then
        find "$HOME/.cursor/extensions" -maxdepth 1 -type l ! -exec test -e {} \; -delete 2>/dev/null
    fi
    
    if [ $removed_count -gt 0 ]; then
        print_info "Removed $removed_count old symlinks"
    fi
}

# Setup chezmoi and apply dotfiles
setup_dotfiles() {
    print_header "Setting Up Dotfiles"
    
    # Clean up old stow symlinks first
    cleanup_stow_symlinks
    
    # Warn if running inside Hyprland session
    if [ -n "$HYPRLAND_INSTANCE_SIGNATURE" ]; then
        print_warning "Running inside Hyprland session"
        print_info "You may see transient errors during config migration"
        print_info "Run 'hyprctl reload' after setup completes"
    fi
    
    # Install chezmoi
    install_chezmoi
    
    # Determine which dotfiles to install based on selected groups
    local dotfiles_to_install=()
    
    # Always install base dotfiles
    dotfiles_to_install+=(
        "dot_zshrc"
        "dot_zsh"
        "dot_tmux.conf"
        "dot_gitconfig"
        "dot_config/kitty"
        "dot_config/starship.toml"
        "dot_config/yazi"
        "completion-for-pnpm.bash"
        "Wallpapers"
    )
    
    # Add group-specific dotfiles
    for group in "${SELECTED_GROUP_NAMES[@]}"; do
        local group_file="$DOTFILES_DIR/packages/groups/$group.yaml"
        
        if [ -f "$group_file" ]; then
            while IFS= read -r dotfile; do
                [ -n "$dotfile" ] && dotfiles_to_install+=("$dotfile")
            done < <(parse_dotfiles "$group_file")
        fi
    done
    
    print_info "Dotfiles to install: ${dotfiles_to_install[*]}"
    
    # Create chezmoi config with selected options
    local chezmoi_config="$HOME/.config/chezmoi/chezmoi.toml"
    mkdir -p "$(dirname "$chezmoi_config")"
    
    # Determine boolean flags for groups
    local install_hyprland="false"
    local install_development="false"
    local install_gaming="false"
    local install_multimedia="false"
    local install_productivity="false"
    
    for group in "${SELECTED_GROUP_NAMES[@]}"; do
        case "$group" in
            hyprland) install_hyprland="true" ;;
            development) install_development="true" ;;
            gaming) install_gaming="true" ;;
            multimedia) install_multimedia="true" ;;
            productivity) install_productivity="true" ;;
        esac
    done
    
    cat > "$chezmoi_config" << EOF
[data]
    distro = "$DISTRO"
    install_hyprland = $install_hyprland
    install_development = $install_development
    install_gaming = $install_gaming
    install_multimedia = $install_multimedia
    install_productivity = $install_productivity
EOF
    
    print_info "Chezmoi config created at $chezmoi_config"
    
    # Initialize chezmoi with the dotfiles repo
    print_info "Initializing chezmoi (this may take a while for large dotfiles)..."
    print_info "Source directory: $DOTFILES_DIR/home"
    
    # Count files to give user an idea of progress
    local file_count=$(find "$DOTFILES_DIR/home" -type f | wc -l)
    print_info "Processing ~$file_count files..."
    
    # Run chezmoi (without --verbose to avoid noisy diffs)
    if chezmoi init --source="$DOTFILES_DIR/home" --apply; then
        print_success "Dotfiles applied successfully"
    else
        print_warning "Chezmoi completed with some warnings"
    fi
}

# Enable services
enable_selected_services() {
    if [ ${#SERVICES_TO_ENABLE[@]} -eq 0 ]; then
        return 0
    fi
    
    print_header "Enabling Services"
    
    source "$SCRIPT_DIR/lib/services.sh"
    
    # Remove duplicates
    local unique_services=($(echo "${SERVICES_TO_ENABLE[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
    
    for service in "${unique_services[@]}"; do
        enable_service "$service"
    done
    
    # Add user to docker group if development is selected
    if [[ " ${SELECTED_GROUP_NAMES[*]} " =~ " development " ]]; then
        add_user_to_group "docker"
    fi
    
    print_success "Services enabled"
}

# Setup SSH key
setup_ssh() {
    print_header "SSH Key Setup"
    
    local ssh_dir="$HOME/.ssh"
    local ssh_key="$ssh_dir/id_ed25519"
    
    if [ -f "$ssh_key" ]; then
        print_info "SSH key already exists"
        return 0
    fi
    
    if gum confirm "Generate a new SSH key?"; then
        mkdir -p "$ssh_dir"
        chmod 700 "$ssh_dir"
        
        echo ""
        local passphrase=$(gum input --password --placeholder "Enter passphrase (or leave empty)")
        
        ssh-keygen -t ed25519 -f "$ssh_key" -N "$passphrase"
        chmod 600 "$ssh_key"
        
        print_success "SSH key generated"
        echo ""
        gum style --foreground 39 "Public key:"
        cat "$ssh_key.pub"
        echo ""
        print_info "Add this key to your GitHub/GitLab account"
    fi
}

# Setup shell
setup_shell() {
    print_header "Shell Setup"
    
    local zsh_path=$(which zsh)
    
    if [ -z "$zsh_path" ]; then
        print_error "zsh not found"
        return 1
    fi
    
    if [ "$SHELL" = "$zsh_path" ]; then
        print_info "zsh is already the default shell"
        return 0
    fi
    
    if gum confirm "Change default shell to zsh?"; then
        chsh -s "$zsh_path"
        print_success "Default shell changed to zsh"
        print_info "Log out and back in for changes to take effect"
    fi
}

# Show completion message
show_completion() {
    echo ""
    
    # Build next steps list
    local steps=(
        "  1. Log out and back in (for shell changes)"
        "  2. Run 'tmux' and press Ctrl+b I (install plugins)"
        "  3. Add your SSH key to GitHub/GitLab"
    )
    
    # Add Hyprland step if running in Hyprland or if Hyprland was selected
    if [ -n "$HYPRLAND_INSTANCE_SIGNATURE" ] || [[ " ${SELECTED_GROUP_NAMES[*]} " =~ " hyprland " ]]; then
        steps+=("  4. Run 'hyprctl reload' to reload Hyprland config")
    fi
    
    gum style \
        --border double \
        --border-foreground 82 \
        --padding "1 2" \
        --margin "1" \
        "$(gum style --foreground 82 --bold '✅ Installation Complete!')" \
        "" \
        "Next steps:" \
        "${steps[@]}"
    echo ""
}

# Main installation flow
main() {
    # Initialize arrays
    SELECTED_GROUP_NAMES=()
    SERVICES_TO_ENABLE=()
    
    # Check for gum
    check_gum
    
    # Welcome and confirmation
    show_welcome
    confirm_distro
    
    # Select groups
    select_groups
    
    # Confirm and install
    confirm_installation
    
    # Run installation steps
    update_system
    install_base_packages
    install_group_packages
    install_common_tools
    setup_dotfiles
    enable_selected_services
    setup_ssh
    setup_shell
    
    # Done!
    show_completion
}

# Run main
main "$@"
