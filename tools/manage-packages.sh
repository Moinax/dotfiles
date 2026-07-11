#!/bin/bash
# Package Manager — add/remove packages from group definitions
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGES_DIR="$DOTFILES_DIR/packages"
GROUPS_DIR="$PACKAGES_DIR/groups"
CHEZMOI_CONF="$HOME/.config/chezmoi/chezmoi.toml"

# Source shared utilities
source "$DOTFILES_DIR/install/lib/common.sh"
source "$DOTFILES_DIR/install/lib/detect.sh"
source "$DOTFILES_DIR/install/lib/services.sh"

install_interrupt_trap

# Detect distro and source distro-specific functions
DISTRO=$(detect_distro)
DISTRO_FAMILY=$(get_distro_family "$DISTRO")

if [ -f "$DOTFILES_DIR/install/distros/$DISTRO_FAMILY.sh" ]; then
    source "$DOTFILES_DIR/install/distros/$DISTRO_FAMILY.sh"
else
    print_error "Unsupported distribution family: $DISTRO_FAMILY"
    exit 1
fi

# Check if install purpose is "terminal" (for filtering desktop_only packages)
is_terminal_install() {
    [ -f "$CHEZMOI_CONF" ] && grep -Eq '^[[:space:]]*install_purpose[[:space:]]*=[[:space:]]*"terminal"' "$CHEZMOI_CONF"
}

# ── YAML helpers ─────────────────────────────────────────────────────────────

# Get group name from YAML file
get_group_name() {
    local file="$1"
    if command_exists yq; then
        yq -r '.name // ""' "$file" 2>/dev/null
    else
        grep -m1 '^name:' "$file" | sed 's/^name:[[:space:]]*//'
    fi
}

# Get group icon from YAML file
get_group_icon() {
    local file="$1"
    if command_exists yq; then
        yq -r '.icon // ""' "$file" 2>/dev/null
    else
        grep -m1 '^icon:' "$file" | sed 's/^icon:[[:space:]]*//'
    fi
}

# Get group ID from filename (e.g., development.yaml -> development)
get_group_id() {
    local file="$1"
    basename "$file" .yaml
}

# Get chezmoi flag name for a group (e.g., development -> install_development)
get_chezmoi_flag() {
    local group_id="$1"
    echo "install_${group_id}"
}

# Read current chezmoi flag value (true/false/empty if not found)
get_chezmoi_flag_value() {
    local flag="$1"
    if [ -f "$CHEZMOI_CONF" ]; then
        grep -E "^[[:space:]]*${flag}[[:space:]]*=[[:space:]]*(true|false)" "$CHEZMOI_CONF" 2>/dev/null \
            | grep -oE '(true|false)' || true
    fi
}

# Update a chezmoi flag value
update_chezmoi_flag() {
    local flag="$1"
    local value="$2"

    if [ ! -f "$CHEZMOI_CONF" ]; then
        print_warning "chezmoi.toml not found, skipping flag update"
        return
    fi

    if grep -qF "${flag} = " "$CHEZMOI_CONF"; then
        sed -i "s/^[[:space:]]*${flag} = .*/    ${flag} = ${value}/" "$CHEZMOI_CONF"
        print_success "Updated ${flag} = ${value} in chezmoi.toml"
    fi
}

# ── Package list helpers ─────────────────────────────────────────────────────

