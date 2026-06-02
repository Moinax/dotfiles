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

# Ensure ~/.local/bin is in PATH so we can detect tools installed there (chezmoi, claude, etc.)
export PATH="$HOME/.local/bin:$PATH"

# Installer state
SELECTED_GROUP_NAMES=()
SERVICES_TO_ENABLE=()
INSTALL_WARNINGS=()
declare -A GROUP_PACKAGE_MODE=()
declare -A GROUP_CUSTOM_PACKAGE_LIST=()
HYPRVOICE_MODEL="small"
HYPRVOICE_PROVIDER="whisper-cpp"
INSTALL_PURPOSE="desktop"

# Regenerate GRUB config (distro-aware: grub-mkconfig vs grub2-mkconfig)
# Patch a grub-btrfs config file to use Fedora's grub2 paths.
# $1: path to the config file (e.g. /etc/default/grub-btrfs/config or a clone's config)
_patch_grub_btrfs_fedora_paths() {
    local config="$1"
    local maybe_sudo=""
    # Use sudo only for system files, not temp clones
    [[ "$config" == /etc/* || "$config" == /boot/* ]] && maybe_sudo="sudo"
    $maybe_sudo sed -i \
        -e 's|^#\?\s*GRUB_BTRFS_GRUB_DIRNAME=.*|GRUB_BTRFS_GRUB_DIRNAME="/boot/grub2"|' \
        -e 's|^#\?\s*GRUB_BTRFS_MKCONFIG=.*|GRUB_BTRFS_MKCONFIG=/usr/sbin/grub2-mkconfig|' \
        -e 's|^#\?\s*GRUB_BTRFS_SCRIPT_CHECK=.*|GRUB_BTRFS_SCRIPT_CHECK=grub2-script-check|' \
        -e 's|^#\?\s*GRUB_BTRFS_MKCONFIG_LIB=.*|GRUB_BTRFS_MKCONFIG_LIB=/usr/share/grub/grub-mkconfig_lib|' \
        -e 's|^#\?\s*GRUB_BTRFS_GBTRFS_DIRNAME=.*|GRUB_BTRFS_GBTRFS_DIRNAME="/boot/grub2"|' \
        "$config"
}

regenerate_grub_config() {
    # Fedora: fix grub-btrfs config paths before regeneration
    # (41_snapshots-btrfs defaults to /boot/grub when GRUB_BTRFS_GRUB_DIRNAME is unset)
    if [ "$DISTRO_FAMILY" = "fedora" ] && [ -f /etc/default/grub-btrfs/config ]; then
        _patch_grub_btrfs_fedora_paths /etc/default/grub-btrfs/config
    fi

    print_info "Regenerating GRUB config..."
    if [ "$DISTRO_FAMILY" = "fedora" ]; then
        sudo grub2-mkconfig -o /boot/grub2/grub.cfg
    else
        sudo grub-mkconfig -o /boot/grub/grub.cfg
    fi
}

# Check if root filesystem is BTRFS
is_root_btrfs() {
    local fstype
    fstype=$(findmnt -n -o FSTYPE / 2>/dev/null)
    [ "$fstype" = "btrfs" ]
}

# Read a value from `snapper -c root get-config`.
# Tries without sudo first (works when ALLOW_USERS includes $USER), falls back to sudo.
snapper_root_config_value() {
    local key="$1"
    local line raw

    raw=$(snapper -c root --csvout get-config 2>/dev/null || sudo snapper -c root --csvout get-config 2>/dev/null) || return 1

    line=$(printf '%s\n' "$raw" | awk -F',' -v key="$key" '
        $1 == key {
            print $2
            exit
        }
    ')

    [ -n "$line" ] || return 1
    printf '%s\n' "$line"
}

# Return success when BTRFS snapshot setup is complete enough to skip rerunning it.
is_btrfs_snapshots_configured() {
    local timeline_value allow_users apt_hook

    command_exists snapper || return 1
    [ -f /etc/snapper/configs/root ] || return 1

    timeline_value=$(snapper_root_config_value "TIMELINE_CREATE") || return 1
    [ "$timeline_value" = "no" ] || return 1

    allow_users=$(snapper_root_config_value "ALLOW_USERS") || return 1
    if ! printf '%s\n' "$allow_users" | tr ',' ' ' | tr -s '[:space:]' '\n' | grep -Fxq "$USER"; then
        return 1
    fi

    if [ "$DISTRO_FAMILY" = "debian" ]; then
        apt_hook="/etc/apt/apt.conf.d/80-snapper"
        [ -f "$apt_hook" ] || return 1
    fi

    if systemctl list-unit-files grub-btrfsd.service &>/dev/null; then
        if ! systemctl is-enabled --quiet grub-btrfsd.service \
            && ! systemctl is-active --quiet grub-btrfsd.service; then
            return 1
        fi
        # Verify grub-btrfsd is watching /.snapshots (snapper), not --timeshift-auto
        if ! systemctl cat grub-btrfsd.service 2>/dev/null | grep -q 'ExecStart=.*/\.snapshots'; then
            return 1
        fi
    elif [[ "$DISTRO_FAMILY" =~ ^(debian|fedora)$ ]]; then
        # grub-btrfs not in repos for debian/fedora — needs source install
        command_exists grub-btrfsd || return 1
    fi

    return 0
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

        # Include custom_install entries (curl/script-installed tools)
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            [ -n "${pkg_seen[$pkg]}" ] && continue
            [ -n "${desktop_only_pkgs[$pkg]}" ] && continue
            pkg_seen["$pkg"]="$group"

            local desc="$(_json_escape "${descs[$pkg]:-}")"
            local name="$(_json_escape "$pkg")"
            pkg_json_items+=("{\"name\":\"$name\",\"desc\":\"$desc\"}")
        done < <(parse_custom_install_names "$group_file" "$DISTRO_FAMILY")

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
        # Combine distro packages and custom_install packages into one list
        local all_group_pkgs=()
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && all_group_pkgs+=("$pkg")
        done < <(parse_packages "$group_file" "$DISTRO_FAMILY")
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && all_group_pkgs+=("$pkg")
        done < <(parse_custom_install_names "$group_file" "$DISTRO_FAMILY")

        for pkg in "${all_group_pkgs[@]}"; do
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
        done
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
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && count=$((count + 1))
        done < <(parse_custom_install_names "$group_file" "$DISTRO_FAMILY")
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
            print_info "python3 not found, falling back to gum filter"
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
        print_info "No packages selected — only dotfiles/services will be applied."
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
        install_packages "${packages[@]}" || track_warning "Some base packages failed to install"
    fi

    # Parse and install desktop packages (only in desktop mode)
    if [ "$INSTALL_PURPOSE" = "desktop" ]; then
        packages=()
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && packages+=("$pkg")
        done < <(parse_packages "$base_file" "desktop")

        if [ ${#packages[@]} -gt 0 ]; then
            install_packages "${packages[@]}" || track_warning "Some desktop base packages failed to install"
        fi
    fi

    # Parse and install AUR packages (Arch family only)
    if [ "$DISTRO_FAMILY" = "arch" ]; then
        packages=()
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && packages+=("$pkg")
        done < <(parse_packages "$base_file" "aur")

        if [ ${#packages[@]} -gt 0 ]; then
            install_packages "${packages[@]}" || track_warning "Some AUR packages failed to install"
        fi
    fi

    # Parse and install desktop-only AUR packages (Arch family only)
    if [ "$DISTRO_FAMILY" = "arch" ] && [ "$INSTALL_PURPOSE" = "desktop" ]; then
        packages=()
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && packages+=("$pkg")
        done < <(parse_packages "$base_file" "desktop_aur")

        if [ ${#packages[@]} -gt 0 ]; then
            install_packages "${packages[@]}" || track_warning "Some desktop AUR packages failed to install"
        fi
    fi

    # Install desktop-only AppImage support via distro-specific hook
    if [ "$INSTALL_PURPOSE" = "desktop" ] && declare -F install_appimage_support >/dev/null; then
        install_appimage_support || track_warning "Failed to install AppImage support"
    fi

    # Install binary packages not available in apt (Debian/Ubuntu family only)
    if [ "$DISTRO_FAMILY" = "debian" ]; then
        install_lazygit || track_warning "Failed to install lazygit"
        install_starship || track_warning "Failed to install starship"
        install_fastfetch || track_warning "Failed to install fastfetch"
        install_yazi || track_warning "Failed to install yazi"
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
        
        setup_group_repos "$group_file" "$group"
        
        # Parse package candidates (distro packages + custom_install)
        local all_packages=()
        local -A custom_install_names=()
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && all_packages+=("$pkg")
        done < <(parse_packages "$group_file" "$DISTRO_FAMILY")
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && all_packages+=("$pkg") && custom_install_names["$pkg"]=1
        done < <(parse_custom_install_names "$group_file" "$DISTRO_FAMILY")

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
        
        # Separate custom_install packages from distro packages
        local distro_packages=()
        local custom_packages=()
        for pkg in "${packages[@]}"; do
            if [ -n "${custom_install_names[$pkg]}" ]; then
                custom_packages+=("$pkg")
            else
                distro_packages+=("$pkg")
            fi
        done

        if [ ${#distro_packages[@]} -gt 0 ]; then
            install_packages "${distro_packages[@]}" || track_warning "Some packages from $group failed to install"
        fi

        # Install custom_install packages via their own commands
        for pkg in "${custom_packages[@]}"; do
            local check_cmd
            check_cmd=$(parse_custom_install_check "$group_file" "$pkg")
            local install_cmd
            install_cmd=$(parse_custom_install_cmd "$group_file" "$pkg")
            local requires_cmd
            requires_cmd=$(parse_custom_install_requires "$group_file" "$pkg")

            # Check if already installed
            local already_installed=false
            if [ -n "$check_cmd" ]; then
                if command_exists "$check_cmd" 2>/dev/null || eval "$check_cmd" 2>/dev/null; then
                    already_installed=true
                fi
            fi

            if $already_installed; then
                print_info "$pkg is already installed"
                continue
            fi

            # Install system prerequisites declared via requires_packages
            # before running the custom install command.
            local -a require_deps=()
            while IFS= read -r dep; do
                [ -n "$dep" ] && require_deps+=("$dep")
            done < <(parse_custom_install_requires_packages "$group_file" "$pkg")

            if [ ${#require_deps[@]} -gt 0 ]; then
                print_info "Installing prerequisites for $pkg (${require_deps[*]})"
                install_packages "${require_deps[@]}" \
                    || track_warning "Failed to install prerequisites for $pkg"
                hash -r 2>/dev/null || true
            fi

            # Skip if a hard-required command is still missing
            if [ -n "$requires_cmd" ] && ! command_exists "$requires_cmd"; then
                track_warning "$requires_cmd still unavailable — skipping $pkg"
                continue
            fi

            if [ -n "$install_cmd" ]; then
                install_curl_tool "$pkg" "$install_cmd" || track_warning "Failed to install $pkg"
            fi
        done

        if [ ${#distro_packages[@]} -eq 0 ] && [ ${#custom_packages[@]} -eq 0 ] && [ "$package_mode" != "skip" ]; then
            track_warning "No packages resolved for group $group"
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

    # Install Nerd Font for any local setup so Starship glyphs render in desktop and terminal modes.
    if command_exists fc-list && fc-list | grep -qi "FiraCode Nerd Font"; then
        print_info "FiraCode Nerd Font is already installed"
    elif ! command_exists unzip; then
        track_warning "Skipping FiraCode Nerd Font install: 'unzip' is not installed"
    else
        print_info "Installing FiraCode Nerd Font..."
        mkdir -p "$HOME/.local/share/fonts/FiraCodeNF"
        if curl -sL https://github.com/ryanoasis/nerd-fonts/releases/latest/download/FiraCode.zip -o /tmp/FiraCode.zip \
            && unzip -o /tmp/FiraCode.zip -d "$HOME/.local/share/fonts/FiraCodeNF" >/dev/null; then
            rm -f /tmp/FiraCode.zip
            if command_exists fc-cache; then
                if fc-cache -fv >/dev/null; then
                    print_success "FiraCode Nerd Font installed"
                else
                    track_warning "FiraCode Nerd Font files installed, but font cache refresh failed"
                fi
            else
                track_warning "FiraCode Nerd Font files installed, but 'fc-cache' is not available"
            fi
        else
            track_warning "Failed to install FiraCode Nerd Font"
            rm -f /tmp/FiraCode.zip
        fi
    fi
    
    # Install zoxide
    if ! command_exists zoxide; then
        install_curl_tool "zoxide" \
            "curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh"
    else
        print_info "zoxide is already installed"
    fi
    
    # Install fnm
    if ! command_exists fnm; then
        install_curl_tool "fnm" "curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell"
        # Source fnm for this session
        eval "$(fnm env --use-on-cd --shell bash)"

        # Install Node.js LTS and global packages
        if command_exists fnm; then
            print_info "Installing Node.js LTS via fnm..."
            fnm install --lts || track_warning "Failed to install Node.js LTS"
            fnm default lts-latest
            print_info "Installing global npm packages..."
            npm install -g yarn@1 pnpm || track_warning "Failed to install global npm packages"
        fi
    else
        print_info "fnm is already installed"
    fi
    
    # Tools below are packaged for Arch; install from upstream on other distros.
    if [ "$DISTRO_FAMILY" != "arch" ]; then
        if ! command_exists eza; then
            local eza_arch
            case "$(uname -m)" in
                x86_64)  eza_arch="x86_64" ;;
                aarch64) eza_arch="aarch64" ;;
                armv7l)  eza_arch="armv7" ;;
                *)       eza_arch="$(uname -m)" ;;
            esac
            install_curl_tool "eza" \
                "curl -fsSL https://github.com/eza-community/eza/releases/latest/download/eza_${eza_arch}-unknown-linux-gnu.tar.gz | sudo tar xz -C /usr/local/bin && sudo chmod +x /usr/local/bin/eza"
        else
            print_info "eza is already installed"
        fi

        if ! command_exists lazydocker; then
            install_curl_tool "lazydocker" \
                "curl -fsSL https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh | bash"
        else
            print_info "lazydocker is already installed"
        fi

        if ! command_exists tv; then
            install_curl_tool "television" \
                "curl -fsSL https://alexpasmantier.github.io/television/install.sh | bash"
        else
            print_info "television is already installed"
        fi
    fi

    # Install TPM (Tmux Plugin Manager)
    if [ ! -d "$HOME/.tmux/plugins/tpm" ]; then
        install_git_repo "TPM" "https://github.com/tmux-plugins/tpm" "$HOME/.tmux/plugins/tpm"
        TMUX_PLUGINS_INSTALLED=true
        print_info "Run tmux and press Ctrl+b I to install plugins"
    else
        print_info "TPM is already installed"
    fi

    # Install rofi themes when a Wayland compositor group is selected
    if group_selected hyprland || group_selected niri; then
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
            track_warning "Failed to install Rofi themes"
        fi
    fi

    # Setup hyprvoice (AI group)
    if group_selected ai; then
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

        # Configure hyprvoice transcription provider and model
        if command_exists hyprvoice; then
            local existing_provider="" existing_model_cfg=""
            if command_exists chezmoi; then
                local chezmoi_json
                chezmoi_json=$(chezmoi data --format json 2>/dev/null) || true
                existing_provider=$(grep -m1 -oP '"hyprvoice_provider"\s*:\s*"\K[^"]+' <<< "$chezmoi_json" || true)
                existing_model_cfg=$(grep -m1 -oP '"hyprvoice_model"\s*:\s*"\K[^"]+' <<< "$chezmoi_json" || true)
            fi

            if [ -n "$existing_provider" ]; then
                HYPRVOICE_PROVIDER="$existing_provider"
                [ -n "$existing_model_cfg" ] && HYPRVOICE_MODEL="$existing_model_cfg"
                print_info "Hyprvoice already configured (provider=$HYPRVOICE_PROVIDER, model=$HYPRVOICE_MODEL)"
            else
                # First-time setup: choose provider
                local provider_choice
                provider_choice=$(printf '%s\n' "whisper-cpp (local)" "groq (cloud, free tier)" | \
                    gum choose --cursor.foreground="212" \
                    --header "Select transcription provider for dictation:") || provider_choice="whisper-cpp (local)"
                HYPRVOICE_PROVIDER="${provider_choice%% (*}"

                if [ "$HYPRVOICE_PROVIDER" = "whisper-cpp" ]; then
                    # Local provider: select and download a whisper model
                    local models=()
                    while IFS= read -r line; do
                        if [[ "$line" =~ ^[[:space:]]*\[.\][[:space:]]+(.+)$ ]]; then
                            models+=("${BASH_REMATCH[1]}")
                        fi
                    done <<< "$(hyprvoice model list 2>/dev/null)"

                    if [ ${#models[@]} -gt 0 ]; then
                        models+=("Skip — download later")
                        HYPRVOICE_MODEL=$(printf '%s\n' "${models[@]}" | \
                            gum choose --header "Select a whisper model for dictation:") || HYPRVOICE_MODEL="Skip"
                        HYPRVOICE_MODEL="${HYPRVOICE_MODEL%% *}"
                    else
                        track_warning "Could not fetch model list from hyprvoice"
                        HYPRVOICE_MODEL="small"
                    fi

                    if [ "$HYPRVOICE_MODEL" != "Skip" ]; then
                        print_info "Downloading whisper model: $HYPRVOICE_MODEL"
                        if hyprvoice model download "$HYPRVOICE_MODEL"; then
                            print_success "Whisper model '$HYPRVOICE_MODEL' downloaded"
                        else
                            print_warning "Failed to download model — run 'hyprvoice model download $HYPRVOICE_MODEL' later"
                            HYPRVOICE_MODEL="small"
                        fi
                    else
                        HYPRVOICE_MODEL="small"
                    fi
                elif [ "$HYPRVOICE_PROVIDER" = "groq" ]; then
                    local groq_choice
                    groq_choice=$(printf '%s\n' "${GROQ_WHISPER_MODELS[@]}" | gum choose --cursor.foreground="212" \
                        --header "Select Groq model:") || groq_choice="${GROQ_WHISPER_MODELS[0]}"
                    HYPRVOICE_MODEL="${groq_choice%% *}"

                    if ! setup_groq_api_key; then
                        track_warning "No Groq API key provided — set GROQ_API_KEY later"
                    fi
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
        "$HOME/.config/swaync"
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
        print_info "Running inside Hyprland session"
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
    
    print_info "Installing ${#dotfiles_to_install[@]} dotfiles..."
    
    # Create chezmoi config with selected options
    local chezmoi_config="$HOME/.config/chezmoi/chezmoi.toml"
    mkdir -p "$(dirname "$chezmoi_config")"
    
    local source_dir="$DOTFILES_DIR/home"

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

    # vibewatch: on by default when the AI group is selected
    local install_vibewatch="$install_ai"
    # If the user customised the AI group's package list, check whether vibewatch was kept
    if [ "${GROUP_PACKAGE_MODE[ai]:-all}" = "custom" ]; then
        case " ${GROUP_CUSTOM_PACKAGE_LIST[ai]:-} " in
            *" vibewatch "*) install_vibewatch="true" ;;
            *) install_vibewatch="false" ;;
        esac
    fi
    
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
    install_vibewatch = $install_vibewatch
    has_nvidia = $HAS_NVIDIA
    hyprvoice_model = "$HYPRVOICE_MODEL"
    hyprvoice_provider = "$HYPRVOICE_PROVIDER"
    install_purpose = "$INSTALL_PURPOSE"
    dark_mode = "dark"
EOF
    
    print_info "Chezmoi config created at $chezmoi_config"
    print_info "Applying dotfiles from $source_dir..."

    # --force: overwrite files already on disk (e.g. rofi themes).
    if chezmoi apply --force; then
        print_success "Dotfiles applied successfully"
    else
        print_warning "Chezmoi completed with some warnings"
    fi
}

# Migrate from old notification daemons (mako/dunst) to swaync
migrate_notification_daemon() {
    if ! group_selected hyprland && ! group_selected niri; then
        return 0
    fi

    local old_daemons=()
    local old_packages=()

    # Check for running old daemons
    if pgrep -x mako &>/dev/null; then
        old_daemons+=("mako")
    fi
    if pgrep -x dunst &>/dev/null; then
        old_daemons+=("dunst")
    fi

    # Check for installed old packages
    for pkg in mako dunst; do
        if is_package_installed "$pkg" 2>/dev/null; then
            old_packages+=("$pkg")
        fi
    done
    # Debian/Ubuntu: dunst is the apt package (mako is not in apt)
    if [ "$DISTRO_FAMILY" = "debian" ]; then
        old_packages=()
        if is_package_installed dunst 2>/dev/null; then
            old_packages+=("dunst")
        fi
    fi

    if [ ${#old_daemons[@]} -eq 0 ] && [ ${#old_packages[@]} -eq 0 ]; then
        return 0
    fi

    print_info "Migrating notification daemon to SwayNC..."

    # Kill old daemons
    for daemon in "${old_daemons[@]}"; do
        print_info "Stopping $daemon..."
        killall "$daemon" 2>/dev/null || true
    done

    # Remove old packages
    if [ ${#old_packages[@]} -gt 0 ]; then
        print_info "Removing old notification packages: ${old_packages[*]}"
        remove_packages "${old_packages[@]}" || true
    fi

    # Start swaync if not running and we're in a desktop session
    if command -v swaync &>/dev/null && ! pgrep -x swaync &>/dev/null; then
        if [ -n "$WAYLAND_DISPLAY" ] || [ -n "$HYPRLAND_INSTANCE_SIGNATURE" ]; then
            print_info "Starting swaync..."
            swaync &>/dev/null &
            disown
        fi
    fi

    print_success "Notification daemon migrated to SwayNC"
}

# One-shot migration: switch from a distro-packaged Dropbox to the official
# dist tarball at ~/.dropbox-dist/ used by our chezmoi-managed dropbox.service.
# Dropbox's in-app auto-updater downloads newer dist binaries to ~/.dropbox-dist/
# and SIGKILLs the running daemon to swap them in — that fights any distro
# package and produces a restart loop. Idempotent: silently returns when there
# is nothing left to clean up.
migrate_dropbox_to_dist() {
    if ! [[ " ${SELECTED_GROUP_NAMES[*]} " =~ " productivity " ]]; then
        return 0
    fi

    local did_something=false

    if is_package_installed dropbox 2>/dev/null; then
        print_info "Removing distro dropbox package (superseded by ~/.dropbox-dist/)..."
        # Free the binary before the package manager yanks it — otherwise the
        # SIGKILL-on-update loop keeps respawning during pacman/dnf/apt removal.
        systemctl --user stop dropbox.service 2>/dev/null || true
        pkill -9 -f "/opt/dropbox"  2>/dev/null || true
        pkill -9 -f "dropbox-lnx"   2>/dev/null || true
        remove_packages dropbox || track_warning "Failed to remove dropbox package"
        did_something=true
    fi

    # Arch ships dropbox in main repos so there's no repo file to clean
    case "$DISTRO_FAMILY" in
        fedora)
            if [ -f /etc/yum.repos.d/dropbox.repo ]; then
                print_info "Removing leftover Dropbox dnf repo..."
                sudo rm -f /etc/yum.repos.d/dropbox.repo
                did_something=true
            fi
            ;;
        debian)
            if [ -f /etc/apt/sources.list.d/dropbox.list ] \
                || [ -f /etc/apt/keyrings/dropbox.gpg ]; then
                print_info "Removing leftover Dropbox apt repo..."
                sudo rm -f /etc/apt/sources.list.d/dropbox.list \
                           /etc/apt/keyrings/dropbox.gpg
                sudo apt-get update -qq || true
                did_something=true
            fi
            ;;
    esac

    if $did_something; then
        systemctl --user daemon-reload      2>/dev/null || true
        systemctl --user reset-failed dropbox.service 2>/dev/null || true
        if [ -n "$WAYLAND_DISPLAY" ] || [ -n "$HYPRLAND_INSTANCE_SIGNATURE" ]; then
            systemctl --user start dropbox.service 2>/dev/null || true
        fi
        print_success "Dropbox migrated to ~/.dropbox-dist/"
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
        "$HOME/.config/swaync/style.css"
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
        APPLY_DARK_MODE_NO_RESTART=1 "$script" "$mode" > /dev/null
        print_success "Theme applied ($mode mode)"
    else
        print_info "Dark/light mode already configured, skipping"
    fi
}

# Remove legacy NVIDIA systemd suspend services that conflict with kernel suspend notifiers (driver 595+).
# See the version-dependent suspend comment in setup_nvidia() for why these must be disabled.
# Idempotent: safe to call even when the services were never installed.
cleanup_legacy_nvidia_suspend_services() {
    # Disable the NVIDIA oneshot services (do NOT use --now; they are oneshot/not running)
    # Only disable, do NOT delete — these unit files are owned by the NVIDIA driver package
    for svc in nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service; do
        if systemctl is-enabled "$svc" &>/dev/null; then
            print_info "Disabling legacy service: $svc (kernel notifiers replace it)"
            sudo systemctl disable "$svc" 2>/dev/null || true
        fi
    done

    # Disable and remove installer-created compositor STOP/CONT services
    local needs_reload=false
    for prefix in hyprland niri; do
        for suffix in suspend resume; do
            local svc="${prefix}-${suffix}.service"
            local unit_file="/etc/systemd/system/${svc}"
            if systemctl is-enabled "$svc" &>/dev/null; then
                print_info "Disabling legacy service: $svc"
                sudo systemctl disable "$svc" 2>/dev/null || true
            fi
            if [ -f "$unit_file" ]; then
                print_info "Removing legacy unit file: $unit_file"
                sudo rm -f "$unit_file"
                needs_reload=true
            fi
        done
    done

    if [ "$needs_reload" = true ]; then
        sudo systemctl daemon-reload
    fi
    print_success "Legacy NVIDIA suspend services cleaned up"
}

# Install NVIDIA driver packages (Arch: prebuilt open modules for mainline + LTS)
# Uses prebuilt (non-DKMS) modules for fast upgrades, plus linux-lts as a fallback
# kernel with its matching nvidia-open-lts module package.
_install_nvidia_drivers_arch() {
    local gaming_selected="$1"
    local pkgs=(linux-lts nvidia-open nvidia-open-lts nvidia-utils nvidia-settings)

    if [ "$gaming_selected" = "true" ]; then
        pkgs+=(lib32-nvidia-utils)
    fi

    print_info "Installing NVIDIA prebuilt driver packages (mainline + LTS): ${pkgs[*]}"
    install_packages "${pkgs[@]}" || track_warning "Some NVIDIA driver packages failed to install"
}

# Install NVIDIA driver packages (Fedora: akmod via RPM Fusion)
_install_nvidia_drivers_fedora() {
    enable_rpmfusion
    local pkgs=(akmod-nvidia nvidia-vaapi-driver)
    print_info "Installing NVIDIA driver packages: ${pkgs[*]}"
    install_packages "${pkgs[@]}" || track_warning "Some NVIDIA driver packages failed to install"
}

# Install NVIDIA driver packages (Debian/Ubuntu)
_install_nvidia_drivers_debian() {
    # Enable non-free/restricted repos needed for NVIDIA drivers
    case "$DISTRO" in
        ubuntu|pop|linuxmint|elementary|neon|zorin)
            if command_exists add-apt-repository; then
                sudo add-apt-repository -y restricted 2>/dev/null || true
                sudo apt update
            fi
            ;;
        *)
            if ! grep -rq 'non-free' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
                print_info "Enabling contrib and non-free repositories..."
                if command_exists add-apt-repository; then
                    sudo add-apt-repository -y contrib 2>/dev/null || true
                    sudo add-apt-repository -y non-free 2>/dev/null || true
                else
                    sudo sed -i 's/^\(deb.*main\)$/\1 contrib non-free non-free-firmware/' /etc/apt/sources.list
                fi
                sudo apt update
            fi
            ;;
    esac

    # Install drivers
    case "$DISTRO" in
        ubuntu|pop|linuxmint|elementary|neon|zorin)
            print_info "Installing NVIDIA drivers via ubuntu-drivers..."
            install_packages ubuntu-drivers-common
            sudo ubuntu-drivers autoinstall || track_warning "ubuntu-drivers autoinstall failed"
            ;;
        *)
            print_info "Installing NVIDIA driver packages for Debian..."
            install_packages nvidia-driver || track_warning "nvidia-driver package failed to install"
            ;;
    esac
}

# Install NVIDIA driver packages per distro (called before setup_nvidia)
install_nvidia_drivers() {
    if [ "$HAS_NVIDIA" != "true" ] || [ "$INSTALL_PURPOSE" != "desktop" ]; then
        return 0
    fi

    print_header "NVIDIA Driver Installation"

    # Skip if drivers are already installed (covers both loaded and freshly-installed-pre-reboot)
    if get_nvidia_driver_version &>/dev/null; then
        print_info "NVIDIA drivers already installed — skipping driver installation"
        return 0
    fi

    local gaming_selected=false
    if group_selected gaming; then
        gaming_selected=true
    fi

    case "$DISTRO_FAMILY" in
        arch)
            _install_nvidia_drivers_arch "$gaming_selected"
            ;;
        fedora)
            _install_nvidia_drivers_fedora
            ;;
        debian)
            _install_nvidia_drivers_debian
            ;;
        *)
            print_warning "NVIDIA driver auto-install not supported on $DISTRO_FAMILY — install manually"
            return 0
            ;;
    esac

    print_success "NVIDIA driver packages installed"
    print_info "A reboot may be required before drivers are fully active"
}

# Setup NVIDIA GPU suspend/resume services
setup_nvidia() {
    if [ "$HAS_NVIDIA" != "true" ]; then
        return 0
    fi

    print_header "NVIDIA GPU Setup"

    # Check if NVIDIA driver services are installed
    if ! has_nvidia_services; then
        print_warning "NVIDIA GPU detected but driver services not found (reboot may be required)"
        print_info "Re-run setup after reboot to configure suspend/resume services"
        return 0
    fi

    # Detect driver version for version-specific suspend behavior
    local nvidia_major
    nvidia_major=$(get_nvidia_driver_version) || nvidia_major="unknown"
    print_info "NVIDIA driver version detected: ${nvidia_major}"

    # NVIDIA's kernel suspend notifier path is not reliable on this desktop:
    # logs showed hard resets after "PM: suspend entry (deep)" when the legacy
    # services were removed, while the service-based path resumed correctly.
    # Keep the explicit systemd suspend/resume path even on driver 595+.
    print_info "Using NVIDIA systemd suspend/resume services"

    # Enable NVIDIA suspend/resume/hibernate services for GPU memory preservation.
    # Use enable without --now: these are oneshot services meant to run only during actual suspend/resume.
    for svc in nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service; do
        if systemctl is-enabled "$svc" &>/dev/null; then
            print_info "Service $svc is already enabled"
        else
            print_info "Enabling service: $svc"
            if sudo systemctl enable "$svc"; then
                print_success "Service $svc enabled"
            else
                print_warning "Failed to enable service $svc"
            fi
        fi
    done

    # Install compositor STOP/CONT services to prevent GPU/compositor deadlocks during suspend.
    if group_selected hyprland; then
        install_compositor_suspend_services "Hyprland" "hyprland"
    fi
    if group_selected niri; then
        install_compositor_suspend_services "niri" "niri"
    fi

    # --- Common configuration (required regardless of driver version) ---

    # Configure modprobe for NVIDIA suspend/resume.
    local modprobe_conf="/etc/modprobe.d/nvidia.conf"
    local nvidia_modprobe_options="NVreg_PreserveVideoMemoryAllocations=1"
    local modprobe_changed=false

    if ! grep -qs '^options[[:space:]]\+nvidia[[:space:]]' "$modprobe_conf"; then
        print_info "Configuring NVIDIA modprobe options..."
        printf '%s\n' "options nvidia $nvidia_modprobe_options" | sudo tee -a "$modprobe_conf" > /dev/null
        modprobe_changed=true
        print_success "NVIDIA modprobe config written to $modprobe_conf"
    else
        local missing_options=()
        for option in $nvidia_modprobe_options; do
            if ! grep -rqs "$option" /etc/modprobe.d/; then
                missing_options+=("$option")
            fi
        done

        if [ ${#missing_options[@]} -gt 0 ]; then
            print_info "Adding missing NVIDIA modprobe options: ${missing_options[*]}"
            local escaped_options
            escaped_options=$(printf ' %s' "${missing_options[@]}")
            sudo sed -i "/^options[[:space:]]\\+nvidia[[:space:]]/s/$/${escaped_options}/" "$modprobe_conf"
            modprobe_changed=true
            print_success "NVIDIA modprobe options updated in $modprobe_conf"
        else
            print_success "NVIDIA modprobe options already configured"
        fi
    fi
    if grep -qs 'NVreg_UseKernelSuspendNotifiers=0' "$modprobe_conf"; then
        print_info "Removing local NVIDIA kernel suspend notifier override (package default applies)"
        sudo sed -i 's/[[:space:]]*NVreg_UseKernelSuspendNotifiers=0//g' "$modprobe_conf"
        modprobe_changed=true
        print_success "Local NVIDIA kernel suspend notifier override removed from $modprobe_conf"
    fi
    if ! grep -rqs '^options[[:space:]]\+nvidia-drm.*modeset=1' /etc/modprobe.d/; then
        echo "options nvidia-drm modeset=1" | sudo tee -a "$modprobe_conf" > /dev/null
        modprobe_changed=true
    fi
    if ! grep -rqs '^options[[:space:]]\+nvidia-drm.*fbdev=1' /etc/modprobe.d/; then
        echo "options nvidia-drm fbdev=1" | sudo tee -a "$modprobe_conf" > /dev/null
        modprobe_changed=true
    fi

    # Disable vblank semaphore control to prevent GPU-accelerated app hangs after suspend.
    # Driver 595 no longer accepts this parameter, so remove stale copies on newer branches.
    if [ "$nvidia_major" != "unknown" ] && [ "$nvidia_major" -ge 595 ] 2>/dev/null; then
        if grep -qs 'vblank_sem_control=0' "$modprobe_conf"; then
            print_info "Removing obsolete NVIDIA vblank_sem_control option"
            sudo sed -i '/vblank_sem_control=0/d' "$modprobe_conf"
            modprobe_changed=true
            print_success "Obsolete NVIDIA vblank_sem_control option removed from $modprobe_conf"
        fi
    elif ! grep -rqs 'vblank_sem_control=0' /etc/modprobe.d/; then
        print_info "Adding vblank_sem_control=0 to prevent post-suspend rendering hangs..."
        echo "options nvidia_modeset vblank_sem_control=0" | sudo tee -a "$modprobe_conf" > /dev/null
        modprobe_changed=true
        print_success "vblank_sem_control=0 added to $modprobe_conf"
    fi

    # Configure GRUB kernel parameters for NVIDIA + proper suspend
    configure_nvidia_kernel_params

    # Blacklist spd5118 DDR5 temp sensor — causes cascading resume failures.
    # The module enters a broken state after the first successful resume (error -6 / ENXIO),
    # then poisons subsequent resume cycles causing NVIDIA GSP heartbeat timeouts (no display).
    # First resume works, second resume fails. Do NOT remove this blacklist.
    if ! grep -rqs 'blacklist spd5118' /etc/modprobe.d/; then
        print_info "Blacklisting spd5118 module (DDR5 temp sensor — causes S3 resume failures)..."
        echo "blacklist spd5118" | sudo tee /etc/modprobe.d/blacklist-spd5118.conf > /dev/null
        modprobe_changed=true
        print_success "spd5118 module blacklisted"
    else
        print_success "spd5118 module already blacklisted"
    fi

    if [ "$modprobe_changed" = true ] && command -v mkinitcpio &>/dev/null; then
        print_info "Rebuilding initramfs so early-loaded NVIDIA modules use updated modprobe options..."
        if sudo mkinitcpio -P; then
            print_success "Initramfs rebuilt"
        else
            print_warning "Failed to rebuild initramfs; reboot may still use stale NVIDIA options"
        fi
    fi

    print_success "NVIDIA GPU setup complete"
}

# Configure kernel parameters in GRUB for NVIDIA suspend/resume support
# Ensures: nvidia-drm.modeset=1, nvidia-drm.fbdev=1,
#          nvidia.NVreg_PreserveVideoMemoryAllocations=1, mem_sleep_default=deep
# Idempotent: only modifies GRUB and regenerates config when changes are needed
configure_nvidia_kernel_params() {
    local grub_default="/etc/default/grub"
    [ -f "$grub_default" ] || return 0

    local current_cmdline
    current_cmdline=$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_default" \
        | head -1 | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="//;s/"$//')

    local updated=false

    # ensure_kparam adds a kernel parameter if not already present.
    # Uses -F for fixed-string matching (dots in param names are literal, not regex wildcards).
    # Modifies outer current_cmdline and updated via bash dynamic scoping.
    ensure_kparam() {
        local param="$1"
        if ! echo "$current_cmdline" | grep -qwF "$param"; then
            current_cmdline="$current_cmdline $param"
            updated=true
        fi
    }

    # Replace s2idle with deep for proper S3 suspend (desktop hardware)
    if echo "$current_cmdline" | grep -q 'mem_sleep_default=s2idle'; then
        # Remove all occurrences of mem_sleep_default=s2idle
        current_cmdline=$(echo "$current_cmdline" | sed 's/mem_sleep_default=s2idle//g')
        updated=true
    fi

    ensure_kparam "nvidia-drm.modeset=1"
    ensure_kparam "nvidia-drm.fbdev=1"
    ensure_kparam "nvidia.NVreg_PreserveVideoMemoryAllocations=1"
    ensure_kparam "mem_sleep_default=deep"

    if [ "$updated" = true ]; then
        # Collapse multiple spaces and trim
        current_cmdline=$(echo "$current_cmdline" | tr -s ' ' | sed 's/^ *//;s/ *$//')
        print_info "Updating GRUB kernel parameters for NVIDIA + suspend..."
        sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$current_cmdline\"|" "$grub_default"
        regenerate_grub_config || {
            track_warning "Failed to regenerate GRUB config"
            return
        }
        print_success "GRUB kernel parameters updated (reboot required)"
    else
        print_success "GRUB kernel parameters already configured"
    fi
}

# Install STOP/CONT systemd services for a Wayland compositor
# $1: process name to signal (e.g. "Hyprland", "niri")
# $2: service name prefix (e.g. "hyprland", "niri")
install_compositor_suspend_services() {
    local process_name="$1"
    local service_prefix="$2"
    local suspend_svc="/etc/systemd/system/${service_prefix}-suspend.service"
    local resume_svc="/etc/systemd/system/${service_prefix}-resume.service"

    if [ -f "$suspend_svc" ] && [ -f "$resume_svc" ]; then
        print_info "${process_name} suspend/resume services already installed"
        for svc in "${service_prefix}-suspend.service" "${service_prefix}-resume.service"; do
            if ! systemctl is-enabled "$svc" &>/dev/null; then
                if ! sudo systemctl enable "$svc"; then
                    print_warning "Failed to enable $svc"
                fi
            fi
        done
        return 0
    fi

    print_info "Installing ${process_name} suspend/resume services..."

    sudo tee "$suspend_svc" > /dev/null << EOF
[Unit]
Description=Suspend ${process_name} before NVIDIA driver suspends
Before=nvidia-suspend.service
Before=nvidia-hibernate.service

[Service]
Type=oneshot
ExecStart=-/usr/bin/pkill -STOP -x ${process_name}

[Install]
WantedBy=systemd-suspend.service
WantedBy=systemd-hibernate.service
WantedBy=systemd-suspend-then-hibernate.service
EOF

    sudo tee "$resume_svc" > /dev/null << EOF
[Unit]
Description=Resume ${process_name} after NVIDIA driver resumes
After=nvidia-resume.service

[Service]
Type=oneshot
ExecStart=-/usr/bin/pkill -CONT -x ${process_name}

[Install]
WantedBy=systemd-suspend.service
WantedBy=systemd-hibernate.service
WantedBy=systemd-suspend-then-hibernate.service
EOF

    # Use enable without --now: these are oneshot services that should only run during actual suspend/resume
    sudo systemctl daemon-reload
    sudo systemctl enable "${service_prefix}-suspend.service" 2>/dev/null
    sudo systemctl enable "${service_prefix}-resume.service" 2>/dev/null
    print_success "${process_name} suspend/resume services installed"
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
    if group_selected development; then
        add_user_to_group "docker"
    fi

    # Add user to input group for swayosd caps-lock detection (Hyprland/Niri)
    if group_selected hyprland || group_selected niri; then
        add_user_to_group "input"
    fi

    # Set tailscale operator and authenticate if development is selected and tailscale is installed
    if group_selected development && command -v tailscale &>/dev/null; then
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

# Trim services that gate the system graphical.target so uwsm can launch the
# compositor sooner after SDDM login.
#
# Diagnosed via `systemd-analyze critical-chain`:
#   graphical.target @25.6s
#     └─multi-user.target @25.6s
#       └─docker.service @20.7s +4.9s
#         └─network-online.target @20.7s
#           └─NetworkManager-wait-online.service @5.4s +15.3s
#
# Net result: ~12s of black screen between SDDM login and Hyprland appearing.
tune_boot_performance() {
    if [ "$INSTALL_PURPOSE" != "desktop" ]; then
        return 0
    fi

    print_header "Tuning Boot Performance"

    source "$SCRIPT_DIR/lib/services.sh"

    # 1. NetworkManager-wait-online — adds 15s+ before graphical.target.
    # Safe to disable on a workstation; no service in our stack needs the
    # network fully online before the user session starts.
    disable_service NetworkManager-wait-online.service

    # 2. Docker — stock unit has Wants=network-online.target, which would
    # re-pull NetworkManager-wait-online (or any equivalent) and also chains
    # ~5s of dockerd startup onto multi-user.target. Drop both the Wants= and
    # After=network-online.target via a system drop-in so docker starts in
    # parallel and doesn't gate graphical.target. Re-add the rest of the stock
    # After= list and Wants=containerd.service so functionality is preserved.
    if [[ " ${SERVICES_TO_ENABLE[*]} " == *" docker "* ]]; then
        local docker_dropin_dir=/etc/systemd/system/docker.service.d
        local docker_dropin_file="$docker_dropin_dir/no-network-online.conf"
        print_info "Installing docker drop-in: drop Wants/After=network-online.target"
        sudo mkdir -p "$docker_dropin_dir"
        sudo tee "$docker_dropin_file" > /dev/null << 'EOF'
# Managed by dotfiles installer (tune_boot_performance).
# Drops network-online.target dependency so docker doesn't gate graphical.target.
[Unit]
Wants=
Wants=containerd.service
After=
After=nss-lookup.target docker.socket firewalld.service containerd.service time-set.target
EOF
        sudo systemctl daemon-reload
        print_success "Docker drop-in installed at $docker_dropin_file"
    fi

    # 3. vibewatch — upstream installer enables the unit via default.target.wants,
    # which fires it before the compositor exists. Remove that stale symlink;
    # the chezmoi drop-in rebinds the lifecycle to graphical-session.target.
    local stale_vibewatch_link="$HOME/.config/systemd/user/default.target.wants/vibewatch.service"
    if [ -L "$stale_vibewatch_link" ]; then
        print_info "Removing stale vibewatch enable symlink in default.target.wants/"
        rm -f "$stale_vibewatch_link"
        systemctl --user daemon-reload 2>/dev/null || true
    fi

    print_success "Boot performance tuned"
}

# Configure and enable ClamAV (conditional on security group).
# ClamAV ships with a poison-pill `Example` line in its configs and a commented
# LocalSocket; the daemon won't start until these are fixed. On Debian the
# postinst handles it, but Arch/Fedora require the edits below. We then enable
# the freshclam updater, wait for the signature DBs to populate, and start the
# on-access scan daemon (needs DBs present to load).
setup_clamav() {
    if ! group_selected security; then
        return 0
    fi

    if ! command_exists clamscan && ! command_exists freshclam; then
        return 0
    fi

    print_header "Configuring ClamAV"

    local freshclam_conf clamd_conf freshclam_svc clamd_svc
    case "$DISTRO_FAMILY" in
        arch|debian)
            freshclam_conf=/etc/clamav/freshclam.conf
            clamd_conf=/etc/clamav/clamd.conf
            freshclam_svc=clamav-freshclam.service
            clamd_svc=clamav-daemon.service
            ;;
        fedora)
            freshclam_conf=/etc/freshclam.conf
            clamd_conf=/etc/clamd.d/scan.conf
            freshclam_svc=clamav-freshclam.service
            clamd_svc=clamd@scan.service
            ;;
        *)
            print_warning "ClamAV auto-config not implemented for $DISTRO_FAMILY — skipping"
            return 0
            ;;
    esac

    sudo sed -i '/^Example[[:space:]]*$/d' "$freshclam_conf" "$clamd_conf"
    sudo sed -i '0,/^#[[:space:]]*LocalSocket[[:space:]]/s//LocalSocket /' "$clamd_conf"

    # Apply tmpfiles.d so /run/clamd.scan (Fedora) / /run/clamav (Arch) exists
    # before starting the daemon — otherwise it fails until first reboot.
    sudo systemd-tmpfiles --create >/dev/null 2>&1 || true

    # Start freshclam first — clamd needs main.cvd/daily.cvd to load.
    enable_service "$freshclam_svc"

    local dbs_glob='/var/lib/clamav/main.c?d'
    if ! compgen -G "$dbs_glob" >/dev/null; then
        print_info "Waiting for freshclam to download signature DBs (up to 180s)..."
        local waited=0
        while ! compgen -G "$dbs_glob" >/dev/null && (( waited < 180 )); do
            sleep 5
            (( waited += 5 ))
        done
        if compgen -G "$dbs_glob" >/dev/null; then
            print_success "Signature DBs downloaded"
        else
            track_warning "ClamAV signature DBs not yet present — check: journalctl -u $freshclam_svc"
        fi
    fi

    enable_service "$clamd_svc"
}

# Configure fingerprint authentication (fprintd + PAM) and Bitwarden biometric unlock.
setup_biometric() {
    group_selected biometric || return 0
    if ! command_exists fprintd-enroll; then
        track_warning "fprintd not installed — skipping biometric setup"
        return 0
    fi

    print_header "Configuring Biometric Authentication"

    if fprintd-list "$USER" 2>&1 | grep -q '^Fingerprints for user'; then
        print_info "Fingerprint(s) already enrolled for $USER"
    elif gum confirm "Enroll a fingerprint now?"; then
        print_info "Touch the sensor several times when prompted..."
        # Use sudo: polkit's enroll rule requires an "active" session with auth_admin,
        # which fails from many terminal contexts (subterminals, IDE shells, tmux).
        # fprintd-enroll defaults to right-index-finger; user can re-run for other fingers.
        if sudo fprintd-enroll "$USER"; then
            print_success "Fingerprint enrolled"
        else
            track_warning "fprintd-enroll failed — run 'sudo fprintd-enroll \$USER' manually later"
        fi
    fi

    # PAM fingerprint covers login, sudo, AND polkit — Bitwarden's biometric unlock goes via polkit.
    if gum confirm "Enable fingerprint for system auth (login, sudo, polkit, Bitwarden)?"; then
        case "$DISTRO_FAMILY" in
            fedora)
                if ! command_exists authselect; then
                    track_warning "authselect not found — enable PAM fingerprint manually"
                elif authselect current 2>/dev/null | grep -q 'with-fingerprint'; then
                    print_info "authselect 'with-fingerprint' feature already enabled"
                elif sudo authselect enable-feature with-fingerprint; then
                    print_success "Enabled authselect 'with-fingerprint'"
                else
                    track_warning "Failed to enable authselect 'with-fingerprint'"
                fi
                ;;
            arch|debian)
                local pam_file
                if [ "$DISTRO_FAMILY" = "arch" ]; then
                    pam_file=/etc/pam.d/system-local-login
                    [ -f /etc/pam.d/system-auth ] && pam_file=/etc/pam.d/system-auth
                else
                    pam_file=/etc/pam.d/common-auth
                fi
                if sudo grep -q 'pam_fprintd.so' "$pam_file" 2>/dev/null; then
                    print_info "pam_fprintd already configured in $pam_file"
                else
                    print_info "Adding pam_fprintd.so to $pam_file"
                    sudo cp "$pam_file" "${pam_file}.bak.$(date +%s)"
                    sudo sed -i '0,/^auth/s//auth      sufficient   pam_fprintd.so\n&/' "$pam_file"
                    print_success "PAM fingerprint enabled (backup: ${pam_file}.bak.*)"
                fi
                ;;
            *)
                track_warning "PAM fingerprint setup not implemented for $DISTRO_FAMILY"
                ;;
        esac
    fi

    # Hyprlock / swaylock PAM stacks default to `auth include login`, which pulls in
    # system-auth where pam_fprintd sits before pam_unix — so typing a password waits
    # for the fprintd timeout (~10s) before falling through. Switch to password-auth
    # (no fprintd) for instant password fallback. Fingerprint at the lockscreen is
    # handled by hyprlock natively via D-Bus (auth.fingerprint in hyprlock.conf),
    # independently from this PAM stack.
    local pam_file ts
    ts=$(date +%s)
    for pam_file in /etc/pam.d/hyprlock /etc/pam.d/swaylock; do
        [ -f "$pam_file" ] || continue
        if grep -qE '^auth\s+include\s+password-auth\s*$' "$pam_file"; then
            print_info "$(basename "$pam_file") PAM already uses password-auth"
            continue
        fi
        if ! grep -qE '^auth\s+include\s+login\s*$' "$pam_file"; then
            print_info "$(basename "$pam_file") PAM uses a non-default stack — leaving as is"
            continue
        fi
        print_info "Patching $pam_file to skip fprintd timeout on password"
        sudo cp "$pam_file" "${pam_file}.bak.${ts}"
        sudo sed -i 's|^auth\s\+include\s\+login\s*$|auth        include      password-auth|' "$pam_file"
        print_success "$pam_file patched (backup: ${pam_file}.bak.${ts})"
    done

    # SDDM (display manager) is left untouched. Enabling fingerprint at the
    # greeter requires switching the auth stack to one that includes
    # pam_fprintd, but PAM is serial (cf. man pam_fprintd) and SDDM lacks
    # GDM-style parallel auth UI — so any fprintd timeout becomes either a
    # short fingerprint window (silent, since the Breeze theme gives no
    # scanning feedback) or a multi-second wait after typing a password.
    # Neither trade-off is worth it given hyprlock already provides
    # fingerprint at the lockscreen via native D-Bus. Reboots fall back to
    # password at the SDDM greeter.

    # Bitwarden Flatpak needs talk access to the Secret Service (libsecret) — the
    # desktop stores its biometric-unlock key there. Browser integration is NOT
    # supported on Linux (Bitwarden limitation, not a Flatpak one), so we don't
    # bother granting access to browser config dirs.
    if flatpak info com.bitwarden.desktop &>/dev/null; then
        print_info "Applying Flatpak overrides for Bitwarden"
        if flatpak override --user com.bitwarden.desktop \
            --talk-name=org.freedesktop.secrets 2>/dev/null; then
            print_success "Bitwarden Flatpak overrides applied"
        else
            track_warning "Failed to apply Bitwarden Flatpak overrides"
        fi

        # The Flatpak sandbox can't install the polkit action that Bitwarden needs for
        # "Unlock with system authentication" — drop it in manually from upstream.
        # https://bitwarden.com/help/biometrics/#linux-flatpak
        local bw_policy=/usr/share/polkit-1/actions/com.bitwarden.Bitwarden.policy
        local bw_policy_url=https://raw.githubusercontent.com/bitwarden/clients/main/apps/desktop/resources/com.bitwarden.desktop.policy
        if [ -f "$bw_policy" ]; then
            print_info "Bitwarden polkit policy already present"
        else
            print_info "Installing Bitwarden polkit policy"
            if sudo wget -q -O "$bw_policy" "$bw_policy_url" && sudo chown root:root "$bw_policy"; then
                # SELinux contexts (Fedora/RHEL) — chcon is a no-op without SELinux, skip if missing.
                command_exists chcon && sudo chcon system_u:object_r:usr_t:s0 "$bw_policy" 2>/dev/null || true
                print_success "Bitwarden polkit policy installed"
            else
                track_warning "Failed to install Bitwarden polkit policy — see https://bitwarden.com/help/biometrics/#linux-flatpak"
                sudo rm -f "$bw_policy"
            fi
        fi
    fi

    echo ""
    gum style --foreground 39 --bold "Next steps inside Bitwarden Desktop:"
    echo "  1. Open Bitwarden Desktop and log in with your master password"
    echo "  2. Settings → Security → enable 'Unlock with system authentication'"
    echo "     (confirms with your fingerprint via polkit)"
    echo ""
    print_warning "Bitwarden does NOT support browser-extension biometric unlock on Linux."
    print_info "    Workaround: enable 'Unlock with PIN' in the extension for fast unlock."
    print_info "    Master password is still required on the first unlock after login/reboot."
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
        SSH_KEY_GENERATED=true

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
    if ! group_selected niri && ! group_selected hyprland; then
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

    # Compositor priority: distro-provided config > kwin_wayland > weston > fallback.
    # KDE-based installs already ship kwin_wayland which handles multi-monitor
    # natively. Weston is the lightweight fallback for non-KDE systems.
    local sddm_compositor="none"
    if [ -f /usr/lib/sddm/sddm.conf.d/plasma-wayland.conf ]; then
        # Distro (e.g. Fedora) ships its own SDDM Wayland config — only set theme
        sddm_compositor="distro"
        print_info "Detected distro-provided SDDM Wayland config — only setting theme"
        sudo tee /etc/sddm.conf.d/theme.conf > /dev/null <<EOF
[Theme]
Current=${theme:-breeze}
Font="Noto Sans"
EOF
    elif command_exists kwin_wayland; then
        sddm_compositor="kwin"
        print_info "Using kwin_wayland as SDDM compositor"
        sudo tee /etc/sddm.conf.d/theme.conf > /dev/null <<EOF
[Theme]
Current=${theme:-breeze}

[General]
DisplayServer=wayland

[Wayland]
CompositorCommand=kwin_wayland --no-global-shortcuts --no-lockscreen --locale1
EOF
    elif command_exists weston; then
        sddm_compositor="weston"
        print_info "Using weston as SDDM compositor"
        sudo tee /etc/sddm.conf.d/theme.conf > /dev/null <<EOF
[Theme]
Current=${theme:-breeze}

[General]
DisplayServer=wayland

[Wayland]
CompositorCommand=weston --shell=kiosk -c /etc/sddm/weston.ini
EOF
    else
        print_info "No Wayland compositor found for SDDM greeter — using default display server"
        sudo tee /etc/sddm.conf.d/theme.conf > /dev/null <<EOF
[Theme]
Current=${theme:-breeze}
Font="Noto Sans"
EOF
    fi

    # --- Weston config (only needed when weston is the SDDM compositor) ---
    if [ "$sddm_compositor" = "weston" ]; then
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
        # Rotated monitors are disabled (mode=off) so the greeter only shows on
        # the horizontal screen. A systemd drop-in waits for the primary monitor
        # to be detected before starting SDDM, preventing a black screen if DP
        # link training is slow (e.g. monitor waking from deep sleep).
        local primary_outputs=()
        if command -v xrandr &>/dev/null && xrandr --query &>/dev/null; then
            while IFS= read -r line; do
                local output_name rotation mode transform
                output_name=$(echo "$line" | awk '{print $1}')
                # Check if rotation keyword is present before the parenthesized list of supported rotations
                rotation=$(echo "$line" | sed 's/(.*//' | grep -oE '\b(left|right|inverted)\b' || true)
                if [ -n "$rotation" ]; then
                    # Rotated monitor — disable for greeter
                    weston_cfg="${weston_cfg}

[output]
name=${output_name}
mode=off"
                else
                    # Non-rotated monitor — enable with native resolution
                    mode=$(xrandr --query 2>/dev/null | grep -A 1 "^${output_name} connected" | tail -1 | awk '{print $1}')
                    if [ -n "$output_name" ] && [[ "$mode" =~ ^[0-9]+x[0-9]+ ]]; then
                        primary_outputs+=("$output_name")
                        weston_cfg="${weston_cfg}

[output]
name=${output_name}
mode=${mode}
transform=normal"
                    fi
                fi
            done < <(xrandr --query 2>/dev/null | grep " connected ")
        else
            print_info "xrandr not available — skipping monitor rotation detection for weston.ini"
        fi

        echo "$weston_cfg" | sudo tee /etc/sddm/weston.ini > /dev/null

        # --- Wait-for-monitor script ---
        # Ensures the primary (non-rotated) monitor is detected before SDDM starts
        if [ ${#primary_outputs[@]} -gt 0 ]; then
            local grep_pattern
            grep_pattern=$(printf '%s\\|' "${primary_outputs[@]}")
            grep_pattern=${grep_pattern%\\|}

            sudo tee /etc/sddm/wait-for-primary-monitor.sh > /dev/null <<WAITEOF
#!/bin/bash
# Wait up to 10s for a primary monitor to be connected before SDDM starts.
# Generated by dotfiles installer — do not edit manually.
TIMEOUT=10
for i in \$(seq 1 \$TIMEOUT); do
    for status_file in /sys/class/drm/card*-*/status; do
        name=\$(basename "\$(dirname "\$status_file")")
        name=\${name#card*-}
        if echo "\$name" | grep -qx '${grep_pattern}'; then
            [ "\$(cat "\$status_file")" = "connected" ] && exit 0
        fi
    done
    sleep 1
done
exit 0
WAITEOF
            sudo chmod +x /etc/sddm/wait-for-primary-monitor.sh

            sudo mkdir -p /etc/systemd/system/sddm.service.d
            sudo tee /etc/systemd/system/sddm.service.d/wait-for-monitor.conf > /dev/null <<DROPEOF
[Service]
ExecStartPre=/etc/sddm/wait-for-primary-monitor.sh
DROPEOF
        else
            # No primary outputs detected — clean up stale wait-script artifacts
            sudo rm -f /etc/sddm/wait-for-primary-monitor.sh
            sudo rm -f /etc/systemd/system/sddm.service.d/wait-for-monitor.conf
        fi
    else
        # Clean up weston artifacts from previous installs
        sudo rm -f /etc/sddm/weston.ini /etc/sddm/wait-for-primary-monitor.sh
        sudo rm -f /etc/systemd/system/sddm.service.d/wait-for-monitor.conf
    fi

    sudo systemctl daemon-reload 2>/dev/null

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
            print_info "SDDM not enabled — login screen wallpaper will not be visible"
        fi
    fi

    print_success "SDDM configured"

    # Hyprland session choice hint: the hyprland package installs two SDDM
    # sessions (hyprland.desktop, hyprland-uwsm.desktop). The dotfiles assume
    # the uwsm-managed variant — daemons are bound to graphical-session.target
    # which only activates under uwsm. SDDM remembers the per-user last
    # selection in /var/lib/sddm/state.conf, so this is one-time.
    if [[ " ${SELECTED_GROUP_NAMES[*]} " =~ " hyprland " ]] \
        && [ -f /usr/share/wayland-sessions/hyprland-uwsm.desktop ]; then
        echo ""
        print_info "At the SDDM greeter, select 'Hyprland (uwsm-managed)' the first time you log in."
        print_info "Selecting plain 'Hyprland' will skip uwsm and leave the session daemons unstarted."
    fi
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
        print_info "No theme selected, using default (spinner)"
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
            sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$current_cmdline\"|" "$grub_default"
            regenerate_grub_config
        else
            print_info "GRUB already has 'quiet splash'"
        fi
    else
        print_info "$grub_default not found — skipping GRUB configuration"
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
        SHELL_CHANGED=true
        print_success "Default shell changed to zsh"
        print_info "Log out and back in for changes to take effect"
    fi
}

# Setup GRUB theme (delegates to manage-grub-theme.sh)
setup_grub_theme() {
    [ "$INSTALL_PURPOSE" = "desktop" ] || return 0
    [ -f /etc/default/grub ] || return 0

    "$DOTFILES_DIR/tools/manage-grub-theme.sh" setup
}

# Configure GRUB to remember last booted kernel when multiple kernels are installed
configure_grub_saved_default() {
    local grub_default="/etc/default/grub"
    [ -f "$grub_default" ] || return 0

    # Only relevant when multiple kernels are present
    local kernel_count
    kernel_count=$(find /boot -maxdepth 1 -name 'vmlinuz-*' 2>/dev/null | wc -l)
    [ "$kernel_count" -gt 1 ] || return 0

    local updated=false
    # Ensure a GRUB variable is set; handles active, commented-out, or missing lines
    ensure_grub_var() {
        local var="$1" value="$2"
        grep -q "^${var}=${value}$" "$grub_default" && return
        if grep -q "^#\?${var}=" "$grub_default"; then
            sudo sed -i "s/^#\?${var}=.*/${var}=${value}/" "$grub_default"
        else
            echo "${var}=${value}" | sudo tee -a "$grub_default" > /dev/null
        fi
        updated=true
    }

    print_info "Setting GRUB to remember last booted kernel..."
    ensure_grub_var GRUB_DEFAULT saved
    ensure_grub_var GRUB_SAVEDEFAULT true
    # Disable submenus so saved_entry uses flat IDs (submenu '>' paths break GRUB_SAVEDEFAULT)
    ensure_grub_var GRUB_DISABLE_SUBMENU y

    if [ "$updated" = true ]; then
        regenerate_grub_config || track_warning "Failed to regenerate GRUB config"
    fi
}

# Setup BTRFS snapshots with Snapper (conditional on BTRFS + productivity group)
setup_btrfs_snapshots() {
    # Only run if productivity group was selected
    if ! group_selected productivity; then
        return 0
    fi

    # Check if root filesystem is BTRFS
    if ! is_root_btrfs; then
        print_info "Root filesystem is not BTRFS — skipping snapshot setup"
        return 0
    fi

    # Verify snapper is installed
    if ! command_exists snapper; then
        print_info "snapper not found — skipping BTRFS snapshot setup"
        return 0
    fi

    if is_btrfs_snapshots_configured; then
        print_info "BTRFS snapshots already configured, skipping"
        BTRFS_SNAPSHOTS_CONFIGURED=true
        return 0
    fi

    echo ""
    print_info "BTRFS root detected with snapper installed"
    if ! gum confirm "Configure automatic BTRFS snapshots before package upgrades?"; then
        return 0
    fi

    print_info "Configuring BTRFS snapshots..."

    # Create snapper root config if it doesn't exist
    local config_created=false
    if [ ! -f /etc/snapper/configs/root ]; then
        print_info "Creating snapper root config..."
        # Safety: if /.snapshots contains numbered snapshot dirs, snapper was previously
        # configured — the root config check above likely failed due to permissions.
        # Bail out rather than destroying existing snapshots.
        if ls -d /.snapshots/[0-9]* &>/dev/null; then
            print_warning "/.snapshots contains existing snapshots but no snapper root config was detected"
            print_warning "This likely means snapper is configured but the check failed — skipping destructive setup"
            print_warning "Run 'snapper list-configs' manually to verify"
            return 0
        fi
        # Remove pre-existing .snapshots subvolume/directory that blocks snapper create-config
        # archinstall creates a top-level @.snapshots subvolume mounted at /.snapshots
        if findmnt -n /.snapshots &>/dev/null; then
            print_info "Unmounting pre-existing /.snapshots..."
            sudo umount /.snapshots || {
                print_warning "Failed to unmount /.snapshots — skipping snapshot setup"
                return 0
            }
            # Delete the top-level @.snapshots subvolume (e.g. from archinstall)
            local root_dev
            root_dev=$(findmnt -n -o SOURCE / | sed 's/\[.*\]//')
            if [ -n "$root_dev" ]; then
                local tmp_mnt
                tmp_mnt=$(mktemp -d)
                if sudo mount -o subvolid=5 "$root_dev" "$tmp_mnt"; then
                    if sudo btrfs subvolume show "$tmp_mnt/@.snapshots" &>/dev/null; then
                        print_info "Deleting top-level @.snapshots subvolume..."
                        # Delete nested snapshot subvolumes first
                        for snap_dir in "$tmp_mnt/@.snapshots"/*/snapshot; do
                            [ -d "$snap_dir" ] && sudo btrfs subvolume delete "$snap_dir" 2>/dev/null || true
                        done
                        sudo btrfs subvolume delete "$tmp_mnt/@.snapshots" || true
                    fi
                    sudo umount "$tmp_mnt" || print_warning "Failed to unmount $tmp_mnt"
                fi
                rmdir "$tmp_mnt" 2>/dev/null
            fi
        fi
        if sudo btrfs subvolume show /.snapshots &>/dev/null; then
            print_info "Removing pre-existing /.snapshots subvolume..."
            # Delete nested snapshot subvolumes first (btrfs refuses to delete non-empty subvolumes)
            for snap_dir in /.snapshots/*/snapshot; do
                [ -d "$snap_dir" ] && sudo btrfs subvolume delete "$snap_dir" 2>/dev/null || true
            done
            sudo btrfs subvolume delete /.snapshots || {
                print_warning "Failed to remove /.snapshots subvolume — skipping snapshot setup"
                return 0
            }
        fi
        if [ -d /.snapshots ]; then
            sudo rmdir /.snapshots || {
                print_warning "Failed to remove /.snapshots directory — skipping snapshot setup"
                return 0
            }
        fi
        sudo snapper create-config / || {
            print_warning "Failed to create snapper root config — skipping snapshot setup"
            return 0
        }
        config_created=true
    fi

    # Disable timeline snapshots (we only want pre-upgrade snapshots)
    sudo snapper -c root set-config "TIMELINE_CREATE=no" || {
        print_warning "Failed to configure snapper timeline settings"
    }

    # Allow the current user to run snapper without sudo
    sudo snapper -c root set-config "ALLOW_USERS=$USER" || {
        print_warning "Failed to set ALLOW_USERS for snapper"
    }

    # Remove stale @.snapshots fstab entry (archinstall leftover, now managed by snapper)
    if grep -q '^UUID=.*@\.snapshots' /etc/fstab; then
        print_info "Removing stale @.snapshots fstab entry..."
        sudo sed -i '/^UUID=.*@\.snapshots/d' /etc/fstab
    fi

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

    # Debian/Fedora: install grub-btrfs from source (not in repos)
    if [[ "$DISTRO_FAMILY" =~ ^(debian|fedora)$ ]] && ! command_exists grub-btrfsd; then
        print_info "Installing grub-btrfs from source..."
        local tmp_dir
        tmp_dir=$(mktemp -d)
        if git clone --depth 1 https://github.com/Antynea/grub-btrfs.git "$tmp_dir"; then
            # Fedora uses grub2 paths instead of grub — patch clone before install
            if [ "$DISTRO_FAMILY" = "fedora" ]; then
                _patch_grub_btrfs_fedora_paths "$tmp_dir/config"
            fi
            if ! (cd "$tmp_dir" && sudo make install); then
                track_warning "Failed to install grub-btrfs from source"
            fi
        else
            track_warning "Failed to clone grub-btrfs repository"
        fi
        rm -rf "$tmp_dir"
    fi

    # Enable grub-btrfsd service if available
    if systemctl list-unit-files grub-btrfsd.service &>/dev/null; then
        print_info "Configuring grub-btrfsd to watch snapper snapshots..."
        # Override the default service to watch /.snapshots (snapper) instead of --timeshift-auto
        sudo mkdir -p /etc/systemd/system/grub-btrfsd.service.d
        sudo tee /etc/systemd/system/grub-btrfsd.service.d/override.conf > /dev/null << 'SVCEOF'
[Service]
ExecStart=
ExecStart=/usr/bin/grub-btrfsd --syslog /.snapshots
SVCEOF
        sudo systemctl daemon-reload
        print_info "Enabling grub-btrfsd service..."
        sudo systemctl enable --now grub-btrfsd || {
            print_warning "Failed to enable grub-btrfsd service"
        }
        # Regenerate grub config to include snapshot entries
        regenerate_grub_config || track_warning "Failed to regenerate GRUB config for grub-btrfs"
    fi

    # Create initial snapshot only when config was freshly created
    if [ "$config_created" = true ]; then
        sudo snapper create --description "Initial snapshot after dotfiles setup" || {
            print_warning "Failed to create initial snapshot"
        }
    fi

    BTRFS_SNAPSHOTS_CONFIGURED=true
    print_success "BTRFS snapshot setup complete"
}

# Show completion message
show_completion() {
    echo ""
    
    # Build next steps list — only include steps the user actually needs to act on
    local steps=()
    local next_step=1

    if [ "$SHELL_CHANGED" = true ]; then
        steps+=("  $next_step. Log out and back in (for shell changes)")
        next_step=$((next_step + 1))
    fi

    if [ "$TMUX_PLUGINS_INSTALLED" = true ]; then
        steps+=("  $next_step. Run 'tmux' and press Ctrl+b I (install plugins)")
        next_step=$((next_step + 1))
    fi

    if [ "$SSH_KEY_GENERATED" = true ]; then
        steps+=("  $next_step. Add your SSH key to GitHub/GitLab")
        next_step=$((next_step + 1))
    fi

    # Hyprland reload only if currently running in Hyprland
    if [ -n "$HYPRLAND_INSTANCE_SIGNATURE" ]; then
        steps+=("  $next_step. Run 'hyprctl reload' to reload Hyprland config")
        next_step=$((next_step + 1))
    fi

    if group_selected niri; then
        steps+=("  $next_step. Log out, choose Niri in your display manager, and log back in")
        next_step=$((next_step + 1))
    fi

    if group_selected ai; then
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

    # Show warnings summary if any
    if [ ${#INSTALL_WARNINGS[@]} -gt 0 ]; then
        local warning_lines=()
        for w in "${INSTALL_WARNINGS[@]}"; do
            warning_lines+=("  • $w")
        done
        gum style \
            --border rounded \
            --border-foreground 214 \
            --padding "1 2" \
            --margin "1" \
            "$(gum style --foreground 214 --bold '⚠ Some steps were skipped:')" \
            "" \
            "${warning_lines[@]}"
    fi

    local body=("$(gum style --foreground 82 --bold '✅ Installation Complete!')")
    if [ ${#steps[@]} -gt 0 ]; then
        body+=("" "Next steps:" "${steps[@]}")
    fi

    gum style \
        --border double \
        --border-foreground 82 \
        --padding "1 2" \
        --margin "1" \
        "${body[@]}"
    echo ""
}

# Main installation flow
main() {
    # Initialize installer state
    SELECTED_GROUP_NAMES=()
    SERVICES_TO_ENABLE=()
    PLYMOUTH_CONFIGURED=false
    BTRFS_SNAPSHOTS_CONFIGURED=false
    SHELL_CHANGED=false
    SSH_KEY_GENERATED=false
    TMUX_PLUGINS_INSTALLED=false
    unset GROUP_PACKAGE_MODE GROUP_CUSTOM_PACKAGE_LIST
    declare -gA GROUP_PACKAGE_MODE=()
    declare -gA GROUP_CUSTOM_PACKAGE_LIST=()

    # Detect NVIDIA GPU
    HAS_NVIDIA=false
    if has_nvidia_gpu; then
        HAS_NVIDIA=true
        print_info "NVIDIA GPU detected"
    fi

    HAS_FINGERPRINT=false
    if has_fingerprint_reader; then
        HAS_FINGERPRINT=true
        print_info "Fingerprint reader detected"
    fi

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
        local group_name
        group_name=$(basename "$group_file" .yaml)
        # Filter groups by environment when in terminal mode
        if [ "$INSTALL_PURPOSE" = "terminal" ]; then
            local env
            env=$(grep '^environment:' "$group_file" | awk '{print $2}')
            if [ "$env" != "both" ]; then
                continue
            fi
        fi
        # No fingerprint reader → silently skip the biometric group. Bitwarden
        # itself lives in 'productivity' now, so it still installs without one.
        if [ "$group_name" = "biometric" ] && [ "$HAS_FINGERPRINT" != "true" ]; then
            continue
        fi
        SELECTED_GROUP_NAMES+=("$group_name")
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
        migrate_notification_daemon
        migrate_dropbox_to_dist
        apply_dark_mode_defaults
    fi
    enable_selected_services
    tune_boot_performance
    setup_clamav
    setup_biometric
    configure_grub_saved_default
    setup_grub_theme
    setup_btrfs_snapshots
    if [ "$INSTALL_PURPOSE" = "desktop" ]; then
        install_nvidia_drivers
        setup_nvidia
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
