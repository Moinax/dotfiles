#!/bin/bash
# Package Manager — add/remove packages from group definitions
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGES_DIR="$DOTFILES_DIR/packages"
GROUPS_DIR="$PACKAGES_DIR/groups"

# Source shared utilities
source "$DOTFILES_DIR/install/lib/common.sh"
source "$DOTFILES_DIR/install/lib/detect.sh"
source "$DOTFILES_DIR/install/lib/services.sh"

install_interrupt_trap

load_distro_lib || exit 1

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

# Update a chezmoi flag value and confirm it to the user
update_chezmoi_flag() {
    if [ ! -f "$CHEZMOI_CONF" ]; then
        print_warning "chezmoi.toml not found, skipping flag update"
        return 0
    fi
    chezmoi_data_set "$1" "$2"
    print_success "Updated $1 = $2 in chezmoi.toml"
}

# ── Package list helpers ─────────────────────────────────────────────────────

# Build a list of packages for a group on the current distro,
# filtered by install purpose (desktop/terminal).
# Outputs one package name per line.
get_group_packages() {
    local file="$1"
    local all_packages
    all_packages=$({ parse_packages "$file" "$DISTRO_FAMILY"; parse_custom_install_names "$file"; } \
        | grep -v "^$" || true)

    if [ -z "$all_packages" ]; then
        return
    fi

    # Filter desktop_only packages when in terminal mode
    if install_purpose_is terminal; then
        local desktop_only_list
        desktop_only_list=$(parse_desktop_only "$file")
        if [ -n "$desktop_only_list" ]; then
            grep -vxFf <(printf '%s\n' "$desktop_only_list") <<< "$all_packages" || true
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

# Check if a custom_install entry is installed using its check command.
# Returns 0 if installed, 1 otherwise. Returns 1 if not a custom_install package.
is_custom_install_pkg() {
    local file="$1" pkg="$2"
    local names
    names=$(parse_custom_install_names "$file" 2>/dev/null)
    echo "$names" | grep -qxF "$pkg"
}

is_group_package_installed() {
    local pkg="$1" file="${2:-}"
    if [ -n "$file" ] && is_custom_install_pkg "$file" "$pkg"; then
        is_custom_install_installed "$file" "$pkg"
    else
        # Strip an AUR-style "repo/" prefix for the system package query
        is_package_installed "${pkg#*/}"
    fi
}

# Install one custom_install package via its declared command. A missing
# "requires" prerequisite or a failed install warns and moves on (returns 0)
# so callers can keep processing the rest of their list.
install_custom_pkg() {
    local file="$1" pkg="$2"
    local install_cmd requires_cmd
    install_cmd=$(parse_custom_install_cmd "$file" "$pkg")
    requires_cmd=$(parse_custom_install_requires "$file" "$pkg")
    if [ -n "$requires_cmd" ] && ! command_exists "$requires_cmd"; then
        print_warning "$requires_cmd not found — skipping $pkg"
        return 0
    fi
    if [ -n "$install_cmd" ]; then
        install_curl_tool "$pkg" "$install_cmd" || print_warning "Failed to install $pkg"
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

    build_installed_index
    for file in "${group_files[@]}"; do
        local name icon installed=0 total=0
        name=$(get_group_name "$file")
        icon=$(get_group_icon "$file")

        local pkg state
        while IFS=$'\t' read -r pkg state; do
            total=$((total + 1))
            [ "$state" = true ] && installed=$((installed + 1))
        done < <(group_package_states "$file")

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

    local name
    name=$(get_group_name "$file")
    load_descriptions "$file"

    # Build list of NOT-installed packages
    build_installed_index
    local available=()
    local pkg state
    while IFS=$'\t' read -r pkg state; do
        [ "$state" = false ] && available+=("$(format_package "$pkg")")
    done < <(group_package_states "$file")

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
        install_custom_pkg "$file" "$pkg"
    done

    sync_group_after_change "$file"
}

# ── Remove flow ──────────────────────────────────────────────────────────────

show_remove() {
    local file
    file=$(choose_group "Remove packages from group") || return

    local name
    name=$(get_group_name "$file")
    load_descriptions "$file"

    # Build list of installed packages
    build_installed_index
    local removable=()
    local pkg state
    while IFS=$'\t' read -r pkg state; do
        [ "$state" = true ] && removable+=("$(format_package "$pkg")")
    done < <(group_package_states "$file")

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
        remove_args+=("${pkg#*/}")
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

    sync_group_after_change "$file"
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

# Emit "pkg<TAB>true|false" installed-state lines for every package in a group.
# Uses the batch INSTALLED_SET index (call build_installed_index first) and one
# custom-name parse per group, instead of forking yq + pacman per package.
group_package_states() {
    local file="$1"
    local -A custom_set=()
    local cn
    while IFS= read -r cn; do
        [ -n "$cn" ] && custom_set["$cn"]=1
    done < <(parse_custom_install_names "$file")

    local pkg installed
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        installed=false
        if [ -n "${custom_set[$pkg]:-}" ]; then
            is_custom_install_installed "$file" "$pkg" && installed=true
        elif [ -n "${INSTALLED_SET[${pkg#*/}]:-}" ]; then
            installed=true
        fi
        printf '%s\t%s\n' "$pkg" "$installed"
    done < <(get_group_packages "$file")
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
        done < <(parse_custom_install_names "$file")

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
            elif [ -n "${INSTALLED_SET[${pkg#*/}]:-}" ]; then
                installed=true
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
        print_error "gum is not installed. Run './dots setup' first."
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
        install_custom_pkg "${pkg_file[$pkg]}" "$pkg"
    done

    # ── Removals ─────────────────────────────────────────────────────────────
    if [ ${#remove_distro[@]} -gt 0 ]; then
        local remove_args=()
        for pkg in "${remove_distro[@]}"; do
            remove_args+=("${pkg#*/}")
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

    # Packages just changed — re-index once and scan the group in one pass
    # instead of forking yq + pacman per package.
    build_installed_index
    local all_installed=true any_installed=false pkg state
    while IFS=$'\t' read -r pkg state; do
        if [ "$state" = true ]; then
            any_installed=true
        else
            all_installed=false
        fi
    done < <(group_package_states "$file")

    local flag flag_val
    flag=$(get_chezmoi_flag "$group_id")
    flag_val=$(chezmoi_data_get "$flag")

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

# ── Sync ─────────────────────────────────────────────────────────────────────

# Base packages this machine should have: core (+ aur), plus the desktop
# sections unless this is a terminal-only install.
base_desired_packages() {
    local base_file="$PACKAGES_DIR/$DISTRO_FAMILY/base.yaml"
    [ -f "$base_file" ] || return 0
    parse_packages "$base_file" "core"
    parse_packages "$base_file" "aur"
    if ! install_purpose_is terminal; then
        parse_packages "$base_file" "desktop"
        parse_packages "$base_file" "desktop_aur"
    fi
}

# Scan base.yaml + enabled groups for packages missing on this machine.
# Emits one TSV line per miss: "distro<TAB>pkg" or "custom<TAB>pkg<TAB>file",
# so it can run under spin_capture (a subshell) and be parsed afterwards.
# Relies on the same batch INSTALLED_SET index as the manage view — one
# package-manager query for the whole scan, not one per package.
scan_missing_packages() {
    build_installed_index
    declare -A seen=()
    local pkg

    while IFS= read -r pkg; do
        if [ -z "$pkg" ] || [ -n "${seen[$pkg]:-}" ]; then continue; fi
        seen["$pkg"]=1
        [ -n "${INSTALLED_SET[${pkg#*/}]:-}" ] || printf 'distro\t%s\n' "$pkg"
    done < <(base_desired_packages)

    # Groups whose chezmoi flag is enabled
    local file
    for file in "$GROUPS_DIR"/*.yaml; do
        group_enabled "$file" || continue

        # Custom-install names for this group (one yq call, not one per package).
        local -A custom_set=()
        local cn
        while IFS= read -r cn; do
            [ -n "$cn" ] && custom_set["$cn"]=1
        done < <(parse_custom_install_names "$file")

        while IFS= read -r pkg; do
            if [ -z "$pkg" ] || [ -n "${seen[$pkg]:-}" ]; then continue; fi
            seen["$pkg"]=1
            if [ -n "${custom_set[$pkg]:-}" ]; then
                is_custom_install_installed "$file" "$pkg" \
                    || printf 'custom\t%s\t%s\n' "$pkg" "$file"
            else
                [ -n "${INSTALLED_SET[${pkg#*/}]:-}" ] || printf 'distro\t%s\n' "$pkg"
            fi
        done < <(get_group_packages "$file")
    done
}

# Install whatever base.yaml and the enabled groups define but this machine is
# missing — the "a package was added to the dotfiles" path, no full setup run.
do_sync() {
    local scan
    spin_capture scan "Scanning for missing packages..." scan_missing_packages

    local missing_distro=() missing_custom=()
    declare -A custom_src=()
    local kind pkg src
    while IFS=$'\t' read -r kind pkg src; do
        case "$kind" in
            distro) missing_distro+=("$pkg") ;;
            custom) missing_custom+=("$pkg"); custom_src["$pkg"]="$src" ;;
        esac
    done <<< "$scan"

    local n_missing=$(( ${#missing_distro[@]} + ${#missing_custom[@]} ))
    if [ "$n_missing" -eq 0 ]; then
        print_success "Everything in base.yaml and enabled groups is already installed"
        return 0
    fi

    print_header "Sync packages"
    print_info "Missing packages (${n_missing}):"
    printf '  %s\n' "${missing_distro[@]}" "${missing_custom[@]}"
    echo ""
    gum confirm "Install these packages?" || { echo "Cancelled."; return 0; }

    if [ ${#missing_distro[@]} -gt 0 ]; then
        install_packages "${missing_distro[@]}"
    fi

    for pkg in "${missing_custom[@]}"; do
        install_custom_pkg "${custom_src[$pkg]}" "$pkg"
    done

    print_success "Sync complete."
}

# ── Main menu ────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage: dots packages [command]

Opens a unified manager: one searchable tree of every package group with the
packages you already have pre-checked. Toggle anything (Space), review the
install/remove diff, and apply.

Commands:
  manage      Open the unified package manager (default)
  add         Alias for the unified manager
  remove      Alias for the unified manager
  sync        Install packages added to base.yaml / enabled groups but missing here
  help        Show this help message
EOF
}

# Fallback for hosts without python3: the original split add/remove menu.
legacy_menu() {
    if ! command_exists gum; then
        print_error "gum is not installed. Run './dots setup' first."
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
    sync)                   do_sync ;;
    help|--help|-h)         usage ;;
    *)                      usage ;;
esac