# Build a list of packages for a group on the current distro,
# filtered by install purpose (desktop/terminal).
# Outputs one package name per line.
get_group_packages() {
    local file="$1"
    local all_packages=""

    local distro_pkgs custom_pkgs
    distro_pkgs=$(parse_packages "$file" "$DISTRO_FAMILY")
    custom_pkgs=$(parse_custom_install_names "$file" "$DISTRO_FAMILY")

    # Combine distro and custom_install packages
    [ -n "$distro_pkgs" ] && all_packages+="$distro_pkgs"$'\n'
    [ -n "$custom_pkgs" ] && all_packages+="$custom_pkgs"$'\n'
    all_packages=$(echo -n "$all_packages" | grep -v "^$" || true)

    if [ -z "$all_packages" ]; then
        return
    fi

    # Filter desktop_only packages when in terminal mode
    if is_terminal_install; then
        local desktop_only_list
        desktop_only_list=$(parse_desktop_only "$file")
        if [ -n "$desktop_only_list" ]; then
            local filtered=""
            while IFS= read -r pkg; do
                if ! echo "$desktop_only_list" | grep -qxF "$pkg"; then
                    filtered+="${pkg}"$'\n'
                fi
            done <<< "$all_packages"
            echo "$filtered" | grep -v "^$"
            return
        fi
    fi

    echo "$all_packages"
}

# Build a descriptions associative array (pkg -> desc) from a group file
# Usage: load_descriptions "file.yaml"
# Sets global DESCRIPTIONS associative array
load_descriptions() {
    local file="$1"
    declare -gA DESCRIPTIONS=()
    local line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local key="${line%%=*}"
        local val="${line#*=}"
        DESCRIPTIONS["$key"]="$val"
    done < <(parse_descriptions "$file")
}

# ── Display helpers ──────────────────────────────────────────────────────────

# Format a package line for display: "package_name — description"
format_package() {
    local pkg="$1"
    local desc="${DESCRIPTIONS[$pkg]:-}"
    if [ -n "$desc" ]; then
        echo "${pkg} — ${desc}"
    else
        echo "$pkg"
    fi
}

# Extract package name from a formatted line
extract_package_name() {
    local line="$1"
    echo "$line" | sed 's/ — .*//'
}

