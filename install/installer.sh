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

# Installer state
SELECTED_GROUP_NAMES=()
SERVICES_TO_ENABLE=()
declare -A GROUP_PACKAGE_MODE=()
declare -A GROUP_CUSTOM_PACKAGE_LIST=()
HYPRVOICE_MODEL="small"

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
    local group_files=()
    local labels=()
    local all_groups_label="✨ all-groups - install every group"
    local line

    # Read available groups in a stable order
    shopt -s nullglob
    group_files=("$groups_dir"/*.yaml)
    shopt -u nullglob

    if [ ${#group_files[@]} -eq 0 ]; then
        print_warning "No group definitions found."
        SELECTED_GROUP_NAMES=()
        return 0
    fi

    IFS=$'\n' group_files=($(printf '%s\n' "${group_files[@]}" | sort))
    unset IFS

    # Build display labels and an exact label->group map
    local -A label_to_group=()
    labels+=("$all_groups_label")
    for group_file in "${group_files[@]}"; do
        local name=$(basename "$group_file" .yaml)
        local desc=""
        local icon=""

        if command_exists yq; then
            desc=$(yq -r '.description // ""' "$group_file")
            icon=$(yq -r '.icon // ""' "$group_file")
        else
            desc=$(grep "^description:" "$group_file" | sed 's/description:[[:space:]]*//')
            icon=$(grep "^icon:" "$group_file" | sed 's/icon:[[:space:]]*//')
        fi

        local label="$icon $name - $desc"
        labels+=("$label")
        label_to_group["$label"]="$name"
    done

    # Show multi-select with gum
    local selected_labels
    selected_labels=$(printf '%s\n' "${labels[@]}" | gum choose --no-limit --header "Space to select, Enter to confirm")

    SELECTED_GROUP_NAMES=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [ "$line" = "$all_groups_label" ]; then
            SELECTED_GROUP_NAMES=()
            for group_file in "${group_files[@]}"; do
                SELECTED_GROUP_NAMES+=("$(basename "$group_file" .yaml)")
            done
            break
        fi

        local mapped_group="${label_to_group[$line]}"
        [ -n "$mapped_group" ] && SELECTED_GROUP_NAMES+=("$mapped_group")
    done <<< "$selected_labels"

    # Remove duplicates while preserving order
    local deduped_groups=()
    local -A seen_groups=()
    for line in "${SELECTED_GROUP_NAMES[@]}"; do
        if [ -z "${seen_groups[$line]}" ]; then
            deduped_groups+=("$line")
            seen_groups["$line"]=1
        fi
    done
    SELECTED_GROUP_NAMES=("${deduped_groups[@]}")

    if [ ${#SELECTED_GROUP_NAMES[@]} -eq 0 ]; then
        print_warning "No groups selected. Only base packages will be installed."
    else
        print_info "Selected groups: ${SELECTED_GROUP_NAMES[*]}"
    fi
}

# Select package install mode per group (two-pass: default all, optionally customize)
select_group_packages() {
    unset GROUP_PACKAGE_MODE GROUP_CUSTOM_PACKAGE_LIST
    declare -gA GROUP_PACKAGE_MODE=()
    declare -gA GROUP_CUSTOM_PACKAGE_LIST=()

    if [ ${#SELECTED_GROUP_NAMES[@]} -eq 0 ]; then
        return 0
    fi

    # Default all groups to "all packages"
    for group in "${SELECTED_GROUP_NAMES[@]}"; do
        GROUP_PACKAGE_MODE["$group"]="all"
    done

    # Skip customize prompt if only 1 group selected
    if [ ${#SELECTED_GROUP_NAMES[@]} -le 1 ]; then
        return 0
    fi

    # Ask which groups to customize (single multi-select screen)
    echo ""
    gum style --foreground 212 --bold "Customize packages?"
    echo ""
    print_info "By default, all packages in each group are installed."
    print_info "Select groups below to pick individual packages instead."
    echo ""

    local customize_labels=()
    local -A clabel_to_group=()
    for group in "${SELECTED_GROUP_NAMES[@]}"; do
        local group_file="$DOTFILES_DIR/packages/groups/$group.yaml"
        local icon=""
        if command_exists yq; then
            icon=$(yq -r '.icon // ""' "$group_file")
        else
            icon=$(grep "^icon:" "$group_file" | sed 's/icon:[[:space:]]*//')
        fi
        local label="$icon $group"
        customize_labels+=("$label")
        clabel_to_group["$label"]="$group"
    done

    local selected_custom
    selected_custom=$(printf '%s\n' "${customize_labels[@]}" \
        | gum choose --no-limit --header "Space to select, Enter to confirm (or Enter with none to install all)") || true

    # Process customized groups
    local line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local group="${clabel_to_group[$line]}"
        [ -z "$group" ] && continue

        local group_file="$DOTFILES_DIR/packages/groups/$group.yaml"
        local all_packages=()
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && all_packages+=("$pkg")
        done < <(parse_packages "$group_file" "$DISTRO")

        if [ ${#all_packages[@]} -eq 0 ]; then
            print_warning "No $DISTRO packages for '$group'; skipping."
            GROUP_PACKAGE_MODE["$group"]="skip"
            continue
        fi

        local selected_packages
        selected_packages=$(printf '%s\n' "${all_packages[@]}" \
            | gum choose --no-limit --header "Select packages for '$group'")

        if [ -z "$selected_packages" ]; then
            GROUP_PACKAGE_MODE["$group"]="skip"
            print_warning "No packages selected for '$group'; only dotfiles/services will apply."
        else
            GROUP_PACKAGE_MODE["$group"]="custom"
            GROUP_CUSTOM_PACKAGE_LIST["$group"]="$selected_packages"
        fi
    done <<< "$selected_custom"
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
        
        # Parse package candidates
        local all_packages=()
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && all_packages+=("$pkg")
        done < <(parse_packages "$group_file" "$DISTRO")

        # Resolve install package list from selected mode
        local packages=()
        local package_mode="${GROUP_PACKAGE_MODE[$group]:-all}"
        case "$package_mode" in
            skip)
                print_info "Skipping package install for $group (selected mode: skip)"
                ;;
            custom)
                while IFS= read -r pkg; do
                    [ -n "$pkg" ] && packages+=("$pkg")
                done <<< "${GROUP_CUSTOM_PACKAGE_LIST[$group]}"
                ;;
            *)
                packages=("${all_packages[@]}")
                ;;
        esac
        
        if [ ${#packages[@]} -gt 0 ]; then
            install_packages "${packages[@]}" || print_warning "Some packages from $group failed to install"
        elif [ "$package_mode" != "skip" ]; then
            print_warning "No packages resolved for group $group"
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
    
    # Install rofi themes when a Wayland compositor group is selected
    if [[ " ${SELECTED_GROUP_NAMES[*]} " =~ " hyprland " ]] || [[ " ${SELECTED_GROUP_NAMES[*]} " =~ " niri " ]]; then
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

    # Setup hyprvoice (AI group)
    if [[ " ${SELECTED_GROUP_NAMES[*]} " =~ " ai " ]]; then
        # Install hyprvoice binary (Fedora only — Arch uses AUR package)
        if [ "$DISTRO" = "fedora" ] && ! command_exists hyprvoice; then
            install_curl_tool "hyprvoice" \
                "curl -sL https://github.com/LeonardoTrapani/hyprvoice/releases/latest/download/hyprvoice-linux-x86_64 -o ~/.local/bin/hyprvoice && chmod +x ~/.local/bin/hyprvoice"
        elif command_exists hyprvoice; then
            print_info "hyprvoice is already installed"
        fi

        # Download whisper model for local transcription
        if command_exists hyprvoice; then
            print_info "Hyprvoice supports local speech-to-text via whisper models"
            HYPRVOICE_MODEL=$(gum choose --header "Select a whisper model for dictation:" \
                "small (500MB — good accuracy, EN+FR)" \
                "medium (1.5GB — better accuracy, EN+FR)" \
                "tiny (75MB — fastest, lower accuracy)" \
                "Skip — download later")

            # Extract model name (first word before space)
            HYPRVOICE_MODEL="${HYPRVOICE_MODEL%% *}"

            if [ "$HYPRVOICE_MODEL" != "Skip" ]; then
                print_info "Downloading whisper model: $HYPRVOICE_MODEL"
                if hyprvoice model download "$HYPRVOICE_MODEL"; then
                    print_success "Whisper model '$HYPRVOICE_MODEL' downloaded"
                else
                    print_warning "Failed to download model — run 'hyprvoice model download $HYPRVOICE_MODEL' later"
                    HYPRVOICE_MODEL="small"
                fi
            else
                HYPRVOICE_MODEL="small"  # Default for config
            fi
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
        "$HOME/.config/niri"
        "$HOME/.config/waybar"
        "$HOME/.config/rofi"
        "$HOME/.config/kitty"
        "$HOME/.config/nvim"
        "$HOME/.config/mako"
        "$HOME/.local/share/rofi/themes"
        "$HOME/.cursor/argv.json"
    )
    
    local removed_count=0
    for path in "${stow_patterns[@]}"; do
        if [ -L "$path" ]; then
            if rm -f "$path" 2>/dev/null || sudo rm -f "$path"; then
                removed_count=$((removed_count + 1))
            else
                print_warning "Could not remove symlink: $path"
            fi
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
    
    # Keep existing sourceDir if user already has a working config (e.g. from manual fix or previous run)
    local source_dir="$DOTFILES_DIR/home"
    if [[ -f "$chezmoi_config" ]]; then
        local existing_source
        existing_source=$(grep -E '^\s*sourceDir\s*=' "$chezmoi_config" | head -1 | sed -E 's/^[^=]*=\s*["]?([^"]*)["]?.*/\1/' | tr -d '"' | tr -d "'")
        if [[ -n "$existing_source" && -d "$existing_source" ]]; then
            source_dir="$existing_source"
            print_info "Preserving existing chezmoi sourceDir: $source_dir"
        fi
    fi
    
    # Determine boolean flags for groups
    local install_hyprland="false"
    local install_niri="false"
    local install_development="false"
    local install_gaming="false"
    local install_multimedia="false"
    local install_productivity="false"
    local install_ai="false"

    for group in "${SELECTED_GROUP_NAMES[@]}"; do
        case "$group" in
            hyprland) install_hyprland="true" ;;
            niri) install_niri="true" ;;
            development) install_development="true" ;;
            gaming) install_gaming="true" ;;
            multimedia) install_multimedia="true" ;;
            productivity) install_productivity="true" ;;
            ai) install_ai="true" ;;
        esac
    done
    
    cat > "$chezmoi_config" << EOF
