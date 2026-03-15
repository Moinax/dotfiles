#!/bin/bash
# Main installer script with interactive prompts (curses tree selector + gum)
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
DISTRO_FAMILY=$(get_distro_family "$DISTRO")

# Source distro-specific functions (using family to allow distro variants)
if [ -f "$SCRIPT_DIR/distros/$DISTRO_FAMILY.sh" ]; then
    source "$SCRIPT_DIR/distros/$DISTRO_FAMILY.sh"
else
    print_error "Unsupported distribution: $DISTRO (family: $DISTRO_FAMILY)"
    print_info "Supported distributions: $(get_supported_distros)"
    exit 1
fi

# Installer state
SELECTED_GROUP_NAMES=()
SERVICES_TO_ENABLE=()
declare -A GROUP_PACKAGE_MODE=()
declare -A GROUP_CUSTOM_PACKAGE_LIST=()
HYPRVOICE_MODEL="small"
INSTALL_PURPOSE="desktop"

# Check if root filesystem is BTRFS
is_root_btrfs() {
    local fstype
    fstype=$(findmnt -n -o FSTYPE / 2>/dev/null)
    [ "$fstype" = "btrfs" ]
}

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

# Select setup purpose (desktop or terminal)
select_purpose() {
    echo ""
    gum style --foreground 212 --bold "What type of setup?"
    echo ""

    local choice
    choice=$(gum choose --cursor.foreground="212" \
        "🖥️  Desktop — full desktop environment with GUI apps" \
        "⌨️  Terminal — CLI tools only (headless/server)")

    case "$choice" in
        *Desktop*)
            INSTALL_PURPOSE="desktop"
            print_success "Setup type: Desktop"
            ;;
        *Terminal*)
            INSTALL_PURPOSE="terminal"
            print_success "Setup type: Terminal (CLI only)"
            ;;
        *)
            INSTALL_PURPOSE="desktop"
            print_info "Defaulting to Desktop setup"
            ;;
    esac
}

# Escape a string for safe inclusion inside a JSON string value.
# Handles backslash, double-quote, and control characters.
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

# Build JSON array of groups for tree_select.py
_build_tree_json() {
    local -A pkg_seen=()
    local first_group=true

    printf '['
    for group in "${SELECTED_GROUP_NAMES[@]}"; do
        local group_file="$DOTFILES_DIR/packages/groups/$group.yaml"
        [ -f "$group_file" ] || continue

        # Read group icon and display name
        local group_icon="" group_label=""
        if command_exists yq; then
            group_icon=$(yq -r '.icon // ""' "$group_file")
            group_label=$(yq -r '.name // ""' "$group_file")
        else
            group_icon=$(grep "^icon:" "$group_file" | sed 's/icon:[[:space:]]*//')
            group_label=$(grep "^name:" "$group_file" | sed 's/name:[[:space:]]*//')
        fi
        [ -z "$group_label" ] && group_label="$group"

        # Load descriptions
        local -A descs=()
        while IFS='=' read -r dkey dval; do
            [ -n "$dkey" ] && descs["$dkey"]="$dval"
        done < <(parse_descriptions "$group_file")

        # Build desktop_only exclusion set for terminal mode
        local -A desktop_only_pkgs=()
        if [ "$INSTALL_PURPOSE" = "terminal" ]; then
            while IFS= read -r do_pkg; do
                [ -n "$do_pkg" ] && desktop_only_pkgs["$do_pkg"]=1
            done < <(parse_desktop_only "$group_file")
        fi

        # Collect deduplicated packages
        local pkg_json_items=()
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            [ -n "${pkg_seen[$pkg]}" ] && continue
            # Skip desktop_only packages in terminal mode
            [ -n "${desktop_only_pkgs[$pkg]}" ] && continue
            pkg_seen["$pkg"]="$group"

            local desc="$(_json_escape "${descs[$pkg]:-}")"
            local name="$(_json_escape "$pkg")"
            pkg_json_items+=("{\"name\":\"$name\",\"desc\":\"$desc\"}")
        done < <(parse_packages "$group_file" "$DISTRO_FAMILY")

        # Emit group JSON object
        if [ "$first_group" = true ]; then
            first_group=false
        else
            printf ','
        fi

        local esc_id="$(_json_escape "$group")"
        local esc_name="$(_json_escape "$group_label")"
        local esc_icon="$(_json_escape "$group_icon")"

        printf '{"id":"%s","name":"%s","icon":"%s","packages":[' "$esc_id" "$esc_name" "$esc_icon"

        local first_pkg=true
        for pj in "${pkg_json_items[@]}"; do
            if [ "$first_pkg" = true ]; then
                first_pkg=false
            else
                printf ','
            fi
            printf '%s' "$pj"
        done
        printf ']}'
    done
    printf ']'
}