normalize_package_name_for_system() {
    local pkg="$1"
    if [ "$DISTRO_FAMILY" = "arch" ] && [[ "$pkg" == */* ]]; then
        echo "${pkg#*/}"
    else
        echo "$pkg"
    fi
}

# Check if a custom_install entry is installed using its check command.
# Returns 0 if installed, 1 otherwise. Returns 1 if not a custom_install package.
is_custom_install_pkg() {
    local file="$1" pkg="$2"
    local names
    names=$(parse_custom_install_names "$file" "$DISTRO_FAMILY" 2>/dev/null)
    echo "$names" | grep -qxF "$pkg"
}

is_custom_install_installed() {
    local file="$1" pkg="$2"
    local check_cmd
    check_cmd=$(parse_custom_install_check "$file" "$pkg")
    # Only the exit code matters. Detach stdin and silence all output so a
    # misbehaving check (e.g. one that launches an app or reads stdin) can't
    # hang the scan or bleed text into a captured stdout stream.
    [ -n "$check_cmd" ] && eval "$check_cmd" </dev/null >/dev/null 2>&1
}

is_group_package_installed() {
    local pkg="$1" file="${2:-}"
    if [ -n "$file" ] && is_custom_install_pkg "$file" "$pkg"; then
        is_custom_install_installed "$file" "$pkg"
    else
        is_package_installed "$(normalize_package_name_for_system "$pkg")"
    fi
}

# ── Group selection ──────────────────────────────────────────────────────────

# Show a gum chooser with all groups and their install counts.
# Returns the chosen group YAML file path, or empty on cancel.
choose_group() {
    local header="${1:-Select a group}"
    local group_files=("$GROUPS_DIR"/*.yaml)
    local labels=()
    local files=()

    for file in "${group_files[@]}"; do
        local name icon packages installed=0 total=0
        name=$(get_group_name "$file")
        icon=$(get_group_icon "$file")

        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            total=$((total + 1))
            if is_group_package_installed "$pkg" "$file"; then
                installed=$((installed + 1))
            fi
        done < <(get_group_packages "$file")

        # Skip groups with no packages for this distro
        [ "$total" -eq 0 ] && continue

        labels+=("${icon} ${name} (${installed}/${total} installed)")
        files+=("$file")
    done

    if [ ${#labels[@]} -eq 0 ]; then
        print_warning "No package groups found for $DISTRO_FAMILY"
        return 1
    fi

    local chosen
    chosen=$(printf '%s\n' "${labels[@]}" | gum choose --cursor.foreground="212" --header "$header") || return 1

    # Find the matching file
    for i in "${!labels[@]}"; do
        if [ "${labels[$i]}" = "$chosen" ]; then
            echo "${files[$i]}"
            return 0
        fi
    done
    return 1
}

# ── Add flow ─────────────────────────────────────────────────────────────────

show_add() {
    local file
    file=$(choose_group "Add packages from group") || return

    local name group_id
    name=$(get_group_name "$file")
    group_id=$(get_group_id "$file")
    load_descriptions "$file"

    # Build list of NOT-installed packages
    local available=()
    local pkg
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        if ! is_group_package_installed "$pkg" "$file"; then
            available+=("$(format_package "$pkg")")
        fi
    done < <(get_group_packages "$file")

    if [ ${#available[@]} -eq 0 ]; then
        print_success "All packages in ${name} are already installed"
        return
    fi

    print_info "Select packages to install from ${name} (tab to select, enter to confirm):"
    local selected
    selected=$(printf '%s\n' "${available[@]}" | gum filter --no-limit \
        --header "Packages to install:" \
        --placeholder "Type to filter...") || {
        echo "Cancelled."
        return
    }

    if [ -z "$selected" ]; then
        print_info "No packages selected"
        return
    fi

    # Extract package names
    local to_install=()
    while IFS= read -r line; do
        to_install+=("$(extract_package_name "$line")")
    done <<< "$selected"

    echo ""
    print_info "Will install: ${to_install[*]}"
    if ! gum confirm "Proceed with installation?"; then
        echo "Cancelled."
        return
    fi

    # Separate distro packages from custom_install packages
    local distro_packages=()
    local custom_packages=()
    for pkg in "${to_install[@]}"; do
        if is_custom_install_pkg "$file" "$pkg"; then
            custom_packages+=("$pkg")
        else
            distro_packages+=("$pkg")
        fi
    done

    if [ ${#distro_packages[@]} -gt 0 ]; then
        install_packages "${distro_packages[@]}"
    fi

    # Install custom_install packages via their own commands
    for pkg in "${custom_packages[@]}"; do
        local install_cmd requires_cmd
        install_cmd=$(parse_custom_install_cmd "$file" "$pkg")
        requires_cmd=$(parse_custom_install_requires "$file" "$pkg")

        if [ -n "$requires_cmd" ] && ! command_exists "$requires_cmd"; then
            print_warning "$requires_cmd not found — skipping $pkg"
            continue
        fi

        if [ -n "$install_cmd" ]; then
            install_curl_tool "$pkg" "$install_cmd" || print_warning "Failed to install $pkg"
        fi
    done

    # Check if all group packages are now installed
    local all_installed=true
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        if ! is_group_package_installed "$pkg" "$file"; then
            all_installed=false
            break
        fi
    done < <(get_group_packages "$file")

    # Offer to enable chezmoi flag if the whole group is now installed
    local flag flag_val
    flag=$(get_chezmoi_flag "$group_id")
    flag_val=$(get_chezmoi_flag_value "$flag")

    if [ "$all_installed" = true ] && [ "$flag_val" = "false" ]; then
        echo ""
        if gum confirm "All ${name} packages are installed. Enable ${flag} in chezmoi.toml?"; then
            update_chezmoi_flag "$flag" "true"
            if gum confirm "Apply dotfiles now?"; then
                chezmoi apply --force
                print_success "Dotfiles applied"
            fi
        fi
    fi

    # Offer to enable services
    local services
    services=$(parse_services "$file")
    if [ -n "$services" ]; then
        local stopped_services=()
        while IFS= read -r svc; do
            [ -z "$svc" ] && continue
            if ! systemctl is-enabled "$svc" &>/dev/null; then
                stopped_services+=("$svc")
            fi
        done <<< "$services"

        if [ ${#stopped_services[@]} -gt 0 ]; then
            echo ""
            print_info "Associated services not enabled: ${stopped_services[*]}"
            if gum confirm "Enable these services?"; then
                for svc in "${stopped_services[@]}"; do
                    enable_service "$svc"
                done
            fi
        fi
    fi
}

# ── Remove flow ──────────────────────────────────────────────────────────────

show_remove() {
    local file
    file=$(choose_group "Remove packages from group") || return

    local name group_id
    name=$(get_group_name "$file")
    group_id=$(get_group_id "$file")
    load_descriptions "$file"

    # Build list of installed packages
    local removable=()
    local pkg
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        if is_group_package_installed "$pkg" "$file"; then
            removable+=("$(format_package "$pkg")")
        fi
    done < <(get_group_packages "$file")

    if [ ${#removable[@]} -eq 0 ]; then
        print_info "No packages from ${name} are currently installed"
        return
    fi

    print_info "Select packages to remove from ${name} (tab to select, enter to confirm):"
    local selected
    selected=$(printf '%s\n' "${removable[@]}" | gum filter --no-limit \
        --header "Packages to remove:" \
        --placeholder "Type to filter...") || {
        echo "Cancelled."
        return
    }

    if [ -z "$selected" ]; then
        print_info "No packages selected"
        return
    fi

    # Extract package names
    local to_remove=()
    while IFS= read -r line; do
        to_remove+=("$(extract_package_name "$line")")
    done <<< "$selected"

    # Separate distro packages from custom_install packages
    local distro_to_remove=()
    local custom_to_remove=()
    for pkg in "${to_remove[@]}"; do
        if is_custom_install_pkg "$file" "$pkg"; then
            custom_to_remove+=("$pkg")
        else
            distro_to_remove+=("$pkg")
        fi
    done

    local remove_args=()
    for pkg in "${distro_to_remove[@]}"; do
        remove_args+=("$(normalize_package_name_for_system "$pkg")")
    done

    echo ""
    print_warning "Will remove: ${to_remove[*]}"
    if [ ${#custom_to_remove[@]} -gt 0 ]; then
        print_warning "Custom packages (${custom_to_remove[*]}) must be removed manually"
    fi
    if ! gum confirm "Proceed with removal?"; then
        echo "Cancelled."
        return
    fi

    if [ ${#remove_args[@]} -gt 0 ]; then
        remove_packages "${remove_args[@]}"
    fi

    # Check if any group packages remain installed
    local any_installed=false
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        if is_group_package_installed "$pkg" "$file"; then
            any_installed=true
            break
        fi
    done < <(get_group_packages "$file")

    # Offer to disable chezmoi flag if no group packages remain
    local flag flag_val
    flag=$(get_chezmoi_flag "$group_id")
    flag_val=$(get_chezmoi_flag_value "$flag")

    if [ "$any_installed" = false ] && [ "$flag_val" = "true" ]; then
        echo ""
        if gum confirm "No ${name} packages remain installed. Disable ${flag} in chezmoi.toml?"; then
            update_chezmoi_flag "$flag" "false"
            if gum confirm "Apply dotfiles now?"; then
                chezmoi apply --force
                print_success "Dotfiles applied"
            fi
        fi
    fi

    # Offer to disable services
    local services
    services=$(parse_services "$file")
    if [ -n "$services" ]; then
        local active_services=()
        while IFS= read -r svc; do
            [ -z "$svc" ] && continue
            if systemctl is-enabled "$svc" &>/dev/null; then
                active_services+=("$svc")
            fi
        done <<< "$services"

        if [ ${#active_services[@]} -gt 0 ] && [ "$any_installed" = false ]; then
            echo ""
            print_info "Associated services still enabled: ${active_services[*]}"
            if gum confirm "Disable these services?"; then
                for svc in "${active_services[@]}"; do
                    disable_service "$svc"
                done
            fi
        fi
    fi
}

# ── Unified manage view ──────────────────────────────────────────────────────

# Build an in-memory set of every installed package (one query, not one per
# package). Populates the global INSTALLED_SET associative array.
build_installed_index() {
    declare -gA INSTALLED_SET=()
    local pkg
    while IFS= read -r pkg; do
        [ -n "$pkg" ] && INSTALLED_SET["$pkg"]=1
    done < <(list_installed_packages)
}

# Build the installed index and the catalogue JSON together, so the whole scan
# (including the package-manager query) runs under one spinner. Used via
# spin_capture; INSTALLED_SET stays local to that background pass.
_scan_manage_catalogue() {
    build_installed_index
    build_manage_json
}

# Emit the whole package catalogue as a single JSON object for tree_select.py,
# tagging each package with its current installed state. Packages are
# de-duplicated across groups (first group wins). Relies on INSTALLED_SET.
build_manage_json() {
    local -A pkg_seen=()
    local first_group=true
    printf '{"mode":"manage","title":"Manage packages","groups":['

    local file
    for file in "$GROUPS_DIR"/*.yaml; do
        [ -f "$file" ] || continue

        local group_id name icon
        group_id=$(get_group_id "$file")

        # Skip groups whose required hardware is absent (e.g. biometric with no
        # fingerprint reader), using the same gate the installer consults so the
        # manage view matches what was actually installable on this machine.
        if ! group_hardware_available "$file"; then
            continue
        fi

        name=$(get_group_name "$file")
        icon=$(get_group_icon "$file")
        load_descriptions "$file"

        # Custom-install names for this group (one yq call, not one per package).
        local -A custom_set=()
        local cn
        while IFS= read -r cn; do
            [ -n "$cn" ] && custom_set["$cn"]=1
        done < <(parse_custom_install_names "$file" "$DISTRO_FAMILY")

        local items=()
        local pkg
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            [ -n "${pkg_seen[$pkg]:-}" ] && continue
            pkg_seen["$pkg"]=1

            local installed=false is_custom=false
            if [ -n "${custom_set[$pkg]:-}" ]; then
                is_custom=true
                is_custom_install_installed "$file" "$pkg" && installed=true
            else
                local norm
                norm=$(normalize_package_name_for_system "$pkg")
                [ -n "${INSTALLED_SET[$norm]:-}" ] && installed=true
            fi

            items+=("{\"name\":\"$(_json_escape "$pkg")\",\"desc\":\"$(_json_escape "${DESCRIPTIONS[$pkg]:-}")\",\"installed\":${installed},\"selected\":${installed},\"custom\":${is_custom}}")
        done < <(get_group_packages "$file")

        [ ${#items[@]} -eq 0 ] && continue

        if $first_group; then first_group=false; else printf ','; fi
        printf '{"id":"%s","name":"%s","icon":"%s","packages":[' \
            "$(_json_escape "$group_id")" "$(_json_escape "$name")" "$(_json_escape "$icon")"
        local first_pkg=true it
        for it in "${items[@]}"; do
            if $first_pkg; then first_pkg=false; else printf ','; fi
            printf '%s' "$it"
        done
        printf ']}'
    done

    printf ']}'
}

# Interactive unified manager: one tree of all groups with installed packages
# pre-checked. Toggle anything, confirm the diff, and the changes are applied.
show_manage() {
    if ! command_exists gum; then
        print_error "gum is not installed. Run './manage.sh setup' first."
        return 1
    fi

    # tree_select.py needs python3; without it, fall back to the basic menus.
    if ! command_exists python3; then
        print_warning "python3 not found — using the basic add/remove menu."
        legacy_menu
        return
    fi

    print_header "Package Manager"

    # Scanning installed packages and parsing every group file takes a moment,
    # so show the standard spinner across the whole catalogue build.
    local json
    spin_capture json "Scanning installed packages..." _scan_manage_catalogue

    if [ -z "$json" ] || [[ "$json" != *'"id"'* ]]; then
        print_warning "No package groups found for $DISTRO_FAMILY"
        return
    fi

    local tsv
    tsv=$(printf '%s' "$json" | python3 "$DOTFILES_DIR/install/lib/tree_select.py") || {
        echo "Cancelled."
        return
    }

    if [ -z "$tsv" ]; then
        print_info "No changes — nothing to install or remove."
        return
    fi

    apply_manage_diff "$tsv"
}

# Apply the install/remove diff emitted by tree_select.py (manage mode).
# Each line is: op<TAB>group<TAB>package<TAB>custom(0|1).
apply_manage_diff() {
    local tsv="$1"
    local install_distro=() install_custom=() remove_distro=() remove_custom=()
    declare -A pkg_file=()
    declare -A affected_groups=()

    local op grp pkg custom
    while IFS=$'\t' read -r op grp pkg custom; do
        [ -z "$op" ] && continue
        pkg_file["$pkg"]="$GROUPS_DIR/${grp}.yaml"
        affected_groups["$grp"]=1
        case "$op" in
            install)
                if [ "$custom" = "1" ]; then install_custom+=("$pkg"); else install_distro+=("$pkg"); fi
                ;;
            remove)
                if [ "$custom" = "1" ]; then remove_custom+=("$pkg"); else remove_distro+=("$pkg"); fi
                ;;
        esac
    done <<< "$tsv"

    local n_install=$(( ${#install_distro[@]} + ${#install_custom[@]} ))
    local n_remove=$(( ${#remove_distro[@]} + ${#remove_custom[@]} ))

    if [ "$n_install" -eq 0 ] && [ "$n_remove" -eq 0 ]; then
        print_info "No changes — nothing to install or remove."
        return
    fi

    # ── Review screen ────────────────────────────────────────────────────────
    echo ""
    print_header "Review changes"
    if [ "$n_install" -gt 0 ]; then
        gum style --foreground 35 "  + Install (${n_install}):"
        printf '      %s\n' "${install_distro[@]}" "${install_custom[@]}" | grep -v '^[[:space:]]*$' || true
    fi
    if [ "$n_remove" -gt 0 ]; then
        gum style --foreground 196 "  - Remove (${n_remove}):"
        printf '      %s\n' "${remove_distro[@]}" "${remove_custom[@]}" | grep -v '^[[:space:]]*$' || true
    fi
    if [ ${#remove_custom[@]} -gt 0 ]; then
        print_warning "Custom-installed (${remove_custom[*]}) can't be auto-removed — remove them manually."
    fi
    echo ""

    if ! gum confirm "Apply these changes?"; then
        echo "Cancelled."
        return
    fi

    # ── Installs ─────────────────────────────────────────────────────────────
    if [ ${#install_distro[@]} -gt 0 ]; then
        install_packages "${install_distro[@]}"
    fi

    local pkg
    for pkg in "${install_custom[@]}"; do
        local file="${pkg_file[$pkg]}"
        local install_cmd requires_cmd
        install_cmd=$(parse_custom_install_cmd "$file" "$pkg")
        requires_cmd=$(parse_custom_install_requires "$file" "$pkg")
        if [ -n "$requires_cmd" ] && ! command_exists "$requires_cmd"; then
            print_warning "$requires_cmd not found — skipping $pkg"
            continue
        fi
        if [ -n "$install_cmd" ]; then
            install_curl_tool "$pkg" "$install_cmd" || print_warning "Failed to install $pkg"
        fi
    done

    # ── Removals ─────────────────────────────────────────────────────────────
    if [ ${#remove_distro[@]} -gt 0 ]; then
        local remove_args=()
        for pkg in "${remove_distro[@]}"; do
            remove_args+=("$(normalize_package_name_for_system "$pkg")")
        done
        remove_packages "${remove_args[@]}"
    fi

    # ── Sync chezmoi flags + services for every touched group ─────────────────
    local grp
    for grp in "${!affected_groups[@]}"; do
        sync_group_after_change "$GROUPS_DIR/${grp}.yaml"
    done

    print_success "Done."
}

# After packages change, offer to flip the group's chezmoi flag and toggle its
# services, matching how the installer treats a fully-present / absent group.
sync_group_after_change() {
    local file="$1"
    [ -f "$file" ] || return 0

    local group_id name
    group_id=$(get_group_id "$file")
    name=$(get_group_name "$file")

    local all_installed=true any_installed=false pkg
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        if is_group_package_installed "$pkg" "$file"; then
            any_installed=true
        else
            all_installed=false
        fi
    done < <(get_group_packages "$file")

    local flag flag_val
    flag=$(get_chezmoi_flag "$group_id")
    flag_val=$(get_chezmoi_flag_value "$flag")

    if [ "$all_installed" = true ] && [ "$flag_val" = "false" ]; then
        echo ""
        if gum confirm "All ${name} packages are installed. Enable ${flag} in chezmoi.toml?"; then
            update_chezmoi_flag "$flag" "true"
            if gum confirm "Apply dotfiles now?"; then
                chezmoi apply --force
                print_success "Dotfiles applied"
            fi
        fi
    elif [ "$any_installed" = false ] && [ "$flag_val" = "true" ]; then
        echo ""
        if gum confirm "No ${name} packages remain installed. Disable ${flag} in chezmoi.toml?"; then
            update_chezmoi_flag "$flag" "false"
            if gum confirm "Apply dotfiles now?"; then
                chezmoi apply --force
                print_success "Dotfiles applied"
            fi
        fi
    fi

    local services
    services=$(parse_services "$file")
    [ -z "$services" ] && return 0

    if [ "$all_installed" = true ]; then
        local stopped=() svc
        while IFS= read -r svc; do
            [ -z "$svc" ] && continue
            systemctl is-enabled "$svc" &>/dev/null || stopped+=("$svc")
        done <<< "$services"
        if [ ${#stopped[@]} -gt 0 ]; then
            echo ""
            print_info "Associated services not enabled: ${stopped[*]}"
            if gum confirm "Enable these services?"; then
                for svc in "${stopped[@]}"; do enable_service "$svc"; done
            fi
        fi
    elif [ "$any_installed" = false ]; then
        local active=() svc
        while IFS= read -r svc; do
            [ -z "$svc" ] && continue
            systemctl is-enabled "$svc" &>/dev/null && active+=("$svc")
        done <<< "$services"
        if [ ${#active[@]} -gt 0 ]; then
            echo ""
            print_info "Associated services still enabled: ${active[*]}"
            if gum confirm "Disable these services?"; then
                for svc in "${active[@]}"; do disable_service "$svc"; done
            fi
        fi
    fi
}

# ── Main menu ────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage: ./manage.sh packages [command]

Opens a unified manager: one searchable tree of every package group with the
packages you already have pre-checked. Toggle anything (Space), review the
install/remove diff, and apply.

Commands:
  manage      Open the unified package manager (default)
  add         Alias for the unified manager
  remove      Alias for the unified manager
  help        Show this help message
EOF
}

# Fallback for hosts without python3: the original split add/remove menu.
legacy_menu() {
    if ! command_exists gum; then
        print_error "gum is not installed. Run './manage.sh setup' first."
        exit 1
    fi

    while true; do
        print_header "Package Manager"

        local choice
        choice=$(printf '%s\n' "Add packages" "Remove packages" "Back" \
            | gum choose --cursor.foreground="212" --header "What would you like to do?") || break

        case "$choice" in
            "Add packages")     show_add ;;
            "Remove packages")  show_remove ;;
            "Back")             break ;;
        esac
    done
}

# ── CLI dispatch ─────────────────────────────────────────────────────────────

case "${1:-}" in
    add|remove|manage|"")   show_manage ;;
    help|--help|-h)         usage ;;
    *)                      usage ;;
esac