# Use this repo's home directory as chezmoi source (so 'chezmoi diff' etc. work without -S)
sourceDir = "$source_dir"

[data]
    distro = "$DISTRO"
    install_hyprland = $install_hyprland
    install_niri = $install_niri
    install_development = $install_development
    install_gaming = $install_gaming
    install_multimedia = $install_multimedia
    install_productivity = $install_productivity
    install_ai = $install_ai
    hyprvoice_model = "$HYPRVOICE_MODEL"
EOF
    
    print_info "Chezmoi config created at $chezmoi_config"
    
    # Initialize chezmoi with the dotfiles repo
    print_info "Initializing chezmoi (this may take a while for large dotfiles)..."
    print_info "Source directory: $source_dir"
    
    # Count files to give user an idea of progress
    local file_count=$(find "$source_dir" -type f | wc -l)
    print_info "Processing ~$file_count files..."
    
    # Run chezmoi (--force to skip overwrite prompts, e.g. rofi themes already on disk)
    if chezmoi init --source="$source_dir" --apply --force; then
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

# Setup SDDM (wallpaper, Wayland compositor, display manager)
setup_sddm() {
    # Only run if a compositor group was selected
    if ! [[ " ${SELECTED_GROUP_NAMES[*]} " =~ " niri " ]] && ! [[ " ${SELECTED_GROUP_NAMES[*]} " =~ " hyprland " ]]; then
        return
    fi

    if ! command_exists sddm; then
        return
    fi

    print_header "SDDM Setup"

    # --- Wallpaper ---
    local wallpaper="$DOTFILES_DIR/home/Wallpapers/colorful.jpg"
    local theme
    theme=$(grep -rh "^Current=" /etc/sddm.conf /etc/sddm.conf.d/ 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '[:space:]')
    if [ -z "$theme" ]; then
        theme=$(ls /usr/share/sddm/themes/ 2>/dev/null | head -1)
    fi

    if [ -n "$theme" ] && [ -d "/usr/share/sddm/themes/$theme" ] && [ -f "$wallpaper" ]; then
        print_info "Setting wallpaper on '$theme' theme..."
        sudo cp "$wallpaper" "/usr/share/sddm/themes/$theme/wallpaper.jpg"
        sudo tee "/usr/share/sddm/themes/$theme/theme.conf.user" > /dev/null <<EOF
[General]
background=/usr/share/sddm/themes/$theme/wallpaper.jpg
EOF
    fi

    # --- SDDM configuration (theme + Wayland) ---
    sudo mkdir -p /etc/sddm.conf.d
    sudo tee /etc/sddm.conf.d/theme.conf > /dev/null <<EOF
[Theme]
Current=${theme:-breeze}

[General]
DisplayServer=wayland

[Wayland]
CompositorCommand=weston --shell=kiosk -c /etc/sddm/weston.ini
EOF

    # --- Weston config for Wayland greeter ---
    sudo mkdir -p /etc/sddm

    # Detect keyboard layout from localectl, fallback to "us"
    local kb_layout
    kb_layout=$(localectl status 2>/dev/null | grep "X11 Layout" | awk '{print $3}')
    kb_layout=${kb_layout:-us}

    # Build weston.ini with keyboard layout and monitor rotation
    local weston_cfg
    weston_cfg="[core]
shell=kiosk-shell.so

[keyboard]
keymap_layout=${kb_layout}"

    # Detect connected monitors via xrandr
    # Only the non-rotated (horizontal) monitor is enabled for the greeter;
    # rotated monitors are disabled (mode=off) so the greeter lands on the right screen.
    # They turn back on once the user session compositor (Hyprland/Niri) starts.
    if command -v xrandr &>/dev/null; then
        while IFS= read -r line; do
            local output_name rotation mode transform
            output_name=$(echo "$line" | awk '{print $1}')
            # Check if rotation keyword is present before the parenthesized list of supported rotations
            rotation=$(echo "$line" | sed 's/(.*//' | grep -oE '\b(left|right|inverted)\b' || true)
            if [ -n "$rotation" ]; then
                # Rotated monitor — disable it during login screen
                weston_cfg="${weston_cfg}

[output]
name=${output_name}
mode=off"
            else
                # Non-rotated monitor — enable with native resolution
                mode=$(xrandr --query 2>/dev/null | grep -A 1 "^${output_name} connected" | tail -1 | awk '{print $1}')
                if [ -n "$output_name" ] && [ -n "$mode" ]; then
                    weston_cfg="${weston_cfg}

[output]
name=${output_name}
mode=${mode}
transform=normal"
                fi
            fi
        done < <(xrandr --query 2>/dev/null | grep " connected ")
    fi

    echo "$weston_cfg" | sudo tee /etc/sddm/weston.ini > /dev/null

    # --- Enable SDDM as display manager ---
    local current_dm
    current_dm=$(basename "$(readlink /etc/systemd/system/display-manager.service 2>/dev/null)" .service 2>/dev/null)
    if [ "$current_dm" != "sddm" ]; then
        echo ""
        print_info "SDDM is not your current display manager (currently: ${current_dm:-none})"
        print_info "The login screen wallpaper requires SDDM to be active"
        if gum confirm "Switch to SDDM as your display manager?"; then
            if [ -n "$current_dm" ]; then
                print_info "Disabling $current_dm..."
                sudo systemctl disable "$current_dm" 2>/dev/null
            fi
            print_info "Enabling SDDM..."
            sudo systemctl enable sddm
            print_success "SDDM enabled (active after reboot)"
        else
            print_warning "SDDM not enabled — login screen wallpaper will not be visible"
        fi
    fi

    print_success "SDDM configured"
}

