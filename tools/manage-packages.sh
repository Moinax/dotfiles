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
source "$DOTFILES_DIR/install/lib/post-apply.sh"

install_interrupt_trap

load_distro_lib || exit 1

# ── YAML helpers ─────────────────────────────────────────────────────────────

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

# Whether a package name is one of a group's custom_install entries.
#
# Memoised per file because the callers ask per *package*: the two apply flows and
# is_group_package_installed below all loop over a selection, and the read behind
# this is 65ms, so a 20-package apply spent 1.3s re-deriving one file's answer. The
# cache lives for the run, which is safe here — nothing in this tool writes a group
# yaml (packages are installed and removed on the machine; group flags go to
# chezmoi.toml), so a file's custom_install list cannot change under us.
declare -A _CUSTOM_NAMES=()
is_custom_install_pkg() {
    local file="$1" pkg="$2"
    if [ -z "${_CUSTOM_NAMES[$file]+set}" ]; then
        _CUSTOM_NAMES["$file"]=$'\n'"$(parse_custom_install_names "$file" 2>/dev/null)"$'\n'
    fi
    # "$pkg" is quoted inside the pattern so its own glob characters stay literal;
    # the surrounding newlines keep this an exact whole-name match, as grep -qxF was.
    [[ "${_CUSTOM_NAMES[$file]}" == *$'\n'"$pkg"$'\n'* ]]
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
        # One read for the name, the icon and the rows the states are counted from.
        load_group_meta "$file"
        name="$GROUP_NAME"
        icon="$GROUP_ICON"

        local pkg state
        while IFS=$'\t' read -r pkg state; do
            total=$((total + 1))
            [ "$state" = true ] && installed=$((installed + 1))
        done < <(group_package_states "$file" "$GROUP_ROWS")

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
    load_group_meta "$file"
    name="$GROUP_NAME"

    # Build list of NOT-installed packages
    build_installed_index
    local available=()
    local pkg state
    while IFS=$'\t' read -r pkg state; do
        [ "$state" = false ] && available+=("$(format_package "$pkg")")
    done < <(group_package_states "$file" "$GROUP_ROWS")

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
    if ! confirm_or_abort "Proceed with installation?"; then
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

    # Guarded for the reason do_sync's call is: under `set -e` a bare failure here
    # would skip the custom_install loop and sync_group_after_change below it.
    if [ ${#distro_packages[@]} -gt 0 ]; then
        install_packages "${distro_packages[@]}" \
            || print_warning "Some packages could not be installed"
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
    load_group_meta "$file"
    name="$GROUP_NAME"

    # Build list of installed packages
    build_installed_index
    local removable=()
    local pkg state
    while IFS=$'\t' read -r pkg state; do
        [ "$state" = true ] && removable+=("$(format_package "$pkg")")
    done < <(group_package_states "$file" "$GROUP_ROWS")

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
        warn_custom_uninstall "${custom_to_remove[@]}"
    fi
    if ! confirm_or_abort "Proceed with removal?"; then
        echo "Cancelled."
        return
    fi

    if [ ${#remove_args[@]} -gt 0 ]; then
        remove_packages "${remove_args[@]}"
    fi

    sync_group_after_change "$file"
}

# ── Unified manage view ──────────────────────────────────────────────────────

# Emit "pkg<TAB>true|false" installed-state lines for every package in a group.
# Uses the batch INSTALLED_SET index (call build_installed_index first) and takes
# the custom flag from group_declared_packages, which already worked it out — the
# separate parse_custom_install_names this used to do was a second yq over the
# same file, per group, on a path the user waits at behind a spinner.
group_package_states() {
    local file="$1" rows="${2:-}"
    local pkg flag installed
    while IFS=$'\t' read -r pkg flag; do
        [ -z "$pkg" ] && continue
        installed=false
        if [ -n "$flag" ]; then
            is_custom_install_installed "$file" "$pkg" && installed=true
        elif [ -n "${INSTALLED_SET[${pkg#*/}]:-}" ]; then
            installed=true
        fi
        printf '%s\t%s\n' "$pkg" "$installed"
        # A caller that already read the file (load_group_meta) passes its rows in,
        # so the whole view costs one yq per group instead of one per question.
    done < <(if [ -n "$rows" ]; then classify_declared_rows <<< "$rows"
             else group_declared_packages "$file"; fi)
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
        # Cheap enough to keep ahead of the read: requires_hardware is grepped, not
        # parsed, so an absent-hardware group costs no yq at all.
        if ! group_hardware_available "$file"; then
            continue
        fi

        # Name, icon, descriptions and the package rows out of ONE read of the file.
        load_group_meta "$file"
        name="$GROUP_NAME"
        icon="$GROUP_ICON"

        local items=()
        local pkg flag
        while IFS=$'\t' read -r pkg flag; do
            [ -z "$pkg" ] && continue
            [ -n "${pkg_seen[$pkg]:-}" ] && continue
            pkg_seen["$pkg"]=1

            local installed=false custom=false
            if [ -n "$flag" ]; then
                custom=true
                is_custom_install_installed "$file" "$pkg" && installed=true
            elif [ -n "${INSTALLED_SET[${pkg#*/}]:-}" ]; then
                installed=true
            fi

            items+=("{\"name\":\"$(_json_escape "$pkg")\",\"desc\":\"$(_json_escape "${DESCRIPTIONS[$pkg]:-}")\",\"installed\":${installed},\"selected\":${installed},\"custom\":${custom}}")
        done < <(classify_declared_rows <<< "$GROUP_ROWS")

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
        warn_custom_uninstall "${remove_custom[@]}"
    fi
    echo ""

    if ! confirm_or_abort "Apply these changes?"; then
        echo "Cancelled."
        return
    fi

    # ── Installs ─────────────────────────────────────────────────────────────
    # Guarded: under `set -e` a bare failure here would abandon the removals and the
    # group-flag/service reconciliation below, leaving the yaml and the machine
    # disagreeing about what the user just applied.
    if [ ${#install_distro[@]} -gt 0 ]; then
        install_packages "${install_distro[@]}" \
            || print_warning "Some packages could not be installed"
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
    load_group_meta "$file"
    name="$GROUP_NAME"

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
    done < <(group_package_states "$file" "$GROUP_ROWS")

    local flag flag_val
    flag=$(get_chezmoi_flag "$group_id")
    flag_val=$(chezmoi_data_get "$flag")

    # confirm_or_abort matters most on these two: the answer is written to
    # chezmoi.toml, so a cancel read as "no" would record the flag against a
    # machine whose packages say the opposite — and the next apply would then
    # template the configs for a group it has, or drop the ones it no longer has.
    if [ "$all_installed" = true ] && [ "$flag_val" = "false" ]; then
        echo ""
        if confirm_or_abort "All ${name} packages are installed. Enable ${flag} in chezmoi.toml?"; then
            update_chezmoi_flag "$flag" "true"
            if confirm_or_abort "Apply dotfiles now?"; then
                apply_dotfiles
            fi
        fi
    elif [ "$any_installed" = false ] && [ "$flag_val" = "true" ]; then
        echo ""
        if confirm_or_abort "No ${name} packages remain installed. Disable ${flag} in chezmoi.toml?"; then
            update_chezmoi_flag "$flag" "false"
            if confirm_or_abort "Apply dotfiles now?"; then
                apply_dotfiles
            fi
        fi
    fi

    local services user_services
    services=$(parse_services "$file")
    user_services=$(parse_user_services "$file")
    [ -z "$services" ] && [ -z "$user_services" ] && return 0

    if [ "$all_installed" = true ]; then
        local stopped=() user_stopped=()
        mapfile -t stopped      < <(services_with_state system no <<< "$services")
        mapfile -t user_stopped < <(services_with_state user   no <<< "$user_services")

        # One merged list for the prompt, two for the verbs. Interpolating the
        # halves side by side ("${stopped[*]} ${user_stopped[*]}") printed the
        # separator whether or not both were populated, and the commonest case is
        # one of them empty — hyprland declares bluetooth, normally already
        # enabled, plus vicinae — so the line read "not enabled:  vicinae.service".
        local missing=("${stopped[@]}" "${user_stopped[@]}")
        if [ ${#missing[@]} -gt 0 ]; then
            echo ""
            print_info "Associated services not enabled: ${missing[*]}"
            if confirm_or_abort "Enable these services?"; then
                for_each_service enable_service      "${stopped[@]}"
                for_each_service enable_user_service "${user_stopped[@]}"
            fi
        fi
    elif [ "$any_installed" = false ]; then
        local active=() user_active=()
        mapfile -t active      < <(services_with_state system yes <<< "$services")
        mapfile -t user_active < <(services_with_state user   yes <<< "$user_services")

        local leftover=("${active[@]}" "${user_active[@]}")
        if [ ${#leftover[@]} -gt 0 ]; then
            echo ""
            print_info "Associated services still enabled: ${leftover[*]}"
            if confirm_or_abort "Disable these services?"; then
                for_each_service disable_service      "${active[@]}"
                for_each_service disable_user_service "${user_active[@]}"
            fi
        fi
    fi
}

# ── Sync ─────────────────────────────────────────────────────────────────────

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
    local file rows
    for file in "$GROUPS_DIR"/*.yaml; do
        group_enabled "$file" || continue

        # One read, classified twice — group_declared_packages is this same yq
        # call and throws the prerequisite rows away.
        rows=$(group_declared_lists "$file")

        # The custom flag comes off the row rather than from a second read: the rows
        # classify_declared_rows returns carry it in field 2, so the extra
        # parse_custom_install_names pass this used to do was a 65ms yq per group
        # spent re-deriving what was in hand.
        local flag
        while IFS=$'\t' read -r pkg flag; do
            if [ -z "$pkg" ] || [ -n "${seen[$pkg]:-}" ]; then continue; fi
            seen["$pkg"]=1
            if [ -n "$flag" ]; then
                is_custom_install_installed "$file" "$pkg" \
                    || printf 'custom\t%s\t%s\n' "$pkg" "$file"
            else
                [ -n "${INSTALLED_SET[${pkg#*/}]:-}" ] || printf 'distro\t%s\n' "$pkg"
            fi
        done < <(printf '%s\n' "$rows" | classify_declared_rows)

        # A custom entry's prerequisites are missing-and-declared exactly like any
        # other package, and the entry's own `check` will never say so: the two
        # chat shells check for a launcher chezmoi puts there, so they read as
        # installed with or without the PyQt6 their launcher imports. Reported as
        # distro packages because that is what pacman installs them as.
        while IFS= read -r pkg; do
            if [ -z "$pkg" ] || [ -n "${seen[$pkg]:-}" ]; then continue; fi
            seen["$pkg"]=1
            [ -n "${INSTALLED_SET[${pkg#*/}]:-}" ] || printf 'distro\t%s\n' "$pkg"
        done < <(printf '%s\n' "$rows" | selected_requires_packages)
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
    confirm_or_abort "Install these packages?" || { echo "Cancelled."; return 0; }

    # Guarded: a bare failing install_packages is what `set -e` exits the whole
    # script on, which left the custom_install loop below unrun and printed no
    # explanation — in the very command the installer points users at to repair a
    # shortfall. install_packages has already marked it and said what failed.
    if [ ${#missing_distro[@]} -gt 0 ]; then
        install_packages "${missing_distro[@]}" \
            || print_warning "Some packages could not be installed"
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