# Fallback: select packages using gum filter (flat list)
_select_packages_gum_fallback() {
    local -A pkg_seen=()
    local -A group_total=()
    local display_lines=()
    local preselected=()
    local -A line_to_pkg=()
    local -A line_to_group=()

    for group in "${SELECTED_GROUP_NAMES[@]}"; do
        local group_file="$DOTFILES_DIR/packages/groups/$group.yaml"
        [ -f "$group_file" ] || continue

        local group_icon="" group_label=""
        if command_exists yq; then
            group_icon=$(yq -r '.icon // ""' "$group_file")
            group_label=$(yq -r '.name // ""' "$group_file")
        else
            group_icon=$(grep "^icon:" "$group_file" | sed 's/icon:[[:space:]]*//')
            group_label=$(grep "^name:" "$group_file" | sed 's/name:[[:space:]]*//')
        fi
        [ -z "$group_label" ] && group_label="$group"

        local -A descs=()
        while IFS='=' read -r dkey dval; do
            [ -n "$dkey" ] && descs["$dkey"]="$dval"
        done < <(parse_descriptions "$group_file")

        # Build desktop_only exclusion set for terminal mode
        local -A desktop_only_pkgs=()
        if [ "$INSTALL_PURPOSE" = "terminal" ]; then
            while IFS= read -r do_pkg; do
                [ -n "$do_pkg" ] && desktop_only_pkgs["$do_pkg"]=1
            done < <(parse_desktop_only "$group_file")
        fi

        local header_line="$group_icon $group_label"
        display_lines+=("$header_line")

        local pkg_count=0
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            # Skip desktop_only packages in terminal mode
            [ -n "${desktop_only_pkgs[$pkg]}" ] && continue
            pkg_count=$((pkg_count + 1))
            [ -n "${pkg_seen[$pkg]}" ] && continue
            pkg_seen["$pkg"]="$group"

            local desc="${descs[$pkg]:-}"
            local display_line
            if [ -n "$desc" ]; then
                display_line="  $pkg: $desc"
            else
                display_line="  $pkg"
            fi
            display_lines+=("$display_line")
            preselected+=("$display_line")
            line_to_pkg["$display_line"]="$pkg"
            line_to_group["$display_line"]="$group"
        done < <(parse_packages "$group_file" "$DISTRO_FAMILY")
        group_total["$group"]=$pkg_count
    done

    if [ ${#display_lines[@]} -eq 0 ]; then
        return 1
    fi

    echo ""
    gum style --foreground 212 --bold "Select packages to install:"
    echo ""
    print_info "All packages are pre-selected. Deselect any you don't want."
    print_info "Type to fuzzy-search, Space to toggle, Enter to confirm."
    echo ""

    local filter_args=(--no-limit --height=20 --header "Packages"
        --indicator.foreground="212" --match.foreground="212")
    for line in "${preselected[@]}"; do
        filter_args+=(--selected "$line")
    done

    local filter_output
    filter_output=$(printf '%s\n' "${display_lines[@]}" | gum filter "${filter_args[@]}")

    local -A group_selected=()
    local -A group_sel_count=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local pkg="${line_to_pkg[$line]}"
        local grp="${line_to_group[$line]}"
        [ -z "$pkg" ] || [ -z "$grp" ] && continue
        if [ -z "${group_selected[$grp]}" ]; then
            group_selected["$grp"]="$pkg"
        else
            group_selected["$grp"]="${group_selected[$grp]}"$'\n'"$pkg"
        fi
        group_sel_count["$grp"]=$(( ${group_sel_count[$grp]:-0} + 1 ))
    done <<< "$filter_output"

    if [ -z "$filter_output" ]; then
        return 1
    fi

    for group in "${SELECTED_GROUP_NAMES[@]}"; do
        local total="${group_total[$group]:-0}"
        local selected="${group_sel_count[$group]:-0}"
        if [ "$selected" -eq 0 ]; then
            GROUP_PACKAGE_MODE["$group"]="skip"
        elif [ "$selected" -ge "$total" ]; then
            GROUP_PACKAGE_MODE["$group"]="all"
        else
            GROUP_PACKAGE_MODE["$group"]="custom"
            GROUP_CUSTOM_PACKAGE_LIST["$group"]="${group_selected[$group]}"
        fi
    done
    return 0
}

# Select packages across all groups using an interactive tree selector
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

    # Track total package counts per group (before dedup, for mode detection)
    local -A group_total=()
    for group in "${SELECTED_GROUP_NAMES[@]}"; do
        local group_file="$DOTFILES_DIR/packages/groups/$group.yaml"
        [ -f "$group_file" ] || continue
        local count=0
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && count=$((count + 1))
        done < <(parse_packages "$group_file" "$DISTRO_FAMILY")
        group_total["$group"]=$count
    done

    # Build JSON and run interactive tree selector
    local tree_json
    tree_json="$(_build_tree_json)"

    if [ -z "$tree_json" ] || [ "$tree_json" = "[]" ]; then
        print_warning "No $DISTRO packages found for the selected groups."
        for group in "${SELECTED_GROUP_NAMES[@]}"; do
            GROUP_PACKAGE_MODE["$group"]="skip"
        done
        return 0
    fi

    local tsv_output=""
    local select_rc=0

    while true; do
        if command_exists python3; then
            tsv_output=$(printf '%s' "$tree_json" | python3 "$SCRIPT_DIR/lib/tree_select.py") || select_rc=$?
        else
            # Fallback to gum filter if python3 unavailable
            print_warning "python3 not found, falling back to gum filter"
            if _select_packages_gum_fallback; then
                # Fallback already populated GROUP_PACKAGE_MODE/GROUP_CUSTOM_PACKAGE_LIST
                break
            else
                select_rc=1
            fi
        fi

        if [ "$select_rc" -eq 1 ]; then
            # User pressed Esc — confirm cancellation
            echo ""
            if gum confirm "Cancel installation?"; then
                print_info "Installation cancelled"
                exit 0
            fi
            # User chose not to cancel — re-run the selector
            select_rc=0
            continue
        fi

        break
    done

    # Parse TSV output into per-group selections
    local -A group_selected=()
    local -A group_sel_count=()

    while IFS=$'\t' read -r grp pkg; do
        [ -z "$grp" ] || [ -z "$pkg" ] && continue
        if [ -z "${group_selected[$grp]}" ]; then
            group_selected["$grp"]="$pkg"
        else
            group_selected["$grp"]="${group_selected[$grp]}"$'\n'"$pkg"
        fi
        group_sel_count["$grp"]=$(( ${group_sel_count[$grp]:-0} + 1 ))
    done <<< "$tsv_output"

    # Handle empty selection
    if [ -z "$tsv_output" ]; then
        print_warning "No packages selected — only dotfiles/services will be applied."
        for group in "${SELECTED_GROUP_NAMES[@]}"; do
            GROUP_PACKAGE_MODE["$group"]="skip"
        done
        return 0
    fi

    # Map selections back to per-group mode
    for group in "${SELECTED_GROUP_NAMES[@]}"; do
        local total="${group_total[$group]:-0}"
        local selected="${group_sel_count[$group]:-0}"

        if [ "$selected" -eq 0 ]; then
            GROUP_PACKAGE_MODE["$group"]="skip"
        elif [ "$selected" -ge "$total" ]; then
            GROUP_PACKAGE_MODE["$group"]="all"
        else
            GROUP_PACKAGE_MODE["$group"]="custom"
            GROUP_CUSTOM_PACKAGE_LIST["$group"]="${group_selected[$group]}"
        fi
    done

    # Prune groups where all packages were deselected
    local kept_groups=()
    for group in "${SELECTED_GROUP_NAMES[@]}"; do
        if [ "${GROUP_PACKAGE_MODE[$group]}" != "skip" ]; then
            kept_groups+=("$group")
        fi
    done
    SELECTED_GROUP_NAMES=("${kept_groups[@]}")
}

# Confirm installation
confirm_installation() {
    echo ""
    gum style --foreground 212 --bold "Installation Summary:"
    echo ""
    echo "  • Distribution: $DISTRO_NAME"
    echo "  • Setup type: $([ "$INSTALL_PURPOSE" = "desktop" ] && echo "Desktop" || echo "Terminal (CLI only)")"
    echo "  • Base packages: Yes"
    if [ ${#SELECTED_GROUP_NAMES[@]} -gt 0 ]; then
        echo "  • Groups:"
        for group in "${SELECTED_GROUP_NAMES[@]}"; do
            local mode="${GROUP_PACKAGE_MODE[$group]:-all}"
            local group_file="$DOTFILES_DIR/packages/groups/$group.yaml"
            local total=0
            while IFS= read -r pkg; do
                [ -n "$pkg" ] && total=$((total + 1))
            done < <(parse_packages "$group_file" "$DISTRO_FAMILY")

            case "$mode" in
                all)
                    echo "      $group: all $total packages"
                    ;;
                custom)
                    local selected=0
                    while IFS= read -r pkg; do
                        [ -n "$pkg" ] && selected=$((selected + 1))
                    done <<< "${GROUP_CUSTOM_PACKAGE_LIST[$group]}"
                    echo "      $group: $selected / $total packages"
                    ;;
                skip)
                    if [ "$total" -gt 0 ]; then
                        echo "      $group: skipped (dotfiles/services only)"
                    else
                        echo "      $group: dotfiles/services only"
                    fi
                    ;;
            esac
        done
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
    
    local base_file="$DOTFILES_DIR/packages/$DISTRO_FAMILY/base.yaml"
    
    if [ ! -f "$base_file" ]; then
        print_error "Base package file not found: $base_file"
        return 1
    fi
    
    # Install yq first for better YAML parsing
    install_yq
    
    # Enable COPR repositories first (Fedora family only)
    if [ "$DISTRO_FAMILY" = "fedora" ]; then
        print_info "Enabling COPR repositories..."
        local copr_repos=()
        while IFS= read -r repo; do
            [ -n "$repo" ] && copr_repos+=("$repo")
        done < <(yq -r '.packages.copr.repositories[]? // ""' "$base_file" 2>/dev/null | grep -v "^$")

        for repo in "${copr_repos[@]}"; do
            enable_copr "$repo" || true  # Continue even if COPR fails
        done
    fi

    # Enable PPA repositories first (Debian/Ubuntu family only)
    if [ "$DISTRO_FAMILY" = "debian" ]; then
        print_info "Enabling PPA repositories..."
        local ppa_repos=()
        while IFS= read -r repo; do
            [ -n "$repo" ] && ppa_repos+=("$repo")
        done < <(yq -r '.packages.ppa.repositories[]? // ""' "$base_file" 2>/dev/null | grep -v "^$")

        for repo in "${ppa_repos[@]}"; do
            enable_ppa "$repo" || true  # Continue even if PPA fails (e.g., pure Debian)
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

    # Parse and install desktop packages (only in desktop mode)
    if [ "$INSTALL_PURPOSE" = "desktop" ]; then
        packages=()
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && packages+=("$pkg")
        done < <(parse_packages "$base_file" "desktop")

        if [ ${#packages[@]} -gt 0 ]; then
            install_packages "${packages[@]}" || print_warning "Some desktop base packages failed to install"
        fi
    fi

    # Parse and install AUR packages (Arch family only)
    if [ "$DISTRO_FAMILY" = "arch" ]; then
        packages=()
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && packages+=("$pkg")
        done < <(parse_packages "$base_file" "aur")

        if [ ${#packages[@]} -gt 0 ]; then
            install_packages "${packages[@]}" || print_warning "Some AUR packages failed to install"
        fi
    fi

    # Install binary packages not available in apt (Debian/Ubuntu family only)
    if [ "$DISTRO_FAMILY" = "debian" ]; then
        install_eza || print_warning "Failed to install eza"
        install_lazygit || print_warning "Failed to install lazygit"
        install_starship || print_warning "Failed to install starship"
        install_fastfetch || print_warning "Failed to install fastfetch"
        install_yazi || print_warning "Failed to install yazi"
        post_install_bat_alias
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
        
        # Setup repos if needed (distro-family specific)
        case "$DISTRO_FAMILY" in
            fedora)
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
                ;;
            debian)
                # Enable any PPA repos defined in the group file
                local debian_ppas=()
                while IFS= read -r repo; do
                    [ -n "$repo" ] && debian_ppas+=("$repo")
                done < <(yq -r '.packages.debian_ppa[]? // ""' "$group_file" 2>/dev/null | grep -v "^$")

                for repo in "${debian_ppas[@]}"; do
                    enable_ppa "$repo" || true
                done

                # Run group-specific repo setup functions
                case "$group" in
                    hyprland) setup_hyprland_repos 2>/dev/null || true ;;
                    gaming) setup_gaming_repos 2>/dev/null || true ;;
                    multimedia) setup_multimedia_repos 2>/dev/null || true ;;
                    productivity) setup_productivity_repos 2>/dev/null || true ;;
                    development) setup_development_repos 2>/dev/null || true ;;
                esac
                ;;
        esac
        
        # Parse package candidates
        local all_packages=()
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && all_packages+=("$pkg")
        done < <(parse_packages "$group_file" "$DISTRO_FAMILY")

        # Filter out desktop_only packages in terminal mode
        if [ "$INSTALL_PURPOSE" = "terminal" ]; then
            local -A desktop_only_pkgs=()
            while IFS= read -r do_pkg; do
                [ -n "$do_pkg" ] && desktop_only_pkgs["$do_pkg"]=1
            done < <(parse_desktop_only "$group_file")

            if [ ${#desktop_only_pkgs[@]} -gt 0 ]; then
                local filtered_packages=()
                for pkg in "${all_packages[@]}"; do
                    [ -z "${desktop_only_pkgs[$pkg]}" ] && filtered_packages+=("$pkg")
                done
                all_packages=("${filtered_packages[@]}")
            fi
        fi

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

    # Install gh-dash (development group)
    if [[ " ${SELECTED_GROUP_NAMES[*]} " =~ " development " ]]; then
        if command_exists gh; then
            if ! gh extension list 2>/dev/null | grep -q "dlvhdr/gh-dash"; then
                print_info "Installing gh-dash extension..."
                gh extension install dlvhdr/gh-dash && print_success "gh-dash installed" || print_warning "Failed to install gh-dash"
            else
                print_info "gh-dash is already installed"
            fi
        else
            print_warning "gh CLI not found — skipping gh-dash extension"
        fi
    fi

    # Setup hyprvoice (AI group)
    if [[ " ${SELECTED_GROUP_NAMES[*]} " =~ " ai " ]]; then
        # Install hyprvoice binary (Fedora only — Arch uses AUR package)
        if [ "$DISTRO_FAMILY" = "fedora" ] && ! command_exists hyprvoice; then
            install_curl_tool "hyprvoice" \
                "curl -sL https://github.com/LeonardoTrapani/hyprvoice/releases/latest/download/hyprvoice-linux-x86_64 -o ~/.local/bin/hyprvoice && chmod +x ~/.local/bin/hyprvoice"
        elif command_exists hyprvoice; then
            print_info "hyprvoice is already installed"
        fi

        # Build whisper-cli from source (Fedora's whisper-cpp package ships only libraries)
        if [ "$DISTRO_FAMILY" = "fedora" ] && ! command_exists whisper-cli; then
            print_info "Building whisper-cli from source (not shipped by Fedora's whisper-cpp package)..."
            local whisper_tmp="/tmp/whisper.cpp"
            rm -rf "$whisper_tmp"
            if git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git "$whisper_tmp" 2>/dev/null; then
                if cmake -B "$whisper_tmp/build" "$whisper_tmp" -DWHISPER_SDL2=ON -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
                    && cmake --build "$whisper_tmp/build" --target whisper-cli -j"$(nproc)"; then
                    mkdir -p "$HOME/.local/bin"
                    cp "$whisper_tmp/build/bin/whisper-cli" "$HOME/.local/bin/whisper-cli"
                    chmod +x "$HOME/.local/bin/whisper-cli"
                    print_success "whisper-cli installed to ~/.local/bin/whisper-cli"
                else
                    print_error "Failed to build whisper-cli"
                fi
                rm -rf "$whisper_tmp"
            else
                print_error "Failed to clone whisper.cpp"
            fi
        elif command_exists whisper-cli; then
            print_info "whisper-cli is already installed"
        fi

        # Download whisper model for local transcription
        if command_exists hyprvoice; then
            local existing_model
            existing_model=$(hyprvoice model list 2>/dev/null | grep '\[x\]' | head -1 | awk '{print $2}')

            if [ -n "$existing_model" ]; then
                HYPRVOICE_MODEL="$existing_model"
                print_info "Whisper model '$existing_model' is already downloaded"
            else
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
        "dot_config/starship.toml"
        "dot_config/yazi"
        "completion-for-pnpm.bash"
    )

    # Add desktop-only base dotfiles
    if [ "$INSTALL_PURPOSE" = "desktop" ]; then
        dotfiles_to_install+=(
            "dot_config/kitty"
            "Wallpapers"
        )
    fi
    
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
    install_purpose = "$INSTALL_PURPOSE"
    dark_mode = "dark"
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

# Apply initial dark mode defaults (creates active theme files not tracked by chezmoi)
apply_dark_mode_defaults() {
    local state_file="$HOME/.local/share/dark-light-mode"
    local script="$HOME/.local/bin/apply-dark-mode.sh"

    if [ ! -x "$script" ]; then
        return 0
    fi

    # Active theme files generated by apply-dark-mode.sh (not tracked by chezmoi)
    local theme_files=(
        "$HOME/.config/kitty/current-theme.conf"
        "$HOME/.config/mako/config"
        "$HOME/.local/share/rofi/themes/moinax.rasi"
        "$HOME/.config/wlogout/style.css"
        "$HOME/.config/waybar/style.css"
    )

    # Re-run if state file is missing or any active theme file is missing
    local needs_apply=false
    if [ ! -f "$state_file" ]; then
        needs_apply=true
    else
        for f in "${theme_files[@]}"; do
            if [ ! -f "$f" ]; then
                needs_apply=true
                break
            fi
        done
    fi

    if [ "$needs_apply" = true ]; then
        local mode
        mode=$(cat "$state_file" 2>/dev/null || echo "dark")
        print_info "Applying $mode mode theme..."
        APPLY_DARK_MODE_NO_RESTART=1 "$script" "$mode"
        print_success "Theme applied ($mode mode)"
    else
        print_info "Dark/light mode already configured, skipping"
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

    # Set tailscale operator and authenticate if development is selected and tailscale is installed
    if [[ " ${SELECTED_GROUP_NAMES[*]} " =~ " development " ]] && command -v tailscale &>/dev/null; then
        print_info "Setting Tailscale operator to $USER"
        sudo tailscale set --operator="$USER"
        print_success "Tailscale operator set (no sudo needed for tailscale commands)"

        # Authenticate if not already logged in
        if ! tailscale status &>/dev/null; then
            print_info "Logging into Tailscale (a browser/URL will open for authentication)..."
            tailscale up
        else
            print_info "Tailscale is already authenticated"
        fi
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
    # Only relevant on Arch family — Fedora ships Plymouth out of the box
    [ "$DISTRO_FAMILY" != "arch" ] && return

    # Skip if Plymouth is already installed and configured
    if command_exists plymouth-set-default-theme \
        && grep -qE '^HOOKS=.*\bplymouth\b' /etc/mkinitcpio.conf 2>/dev/null; then
        print_info "Plymouth is already configured"
        PLYMOUTH_CONFIGURED=true
        return
    fi

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

# Setup BTRFS snapshots with Snapper (conditional on BTRFS + productivity group)
setup_btrfs_snapshots() {
    # Only run if productivity group was selected
    if ! [[ " ${SELECTED_GROUP_NAMES[*]} " =~ " productivity " ]]; then
        return 0
    fi

    # Check if root filesystem is BTRFS
    if ! is_root_btrfs; then
        print_info "Root filesystem is not BTRFS — skipping snapshot setup"
        return 0
    fi

    # Verify snapper is installed
    if ! command_exists snapper; then
        print_warning "snapper not found — skipping BTRFS snapshot setup"
        return 0
    fi

    echo ""
    print_info "BTRFS root detected with snapper installed"
    if ! gum confirm "Configure automatic BTRFS snapshots before package upgrades?"; then
        return 0
    fi

    print_info "Configuring BTRFS snapshots..."

    # Create snapper root config if it doesn't exist
    if ! sudo snapper list-configs 2>/dev/null | grep -q "^root"; then
        print_info "Creating snapper root config..."
        sudo snapper create-config / || {
            print_warning "Failed to create snapper root config — skipping snapshot setup"
            return 0
        }
    fi

    # Disable timeline snapshots (we only want pre-upgrade snapshots)
    sudo snapper -c root set-config "TIMELINE_CREATE=no" || {
        print_warning "Failed to configure snapper timeline settings"
    }

    # Debian: install APT hook for pre-upgrade snapshots
    if [ "$DISTRO_FAMILY" = "debian" ]; then
        local apt_hook="/etc/apt/apt.conf.d/80-snapper"
        if [ ! -f "$apt_hook" ]; then
            print_info "Installing APT snapper hook..."
            sudo tee "$apt_hook" > /dev/null << 'APTEOF'
DPkg::Pre-Invoke { "if command -v snapper >/dev/null 2>&1 && snapper list-configs 2>/dev/null | grep -q root; then snapper create --description 'Before APT upgrade' --cleanup-algorithm number; fi"; };
APTEOF
        fi
    fi

    # Debian: install grub-btrfs from source (not in apt repos)
    if [ "$DISTRO_FAMILY" = "debian" ] && ! command_exists grub-btrfsd; then
        print_info "Installing grub-btrfs from source..."
        local tmp_dir
        tmp_dir=$(mktemp -d)
        if git clone https://github.com/Antynea/grub-btrfs.git "$tmp_dir"; then
            (cd "$tmp_dir" && sudo make install) || {
                print_warning "Failed to install grub-btrfs from source"
            }
        else
            print_warning "Failed to clone grub-btrfs repository"
        fi
        rm -rf "$tmp_dir"
    fi

    # Enable grub-btrfsd service if available
    if systemctl list-unit-files grub-btrfsd.service &>/dev/null; then
        print_info "Enabling grub-btrfsd service..."
        sudo systemctl enable --now grub-btrfsd || {
            print_warning "Failed to enable grub-btrfsd service"
        }
    fi

    # Create initial snapshot
    sudo snapper create --description "Initial snapshot after dotfiles setup" || {
        print_warning "Failed to create initial snapshot"
    }

    BTRFS_SNAPSHOTS_CONFIGURED=true
    print_success "BTRFS snapshot setup complete"
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

    if [ "$BTRFS_SNAPSHOTS_CONFIGURED" = true ]; then
        steps+=("  $next_step. Run 'snapper list' to verify BTRFS snapshots are working")
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
    BTRFS_SNAPSHOTS_CONFIGURED=false
    unset GROUP_PACKAGE_MODE GROUP_CUSTOM_PACKAGE_LIST
    declare -gA GROUP_PACKAGE_MODE=()
    declare -gA GROUP_CUSTOM_PACKAGE_LIST=()
    
    # Check for gum
    check_gum
    
    # Welcome and confirmation
    show_welcome
    confirm_distro

    # Select setup purpose (desktop or terminal)
    select_purpose

    # Auto-populate groups based on purpose and go straight to package filter
    local groups_dir="$DOTFILES_DIR/packages/groups"
    shopt -s nullglob
    local group_files=("$groups_dir"/*.yaml)
    shopt -u nullglob
    IFS=$'\n' group_files=($(printf '%s\n' "${group_files[@]}" | sort))
    unset IFS
    for group_file in "${group_files[@]}"; do
        # Filter groups by environment when in terminal mode
        if [ "$INSTALL_PURPOSE" = "terminal" ]; then
            local env
            env=$(grep '^environment:' "$group_file" | awk '{print $2}')
            if [ "$env" != "both" ]; then
                continue
            fi
        fi
        SELECTED_GROUP_NAMES+=("$(basename "$group_file" .yaml)")
    done
    select_group_packages
    
    # Confirm and install
    confirm_installation
    
    # Run installation steps
    update_system
    install_base_packages
    install_group_packages
    install_common_tools
    setup_dotfiles
    if [ "$INSTALL_PURPOSE" = "desktop" ]; then
        apply_dark_mode_defaults
    fi
    enable_selected_services
    setup_btrfs_snapshots
    if [ "$INSTALL_PURPOSE" = "desktop" ]; then
        setup_sddm
        setup_plymouth
    fi
    setup_ssh
    setup_shell
    
    # Done!
    show_completion
}

# Run main
main "$@"