# Setup Plymouth boot splash screen
setup_plymouth() {
    # Only relevant on Arch — Fedora ships Plymouth out of the box
    [ "$DISTRO" != "arch" ] && return

    echo ""
    if ! gum confirm "Set up Plymouth boot splash screen?"; then
        return
    fi

    print_header "Plymouth Setup"

    # Install plymouth
    print_info "Installing Plymouth..."
    install_packages plymouth || {
        print_error "Failed to install Plymouth"
        return 1
    }

    # Build theme list
    local themes=()
    while IFS= read -r t; do
        [ -n "$t" ] && themes+=("$t")
    done < <(plymouth-set-default-theme -l 2>/dev/null)

    if [ ${#themes[@]} -eq 0 ]; then
        themes=("spinner" "bgrt")
    fi

    # Let user pick a theme
    local theme
    theme=$(printf '%s\n' "${themes[@]}" | gum choose --header "Select Plymouth theme")

    if [ -z "$theme" ]; then
        print_warning "No theme selected, using default (spinner)"
        theme="spinner"
    fi

    print_info "Setting Plymouth theme to '$theme'..."

    # Set theme (the -R flag also rebuilds initramfs)
    sudo plymouth-set-default-theme -R "$theme"

    # --- Configure mkinitcpio: add 'plymouth' hook after 'udev' ---
    local mkinitcpio="/etc/mkinitcpio.conf"
    if [ -f "$mkinitcpio" ] && ! grep -qE '^HOOKS=.*\bplymouth\b' "$mkinitcpio"; then
        print_info "Adding plymouth hook to mkinitcpio..."
        sudo sed -i 's/\(HOOKS=.*\budev\b\)/\1 plymouth/' "$mkinitcpio"
        sudo mkinitcpio -P
    else
        print_info "Plymouth hook already present in mkinitcpio"
    fi

    # --- Configure GRUB: add 'quiet splash' to kernel command line ---
    local grub_default="/etc/default/grub"
    if [ -f "$grub_default" ]; then
        local current_cmdline
        current_cmdline=$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_default" | head -1 | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="//;s/"$//')

        local updated=false
        if ! echo "$current_cmdline" | grep -qw "quiet"; then
            current_cmdline="$current_cmdline quiet"
            updated=true
        fi
        if ! echo "$current_cmdline" | grep -qw "splash"; then
            current_cmdline="$current_cmdline splash"
            updated=true
        fi

        if [ "$updated" = true ]; then
            # Trim leading/trailing whitespace
            current_cmdline=$(echo "$current_cmdline" | sed 's/^ *//;s/ *$//')
            print_info "Updating GRUB command line: $current_cmdline"
            sudo sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"$current_cmdline\"/" "$grub_default"
            print_info "Regenerating GRUB config..."
            sudo grub-mkconfig -o /boot/grub/grub.cfg
        else
            print_info "GRUB already has 'quiet splash'"
        fi
    else
        print_warning "$grub_default not found — skipping GRUB configuration"
    fi

    PLYMOUTH_CONFIGURED=true
    print_success "Plymouth configured (theme: $theme)"
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
    local next_step=4
    
    # Add Hyprland step if running in Hyprland or if Hyprland was selected
    if [ -n "$HYPRLAND_INSTANCE_SIGNATURE" ] || [[ " ${SELECTED_GROUP_NAMES[*]} " =~ " hyprland " ]]; then
        steps+=("  $next_step. Run 'hyprctl reload' to reload Hyprland config")
        next_step=$((next_step + 1))
    fi

    if [[ " ${SELECTED_GROUP_NAMES[*]} " =~ " niri " ]]; then
        steps+=("  $next_step. Log out, choose Niri in your display manager, and log back in")
        next_step=$((next_step + 1))
    fi

    if [[ " ${SELECTED_GROUP_NAMES[*]} " =~ " ai " ]]; then
        steps+=("  $next_step. Press Mod+D to toggle dictation (hyprvoice)")
        next_step=$((next_step + 1))
    fi

    if [ "$PLYMOUTH_CONFIGURED" = true ]; then
        steps+=("  $next_step. Reboot to see the Plymouth boot splash")
        next_step=$((next_step + 1))
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
    # Initialize installer state
    SELECTED_GROUP_NAMES=()
    SERVICES_TO_ENABLE=()
    PLYMOUTH_CONFIGURED=false
    unset GROUP_PACKAGE_MODE GROUP_CUSTOM_PACKAGE_LIST
    declare -gA GROUP_PACKAGE_MODE=()
    declare -gA GROUP_CUSTOM_PACKAGE_LIST=()
    
    # Check for gum
    check_gum
    
    # Welcome and confirmation
    show_welcome
    confirm_distro
    
    # Select groups
    select_groups
    select_group_packages
    
    # Confirm and install
    confirm_installation
    
    # Run installation steps
    update_system
    install_base_packages
    install_group_packages
    install_common_tools
    setup_dotfiles
    enable_selected_services
    setup_sddm
    setup_plymouth
    setup_ssh
    setup_shell
    
    # Done!
    show_completion
}

# Run main
main "$@"
