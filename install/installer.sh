#!/bin/bash
# Main installer script with interactive prompts (curses tree selector + gum)
set -e

# Get script directory and dotfiles root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Args, before anything else is sourced or detected. Kept to the one flag the
# installer needs — everything else about a run is asked interactively — and
# parsed up here so `--help` costs nothing: `dots setup help` delegates straight
# to it, which is what keeps the help text from being written out twice.
# Set by --force: re-run the full installer on a machine that is already managed.
FORCE_SETUP=false
while [ $# -gt 0 ]; do
    case "$1" in
        --force|-f) FORCE_SETUP=true ;;
        help|--help|-h)
            cat <<'EOF'
Usage: dots setup [--force]

Runs the full interactive installer: picks the groups and packages for this
machine, installs them, and writes the chezmoi config.

On a machine that is already managed this refuses and points at 'dots update',
which carries the answers forward instead of re-asking them. --force reinstalls
from scratch anyway.
EOF
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

# Source library functions
source "$SCRIPT_DIR/lib/detect.sh"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/hyprvoice.sh"
source "$SCRIPT_DIR/lib/dns-encrypted.sh"
source "$SCRIPT_DIR/lib/login-wallpaper.sh"
source "$SCRIPT_DIR/lib/post-apply.sh"

# The prompt-heaviest script in the repo, and the last one still without this:
# gum exits 130 on Ctrl+C rather than dying from the signal, so a shell with no
# trap reads the interrupt as an answer and installs on regardless.
install_interrupt_trap

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
USER_SERVICES_TO_ENABLE=()
INSTALL_WARNINGS=()
# yaml-declared tools found already installed, so left untouched by the install
# phase. Collected for refresh_preinstalled_tools, which offers to move them to
# the current release once the dotfiles are applied.
PREINSTALLED_TOOLS=()
declare -A GROUP_PACKAGE_MODE=()
declare -A GROUP_CUSTOM_PACKAGE_LIST=()
HYPRVOICE_MODEL="small"
HYPRVOICE_PROVIDER="whisper-cpp"
INSTALL_PURPOSE="desktop"

# gum draws every prompt, yq parses every packages/ yaml. tools/setup.sh installs
# both before it execs this script, so the guard is for the direct invocation that
# skips it: a missing gum is loud on its own, but a missing yq is not — every
# parser would return nothing and the selector would offer an empty catalogue
# rather than fail. That silence is what the hand-rolled yq fallbacks used to
# cover; this is what replaces them.
check_prerequisites() {
    require_tools gum yq || exit 1
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

# Select setup purpose (desktop or terminal)
select_purpose() {
    echo ""
    gum style --foreground 212 --bold "What type of setup?"
    echo ""

    # Esc here used to fall through to the *) arm and silently start a full Desktop
    # install — the largest thing this script does, chosen by a keypress that means
    # "stop". The *) arm stays for a genuinely empty answer.
    local choice
    choose_or_abort choice --cursor.foreground="212" \
        "🖥️  Desktop — full desktop environment with GUI apps" \
        "⌨️  Terminal — CLI tools only (headless/server)" || true

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

# Decide, once per selector, whether the tree seeds from what is installed.
#
# A first install pre-checks everything — there is no history to read, and the
# point is to talk the catalogue down to what you want. A machine that already
# has a profile is the opposite situation: the tree opens on what is actually
# installed, so a re-run is a diff against reality instead of the whole
# catalogue offering itself again. That is what stopped `gaming` from coming
# back pre-checked on a laptop that has never wanted it.
#
# Unchecked, never hidden: setup is the only place that can turn a group back
# on, so a group or package you passed on has to stay visible and one Space away.
#
# Each selector calls this itself rather than sharing one call: the tree builds
# inside spin_capture's subshell, so its copy of the index dies with it.
_seed_installed_state() {
    SEED_FROM_INSTALLED=false
    machine_is_managed || return 0
    SEED_FROM_INSTALLED=true
    build_installed_index
}

# Whether a package opens the tree checked. Status, not output: both callers
# consume it immediately, and a command substitution here is a fork per package.
_pkg_starts_checked() {
    local group_file="$1" pkg="$2" is_custom="$3"
    $SEED_FROM_INSTALLED || return 0
    if [ "$is_custom" = true ]; then
        is_custom_install_installed "$group_file" "$pkg"
    else
        # `${pkg#*/}` drops a repo prefix (aur/foo): the index is keyed on bare
        # names, the yaml is not always.
        [ -n "${INSTALLED_SET[${pkg#*/}]:-}" ]
    fi
}

# Build JSON array of groups for tree_select.py
_build_tree_json() {
    local -A pkg_seen=()
    local first_group=true

    _seed_installed_state

    printf '['
    for group in "${SELECTED_GROUP_NAMES[@]}"; do
        local group_file="$DOTFILES_DIR/packages/groups/$group.yaml"
        [ -f "$group_file" ] || continue

        # One read for the icon, the name and the descriptions — four separate ones
        # (two of them a yq apiece) used to open every group here.
        load_group_meta "$group_file"
        local group_icon="$GROUP_ICON" group_label="$GROUP_NAME"
        [ -z "$group_label" ] && group_label="$group"
        local -A descs=()
        local _dk
        for _dk in "${!DESCRIPTIONS[@]}"; do descs["$_dk"]="${DESCRIPTIONS[$_dk]}"; done

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

            local desc name checked=false
            desc=$(_json_escape "${descs[$pkg]:-}")
            name=$(_json_escape "$pkg")
            _pkg_starts_checked "$group_file" "$pkg" false && checked=true
            pkg_json_items+=("{\"name\":\"$name\",\"desc\":\"$desc\",\"selected\":$checked}")
        done < <(parse_packages "$group_file" "$DISTRO_FAMILY")

        # Include custom_install entries (curl/script-installed tools)
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            [ -n "${pkg_seen[$pkg]}" ] && continue
            [ -n "${desktop_only_pkgs[$pkg]}" ] && continue
            pkg_seen["$pkg"]="$group"

            local desc name checked=false
            desc=$(_json_escape "${descs[$pkg]:-}")
            name=$(_json_escape "$pkg")
            _pkg_starts_checked "$group_file" "$pkg" true && checked=true
            pkg_json_items+=("{\"name\":\"$name\",\"desc\":\"$desc\",\"selected\":$checked}")
        done < <(parse_custom_install_names "$group_file")

        # Emit group JSON object
        if [ "$first_group" = true ]; then
            first_group=false
        else
            printf ','
        fi

        local esc_id esc_name esc_icon
        esc_id=$(_json_escape "$group")
        esc_name=$(_json_escape "$group_label")
        esc_icon=$(_json_escape "$group_icon")

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

# Build everything the selector needs in one pass so it can all run under a
# single spinner. Emits the per-group totals (pre-dedup, for mode detection) on
# the first line, then the tree JSON on the second:
#   line 1: "hyprland=31 development=19 ..."
#   line 2: <tree json>
_build_tree_payload() {
    local totals="" group
    for group in "${SELECTED_GROUP_NAMES[@]}"; do
        local group_file="$DOTFILES_DIR/packages/groups/$group.yaml"
        [ -f "$group_file" ] || continue
        # One read for both halves, and the same read the tree itself uses. The two
        # loops this replaces also skipped the desktop_only filter, so a terminal
        # install advertised a total one higher than the list underneath it could
        # show (development's cursor-bin); group_declared_packages applies the filter,
        # so the header now agrees with its own rows.
        local count=0 pkg
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && count=$((count + 1))
        done < <(group_declared_packages "$group_file")
        totals+="${group}=${count} "
    done
    printf '%s\n' "$totals"
    _build_tree_json
}

# Fallback: select packages using gum filter (flat list)
_select_packages_gum_fallback() {
    local -A pkg_seen=()
    local -A group_total=()
    local display_lines=()
    local preselected=()
    local -A line_to_pkg=()
    local -A line_to_group=()

    _seed_installed_state

    for group in "${SELECTED_GROUP_NAMES[@]}"; do
        local group_file="$DOTFILES_DIR/packages/groups/$group.yaml"
        [ -f "$group_file" ] || continue

        # One read for the icon, the name and the descriptions — four separate ones
        # (two of them a yq apiece) used to open every group here.
        load_group_meta "$group_file"
        local group_icon="$GROUP_ICON" group_label="$GROUP_NAME"
        [ -z "$group_label" ] && group_label="$group"
        local -A descs=()
        local _dk
        for _dk in "${!DESCRIPTIONS[@]}"; do descs["$_dk"]="${DESCRIPTIONS[$_dk]}"; done

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
        # Custom entries are collected into the same list, so remember which
        # names they were: their installed-state check is a different one.
        local -A custom_set=()
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && all_group_pkgs+=("$pkg") && custom_set["$pkg"]=1
        done < <(parse_custom_install_names "$group_file")

        for pkg in "${all_group_pkgs[@]}"; do
            # Skip desktop_only packages in terminal mode
            [ -n "${desktop_only_pkgs[$pkg]}" ] && continue
            pkg_count=$((pkg_count + 1))
            [ -n "${pkg_seen[$pkg]}" ] && continue
            pkg_seen["$pkg"]="$group"

            local desc="${descs[$pkg]:-}"
            local display_line is_custom=false
            [ -n "${custom_set[$pkg]:-}" ] && is_custom=true
            if [ -n "$desc" ]; then
                display_line="  $pkg: $desc"
            else
                display_line="  $pkg"
            fi
            display_lines+=("$display_line")
            _pkg_starts_checked "$group_file" "$pkg" "$is_custom" \
                && preselected+=("$display_line")
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
    if $SEED_FROM_INSTALLED; then
        print_info "What you already have is pre-selected. Check anything you want to add."
    else
        print_info "All packages are pre-selected. Deselect any you don't want."
    fi
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

    # Build the per-group totals (pre-dedup, for mode detection) and the tree
    # JSON in one spinner-covered pass, so the loader appears immediately after
    # the purpose prompt rather than after a second of silent yq parsing.
    # Blank line first so the loader isn't jammed against the purpose result,
    # matching the spacing the manage view gets from its print_header.
    local payload
    echo ""
    spin_capture payload "Loading packages..." _build_tree_payload

    local -A group_total=()
    local totals_line="${payload%%$'\n'*}"
    local tree_json="${payload#*$'\n'}"
    local kv
    for kv in $totals_line; do
        [ -n "$kv" ] && group_total["${kv%%=*}"]="${kv#*=}"
    done

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
            # The one prompt left as a raw `gum confirm`, on purpose: everywhere
            # else a cancel means "stop", but here stopping *is* the Yes answer, so
            # treating Esc as an abort would silently invert it into a yes.
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

    if confirm_or_abort "Proceed with installation?"; then
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

    # Parse and install AUR packages
    packages=()
    while IFS= read -r pkg; do
        [ -n "$pkg" ] && packages+=("$pkg")
    done < <(parse_packages "$base_file" "aur")

    if [ ${#packages[@]} -gt 0 ]; then
        install_packages "${packages[@]}" || track_warning "Some AUR packages failed to install"
    fi

    # Parse and install desktop-only AUR packages
    if [ "$INSTALL_PURPOSE" = "desktop" ]; then
        packages=()
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && packages+=("$pkg")
        done < <(parse_packages "$base_file" "desktop_aur")

        if [ ${#packages[@]} -gt 0 ]; then
            install_packages "${packages[@]}" || track_warning "Some desktop AUR packages failed to install"
        fi
    fi

    # Install desktop-only AppImage support (fuse2)
    if [ "$INSTALL_PURPOSE" = "desktop" ]; then
        install_appimage_support || track_warning "Failed to install AppImage support"
    fi

    print_success "Base packages installed"
}

# Install a packages/common.yaml `tools:` entry using the command the yaml
# declares, so the installer and 'dots update' (which re-runs the same
# command to refresh the tool) can't drift apart. A missing declaration warns
# rather than failing: every caller gates on the tool's own availability check.
install_common_tool() {
    local name="$1"
    local install_cmd
    install_cmd=$(parse_entry_field "$DOTFILES_DIR/packages/common.yaml" tools "$name" install)
    # Both outcomes leave the tool absent — callers only get here when it is
    # missing — so both withhold the anchor. A missing declaration is a repo bug
    # rather than a machine one, but the machine is still short a declared tool, and
    # the fix belongs in common.yaml where CLAUDE.md already requires the metadata.
    if [ -z "$install_cmd" ]; then
        track_warning "No install command declared for $name in packages/common.yaml"
        mark_sync_shortfall
        return 0
    fi
    install_curl_tool "$name" "$install_cmd" || {
        mark_sync_shortfall
        return 1
    }
}

# Install fnm and a Node.js LTS if missing. Idempotent, safe to call more than
# once. fnm's LTS is our npm provider — Arch's nodejs package ships without
# npm/npx — so npm-dependent custom installs (codex, hunk, global pnpm) need
# this to have run first.
ensure_node_toolchain() {
    # Called twice per run — from main() before group packages (so npm-based
    # custom installs work) and again from install_common_tools. The first
    # successful pass sets this flag; the second returns immediately instead of
    # re-spawning fnm to re-confirm what we already know.
    [ "${NODE_TOOLCHAIN_READY:-false}" = true ] && return 0

    if ! command_exists fnm; then
        install_common_tool fnm
        activate_fnm_node
    else
        print_info "fnm is already installed"
        # fnm itself, not the Node it manages: refreshing the version manager
        # moves nothing under the global npm packages, so it belongs in the
        # post-install refresh where `node (LTS)` deliberately does not.
        PREINSTALLED_TOOLS+=(fnm)
    fi

    # Ensure a Node.js version is actually installed — fnm can exist with no
    # versions (e.g. from a run that died before this step).
    if command_exists fnm; then
        activate_fnm_node
        if ! fnm ls | grep -q 'lts\|v[0-9]'; then
            print_info "Installing Node.js LTS via fnm..."
            if install_node_lts; then
                print_success "Node.js LTS installed via fnm"
            else
                track_warning "Failed to install Node.js LTS via fnm"
            fi
        else
            print_info "Node.js already installed via fnm"
        fi
    else
        track_warning "fnm unavailable — Node.js LTS not installed"
    fi

    NODE_TOOLCHAIN_READY=true
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

        # Parse package candidates (distro packages + custom_install)
        local all_packages=()
        local -A custom_install_names=()
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && all_packages+=("$pkg")
        done < <(parse_packages "$group_file" "$DISTRO_FAMILY")
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && all_packages+=("$pkg") && custom_install_names["$pkg"]=1
        done < <(parse_custom_install_names "$group_file")

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
                # `check` only asks whether the tool exists, never which version
                # it is — so this is also the only place that knows a refresh is
                # even worth offering later.
                PREINSTALLED_TOOLS+=("$pkg")
                continue
            fi

            # Install system prerequisites declared via requires_packages before
            # running the custom install command. Shared with install_custom_pkg
            # rather than inlined here: the two copies had already diverged on
            # whether to skip a dependency that is present, so a fresh install
            # invoked sudo pacman twice for the runtime both chat shells declare.
            install_custom_requires "$group_file" "$pkg" \
                || track_warning "Failed to install prerequisites for $pkg"

            # Skip if a hard-required command is still missing. No shortfall for
            # the same reason install_custom_pkg does not mark one: a toolchain the
            # machine has not got is not something this run fell short of.
            if [ -n "$requires_cmd" ] && ! command_exists "$requires_cmd"; then
                track_warning "$requires_cmd still unavailable — skipping $pkg"
                continue
            fi

            if [ -n "$install_cmd" ]; then
                # track_warning alone is not enough: it prints at the end of setup
                # but leaves SYNC_SHORTFALL false, so record_synced_state stamped the
                # anchor over the missing tool and no later delta ever re-offered it.
                install_curl_tool "$pkg" "$install_cmd" || {
                    track_warning "Failed to install $pkg"
                    mark_sync_shortfall
                }
            fi
        done

        if [ ${#distro_packages[@]} -eq 0 ] && [ ${#custom_packages[@]} -eq 0 ] && [ "$package_mode" != "skip" ]; then
            track_warning "No packages resolved for group $group"
        fi

        # Collect services to enable. Two plain reads rather than a tagged
        # single-read protocol: this loop already spends several yq calls per
        # group and four more per custom entry, so folding two of them saved
        # ~170ms of a multi-minute install and cost a second row format to
        # maintain alongside group_declared_lists.
        local service
        while IFS= read -r service; do
            [ -n "$service" ] && SERVICES_TO_ENABLE+=("$service")
        done < <(parse_services "$group_file")

        while IFS= read -r service; do
            [ -n "$service" ] && USER_SERVICES_TO_ENABLE+=("$service")
        done < <(parse_user_services "$group_file")
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
        install_common_tool zoxide
    else
        print_info "zoxide is already installed"
        PREINSTALLED_TOOLS+=(zoxide)
    fi

    # Install fnm + a Node.js LTS (idempotent). Also called earlier, before
    # group packages, so npm-based custom installs (e.g. codex) can run.
    ensure_node_toolchain

    # Ensure global npm packages (idempotent — also runs when fnm pre-exists).
    # The list and each package's install spec come from common.yaml's `tools:`
    # entries, so they stay in step with what 'dots update' checks.
    local npm_pkgs=()
    mapfile -t npm_pkgs < <(parse_entry_field_values "$common_file" tools npm)

    if [ ${#npm_pkgs[@]} -eq 0 ]; then
        print_info "No global npm packages declared in packages/common.yaml"
    elif command_exists npm; then
        print_info "Installing global npm packages (${npm_pkgs[*]})..."
        npm install -g "${npm_pkgs[@]}" || {
            track_warning "Failed to install global npm packages"
            mark_sync_shortfall
        }
    else
        # ensure_node_toolchain ran just above, so npm missing here is a failure of
        # this run, not a machine that never had node.
        track_warning "npm unavailable — skipped global npm packages (${npm_pkgs[*]})"
        mark_sync_shortfall
    fi

    # Setup hyprvoice (AI group)
    if group_selected ai; then
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
                # First-time setup: default to local when declined, but stop on a
                # cancel. Esc used to land on whisper-cpp and go on to install the
                # engine and a model — the install the user was trying to call off.
                # abort_interrupted has to run here, not in the helper: the helper
                # runs in a command substitution, where an exit ends the subshell only.
                local _provider_rc=0
                HYPRVOICE_PROVIDER=$(hyprvoice_choose_provider "Select transcription provider for dictation:") \
                    || _provider_rc=$?
                if [ "$_provider_rc" -eq 130 ]; then
                    abort_interrupted
                elif [ "$_provider_rc" -ne 0 ]; then
                    HYPRVOICE_PROVIDER="whisper-cpp"
                fi

                if [ "$HYPRVOICE_PROVIDER" = "whisper-cpp" ]; then
                    # Local provider: install the whisper.cpp engine on demand.
                    # It is deliberately kept out of the AI group's package list
                    # (see packages/groups/ai.yaml) so Groq users never pay for
                    # the CUDA toolkit + ggml-cuda-git compile.
                    if ! command_exists whisper-cli && ! command_exists whisper-cpp; then
                        print_info "Installing local whisper.cpp engine (may build against CUDA)..."
                        # install_optional_packages, not install_packages: the comment
                        # above is why it is in no yaml, so a failure here is not a
                        # declared package missing and must not withhold the anchor.
                        install_optional_packages whisper.cpp \
                            || track_warning "Failed to install whisper.cpp — local dictation will not work"
                    fi

                    # Local provider: select and download a whisper model
                    local models=()
                    mapfile -t models < <(hyprvoice_list_models)

                    if [ ${#models[@]} -gt 0 ]; then
                        models+=("Skip — download later")
                        # The list carries an explicit "Skip — download later", so Esc
                        # is a cancel, not a skip. Redirect rather than a pipe:
                        # choose_or_abort must run in this shell to be able to stop it.
                        choose_or_abort HYPRVOICE_MODEL \
                            --header "Select a whisper model for dictation:" \
                            <<< "$(printf '%s\n' "${models[@]}")" || HYPRVOICE_MODEL="Skip"
                        HYPRVOICE_MODEL="${HYPRVOICE_MODEL%% *}"
                    else
                        track_warning "Could not fetch model list from hyprvoice"
                        HYPRVOICE_MODEL="small"
                    fi

                    if [ "$HYPRVOICE_MODEL" != "Skip" ]; then
                        if ! hyprvoice_download_model "$HYPRVOICE_MODEL"; then
                            print_warning "Failed to download model — run 'hyprvoice model download $HYPRVOICE_MODEL' later"
                            HYPRVOICE_MODEL="small"
                        fi
                    else
                        HYPRVOICE_MODEL="small"
                    fi
                elif [ "$HYPRVOICE_PROVIDER" = "groq" ]; then
                    local _model_rc=0
                    HYPRVOICE_MODEL=$(hyprvoice_choose_groq_model) || _model_rc=$?
                    if [ "$_model_rc" -eq 130 ]; then
                        abort_interrupted
                    elif [ "$_model_rc" -ne 0 ]; then
                        HYPRVOICE_MODEL="${GROQ_WHISPER_MODELS[0]%% *}"
                    fi

                    if ! setup_groq_api_key; then
                        track_warning "No Groq API key provided — set GROQ_API_KEY later"
                    fi
                fi
            fi
        fi
    fi

    print_success "Common tools installed"
}

# Setup chezmoi and apply dotfiles
setup_dotfiles() {
    print_header "Setting Up Dotfiles"

    # Warn if running inside Hyprland session
    if [ -n "$HYPRLAND_INSTANCE_SIGNATURE" ]; then
        print_info "Running inside Hyprland session"
        print_info "You may see transient errors during config migration"
        print_info "The config is reloaded once the apply finishes"
    fi
    
    # Install chezmoi
    install_chezmoi
    
    # Determine which dotfiles to install based on selected groups
    local dotfiles_to_install=()
    
    # Always install base dotfiles
    dotfiles_to_install+=(
        "dot_zshrc"
        "dot_zsh"
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

    # One flag per group file, generated — never a list kept by hand here.
    # A hand-kept list is exactly how `biometric` and `security` came to be
    # installed on a machine whose chezmoi data recorded no flag for either:
    # they were added to packages/groups/ long after this block was written, so
    # the installer installed them and then said nothing about them. Every
    # `group_enabled` caller since — `dots packages sync`, the update delta, the
    # tool scan — read that silence as "disabled".
    # The same rule now covers the per-app flags of custom_install entries that
    # declare `chezmoi_flag: true` — vibewatch, and the two chat shells whose
    # launchers, .desktop files and icons chezmoi owns. Those were a hand-kept
    # list of three right here, thirty lines under the comment that says not to
    # keep one: adding a fourth app meant editing this file twice and
    # .chezmoiignore once, and forgetting any of them fails silently.
    local -a group_flags=()
    local group_file group_id enabled entry
    for group_file in "$DOTFILES_DIR"/packages/groups/*.yaml; do
        [ -f "$group_file" ] || continue
        group_id=$(get_group_id "$group_file")
        enabled=false
        group_selected "$group_id" && enabled=true
        group_flags+=("    $(get_chezmoi_flag "$group_id") = $enabled")

        while IFS= read -r entry; do
            [ -n "$entry" ] || continue
            enabled=false
            custom_entry_selected "$group_id" "$entry" && enabled=true
            group_flags+=("    $(get_chezmoi_flag "$entry") = $enabled")
        done < <(parse_custom_install_flag_entries "$group_file")
    done

    local has_hyprlock_fingerprint="false"
    if [ "$HAS_FINGERPRINT" = "true" ] && group_selected biometric && command_exists fprintd-enroll; then
        has_hyprlock_fingerprint="true"
    fi

    # Settings the setup flow never asks about (dark_mode via the theme
    # toggle) must survive re-runs: carry over existing values, defaulting
    # only when absent.
    local dark_mode="dark" existing_val
    if [ -f "$chezmoi_config" ]; then
        existing_val=$(grep -m1 -oP '^\s*dark_mode\s*=\s*"\K[^"]+' "$chezmoi_config" || true)
        [ -n "$existing_val" ] && dark_mode="$existing_val"
    fi

    cat > "$chezmoi_config" << EOF
# Use this repo's home directory as chezmoi source (so 'chezmoi diff' etc. work without -S)
sourceDir = "$source_dir"

[data]
    distro = "$DISTRO"
$(printf '%s\n' "${group_flags[@]}")
    has_fingerprint = $has_hyprlock_fingerprint
    hyprvoice_model = "$HYPRVOICE_MODEL"
    hyprvoice_provider = "$HYPRVOICE_PROVIDER"
    install_purpose = "$INSTALL_PURPOSE"
    dark_mode = "$dark_mode"
EOF
    
    print_info "Chezmoi config created at $chezmoi_config"
    print_info "Applying dotfiles from $source_dir..."

    # chezmoi_apply, not apply_dotfiles: main runs run_post_apply itself, after
    # refresh_preinstalled_tools, so waybar restarts after the binaries its
    # modules run rather than before.
    chezmoi_apply
}

# Offer to move the tools the install phase found already present. Runs after
# the dotfiles apply, not before: group_enabled reads the chezmoi data that
# setup_dotfiles has only just written, so a filtered scan started earlier would
# find no enabled group and quietly report nothing to do.
refresh_preinstalled_tools() {
    [ ${#PREINSTALLED_TOOLS[@]} -gt 0 ] || return 0

    local updater="$DOTFILES_DIR/tools/manage-updates.sh"
    [ -x "$updater" ] || return 0

    # 130 means the user stopped the child at one of its prompts (gum sends no
    # signal on Esc, so our own trap never fires). Swallowing it as a warning
    # carried on with the rest of the install; see update_tools in sync-machine.sh.
    local rc=0
    "$updater" refresh "${PREINSTALLED_TOOLS[@]}" || rc=$?
    if [ "$rc" -eq 130 ]; then
        exit 130
    elif [ "$rc" -ne 0 ]; then
        track_warning "Some tools could not be refreshed — run 'dots update' to retry"
    fi
}

# Open LocalSend's port on ufw when the productivity group (which ships
# localsend-bin) is installed and ufw is present. Port 53317 carries both the
# TCP file transfers and the UDP multicast announcements — without the UDP hole
# peers only show up as raw IPs instead of by device name. ufw persists rules to
# /etc/ufw and skips duplicates, so this is safe to re-run on every apply.
configure_localsend_firewall() {
    if ! group_selected productivity; then
        return 0
    fi
    if ! command_exists ufw; then
        return 0
    fi

    print_info "Opening LocalSend port 53317 (tcp+udp) on ufw..."
    # `ufw allow` applies to the live ruleset immediately when the firewall
    # is active (and just persists when inactive) — no reload needed.
    sudo ufw allow 53317/tcp comment 'LocalSend transfer'  > /dev/null
    sudo ufw allow 53317/udp comment 'LocalSend discovery' > /dev/null
    print_success "LocalSend firewall rules ensured (53317 tcp+udp)"
}

# Seed the desktop's dark/light mode on a machine that has never had one set.
#
# Only the state file is checked. This used to also re-run when any of the active
# theme copies was missing, but `run_post_apply` above now syncs all of them
# through theme-copies.sh, so by this point a copy is missing only when its
# managed source is — which re-running the script would not fix either. Dropping
# that half also drops what was a fourth hand-maintained copy of the surface list
# (already stale: it listed four of the six).
apply_dark_mode_defaults() {
    local state_file="$HOME/.local/share/dark-light-mode"
    local script="$HOME/.local/bin/apply-dark-mode.sh"

    if [ ! -x "$script" ]; then
        return 0
    fi

    if [ -f "$state_file" ]; then
        print_info "Dark/light mode already configured, skipping"
        return 0
    fi

    print_info "Applying dark mode theme..."
    "$script" dark > /dev/null
    print_success "Theme applied (dark mode)"
}

# NVIDIA note: no driver installation or tuning happens here on purpose.
# CachyOS ships its own NVIDIA stack (prebuilt nvidia-open modules for the
# cachyos kernels, modeset defaults, suspend/resume services) — the dotfiles
# deliberately leave it untouched so the stock behavior can be evaluated.

# Enable services
enable_selected_services() {
    # base.yaml's own services, which no group declares — the bluetooth stack is
    # baseline rather than a group's business. Collected here rather than beside
    # the group walk because that walk only runs over *selected* groups, and
    # these are owed to the machine whatever it selected.
    local service
    while IFS= read -r service; do
        [ -n "$service" ] && SERVICES_TO_ENABLE+=("$service")
    done < <(base_desired_services "$DOTFILES_DIR/packages")

    if [ ${#SERVICES_TO_ENABLE[@]} -eq 0 ] && [ ${#USER_SERVICES_TO_ENABLE[@]} -eq 0 ]; then
        return 0
    fi

    print_header "Enabling Services"

    source "$SCRIPT_DIR/lib/services.sh"

    # Two lists rather than one sniffed from the unit name: nothing in
    # `vicinae.service` says which systemd instance owns it, and guessing wrong
    # means either a sudo prompt for a unit root cannot see, or a system unit
    # silently enabled in the user instance. The dedupe is shared.
    for_each_service enable_service      "${SERVICES_TO_ENABLE[@]}"
    for_each_service enable_user_service "${USER_SERVICES_TO_ENABLE[@]}"

    # Add user to docker group if development is selected
    if group_selected development; then
        add_user_to_group "docker"
    fi

    # Add user to input group for swayosd caps-lock detection (Hyprland)
    if group_selected hyprland; then
        add_user_to_group "input"
    fi

    # Configure Tailscale if development is selected and tailscale is installed.
    # The tailscaled daemon is enabled above (needed for the manual toggle), but
    # Tailscale itself is NOT auto-connected — connect on demand via the waybar
    # module or the Super+Ctrl+N keybind (toggle-tailscale.sh).
    if group_selected development && command -v tailscale &>/dev/null; then
        print_info "Setting Tailscale operator to $USER"
        sudo tailscale set --operator="$USER"

        # MagicDNS on, and it is a requirement rather than a taste: the remote
        # T3 Code host is reached at its `*.ts.net` name because that is what its
        # TLS certificate is issued for, so a 100.x address cannot stand in for
        # it (`dots droplet`, docs/adr/0002).
        #
        # This was --accept-dns=false for a long time, to stop tailscaled taking
        # over system DNS. Measured on 1.102.2 that fear does not apply to this
        # tailnet: it declares no global resolvers, so tailscale0 only claims
        # `*.ts.net` and the 100.x reverse zones as routing domains and every
        # other lookup still goes through NetworkManager. The other half of the
        # old rationale — a stale server-less route left after `down` breaking
        # resolution — does not reproduce either: the leftover link has
        # `Current Scopes: none` and resolved skips it, lookups answering in
        # ~10ms with Tailscale down.
        tailscale set --accept-dns=true
        print_success "Tailscale operator set; MagicDNS enabled"

        # Authenticate once if needed, then leave Tailscale DISCONNECTED so it
        # never comes up automatically at boot.
        if ! tailscale status &>/dev/null; then
            print_info "Logging into Tailscale (a browser/URL will open for authentication)..."
            tailscale up
            tailscale down
            print_info "Authenticated. Tailscale left disconnected — toggle it via the waybar module or Super+Ctrl+N."
        else
            tailscale down 2>/dev/null || true
            print_info "Tailscale already authenticated; left disconnected (connect manually)."
        fi
    fi

    print_success "Services enabled"
}

# Trim services that gate the system graphical.target so uwsm can launch the
# compositor sooner after display-manager login.
#
# Diagnosed via `systemd-analyze critical-chain`:
#   graphical.target @25.6s
#     └─multi-user.target @25.6s
#       └─docker.service @20.7s +4.9s
#         └─network-online.target @20.7s
#           └─NetworkManager-wait-online.service @5.4s +15.3s
#
# Net result: ~12s of black screen between login and Hyprland appearing.
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
# LocalSocket; the daemon won't start until these are fixed. We then enable
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

    local freshclam_conf=/etc/clamav/freshclam.conf
    local clamd_conf=/etc/clamav/clamd.conf
    local freshclam_svc=clamav-freshclam.service
    local clamd_svc=clamav-daemon.service

    sudo sed -i '/^Example[[:space:]]*$/d' "$freshclam_conf" "$clamd_conf"
    sudo sed -i '0,/^#[[:space:]]*LocalSocket[[:space:]]/s//LocalSocket /' "$clamd_conf"

    # Apply tmpfiles.d so /run/clamav exists before starting the daemon —
    # otherwise it fails until first reboot.
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
    elif confirm_or_abort "Enroll a fingerprint now?"; then
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
    # Detect before prompting, like the enrollment step above: the answer is already
    # on disk on a re-run, so asking again is noise the user can only answer wrong.
    local sysauth_file=/etc/pam.d/system-local-login
    [ -f /etc/pam.d/system-auth ] && sysauth_file=/etc/pam.d/system-auth
    if grep -q 'pam_fprintd.so' "$sysauth_file" 2>/dev/null; then
        print_info "pam_fprintd already configured in $sysauth_file"
    elif confirm_or_abort "Enable fingerprint for system auth (login, sudo, polkit, Bitwarden)?"; then
        print_info "Adding pam_fprintd.so to $sysauth_file"
        sudo cp "$sysauth_file" "${sysauth_file}.bak.$(date +%s)"
        sudo sed -i '0,/^auth/s//auth      sufficient   pam_fprintd.so\n&/' "$sysauth_file"
        print_success "PAM fingerprint enabled (backup: ${sysauth_file}.bak.*)"
    fi

    # hyprlock restarts fingerprint verification the instant logind emits
    # PrepareForSleep(false) on resume. The stock fprintd action is
    # allow_active=yes / allow_inactive=no, and the session is not yet marked
    # active that early in the resume — so polkit denies VerifyStart with
    # "Not Authorized: net.reactivated.fprint.device.verify", hyprlock logs a
    # warning and never retries, leaving fingerprint dead for the rest of that
    # lock (password fallback only). It only misfires when hyprlock still held
    # the sensor at suspend time and so skips the Claim round-trip on resume —
    # without that extra latency it beats logind to the punch. Hence the
    # intermittency. Granting verify to the local user regardless of
    # session-active state removes the race. Scoped to verify: enroll and
    # setusername keep their auth prompts.
    local fprint_rule=/etc/polkit-1/rules.d/49-fprintd-verify.rules
    if [ -f "$fprint_rule" ] && ! head -n1 "$fprint_rule" | grep -q '^// Installed by the dotfiles installer'; then
        print_info "$(basename "$fprint_rule") is hand-authored — leaving as is"
    else
        print_info "Installing polkit rule for fingerprint verify on resume"
        sudo mkdir -p /etc/polkit-1/rules.d
        sudo tee "$fprint_rule" >/dev/null <<RULEEOF
// Installed by the dotfiles installer (setup_biometric).
// Without this, fingerprint silently stops working at the hyprlock screen
// after a suspend/resume cycle — see the comment in install/installer.sh.
polkit.addRule(function(action, subject) {
    if (action.id == "net.reactivated.fprint.device.verify" &&
        subject.local && subject.user == "$USER") {
        return polkit.Result.YES;
    }
});
RULEEOF
        sudo chmod 644 "$fprint_rule"
        print_success "$fprint_rule installed"
    fi

    # The plasmalogin override below runs its auth phase through password-auth
    # instead of system-auth, where pam_fprintd sits before pam_unix — so a
    # password typed at the greeter would otherwise wait out the fprintd
    # timeout before falling through. (hyprlock had the same problem; it now
    # gets its own self-contained stack further down, for a second reason.)
    # `password-auth` is a Fedora/RHEL PAM name that does not exist on Arch —
    # generate it as system-auth minus pam_fprintd so the include below
    # resolves. A dangling include makes every pam_authenticate fail
    # instantly, locking you out of the greeter. The file is derived state, and
    # system-auth changes at arbitrary times (pambase .pacnew merges, manual
    # edits) long after this installer ran — so the regeneration lives in a
    # systemd path unit watching system-auth, not here. The service only
    # rewrites a file it generated (header-prefix check), so a hand-authored
    # password-auth is never clobbered. No $ or backslash in the ExecStart
    # shell: systemd would expand/escape them.
    if [ -f /etc/pam.d/system-auth ]; then
        print_info "Installing pam-password-auth systemd path unit"
        sudo tee /etc/systemd/system/pam-password-auth.service >/dev/null <<'UNIT'
[Unit]
Description=Regenerate /etc/pam.d/password-auth from system-auth (minus fprintd)
# Installed by the dotfiles installer (setup_biometric); hyprlock's PAM stack
# includes password-auth for an instant, fprintd-free password fallback.

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'if [ ! -f /etc/pam.d/password-auth ] || head -n1 /etc/pam.d/password-auth | grep -q "^# Generated from system-auth"; then { echo "# Generated from system-auth — do not edit; regenerated automatically by pam-password-auth.service."; sed "/pam_fprintd[.]so/d" /etc/pam.d/system-auth; } > /etc/pam.d/.password-auth.tmp && mv /etc/pam.d/.password-auth.tmp /etc/pam.d/password-auth; fi'

# Enabled directly (besides the path-unit trigger) so every boot re-runs the
# generation once: a password-auth that went missing self-heals instead of
# leaving the hyprlock/plasmalogin includes dangling (instant auth failure).
# Boot-time self-heal must NOT live in the path unit as PathExists= — that
# condition stays true after the oneshot exits, so systemd re-triggers it in
# a loop until the start limit kills the path unit.
[Install]
WantedBy=multi-user.target
UNIT
        sudo tee /etc/systemd/system/pam-password-auth.path >/dev/null <<'UNIT'
[Unit]
Description=Keep /etc/pam.d/password-auth in sync with system-auth

[Path]
PathChanged=/etc/pam.d/system-auth

[Install]
WantedBy=multi-user.target
UNIT
        sudo systemctl daemon-reload
        sudo systemctl enable --now pam-password-auth.path >/dev/null
        # enable: boot-time self-heal; --now: initial generation (also
        # refreshes a file stamped by earlier versions of this setup — their
        # headers share the prefix).
        sudo systemctl enable --now pam-password-auth.service >/dev/null
        print_success "password-auth generated and kept in sync with system-auth"
    fi

    # hyprlock gets a self-contained auth stack rather than an include, because
    # it must contain neither pam_fprintd nor pam_faillock:
    #
    #   pam_fprintd — a typed password would wait out the fingerprint timeout
    #   (~10s) before pam_unix ever sees it. Fingerprint at the lockscreen is
    #   handled by hyprlock natively over D-Bus (auth.fingerprint in
    #   hyprlock.conf), independently of this stack.
    #
    #   pam_faillock — hyprlock races the PAM password conversation against
    #   that D-Bus fingerprint check and aborts the conversation when the
    #   fingerprint wins. pam_unix then returns "conversation failed", which
    #   faillock's authfail branch records as a failed login — so every
    #   SUCCESSFUL fingerprint unlock increments the tally. At the stock
    #   deny=3 fail_interval=900, three unlocks inside 15 minutes lock the
    #   account for unlock_time (600s), taking sudo, TTY login and this
    #   screen's own password fallback down with it. A screen locker is a
    #   local-presence unlock; faillock buys nothing here and self-DoSes
    #   instead, so it stays in the greeter and login stacks only.
    #
    # Deriving this from system-auth with a sed was the obvious alternative and
    # is a trap: deleting the three pam_faillock lines shifts the [success=N]
    # jump counts on pam_systemd_home and pam_unix, and a miscounted jump in an
    # auth stack fails open. Hand-authored and auditable beats generated here.
    # Only `account` includes system-auth, which pambase always ships — so that
    # include cannot dangle.
    local pam_file=/etc/pam.d/hyprlock ts
    ts=$(date +%s)
    if [ -f "$pam_file" ] && ! head -n2 "$pam_file" | grep -q '^# Installed by the dotfiles installer'; then
        sudo cp "$pam_file" "${pam_file}.bak.${ts}"
        print_info "Backed up $pam_file to ${pam_file}.bak.${ts}"
    fi
    print_info "Installing hyprlock PAM stack (no fprintd, no faillock)"
    sudo tee "$pam_file" >/dev/null <<'PAMEOF'
#%PAM-1.0
# Installed by the dotfiles installer — hyprlock's own auth stack.
# Deliberately not an include of login/system-auth/password-auth: it must carry
# neither pam_fprintd (a typed password would wait out the fingerprint timeout)
# nor pam_faillock (hyprlock records a PAM failure on every SUCCESSFUL
# fingerprint unlock, which locks the account after three of them). See
# setup_biometric in install/installer.sh for the full reasoning.

-auth      [success=1 default=ignore]  pam_systemd_home.so
auth       required                    pam_unix.so          try_first_pass nullok
auth       required                    pam_env.so

account    include                     system-auth
PAMEOF
    print_success "$pam_file installed"

    # Same fprintd-timeout problem at the login screen: the Plasma Login
    # Manager's vendor stack (/usr/lib/pam.d/plasmalogin) includes
    # system-login → system-auth, where pam_fprintd sits before pam_unix — the
    # password typed at the greeter waits out the fingerprint timeout (~25s)
    # before pam_unix consumes it. PAM reads /etc/pam.d before /usr/lib/pam.d,
    # so drop an override whose auth phase goes through password-auth
    # (system-login's own auth preamble inlined); account/password/session
    # mirror the vendor stack, keeping the kwallet/keyring hooks so the wallet
    # still auto-unlocks from the typed password. Header check as above: a
    # hand-authored override is never clobbered.
    local plasma_pam=/etc/pam.d/plasmalogin
    if [ -f /usr/lib/pam.d/plasmalogin ] && [ -f /etc/pam.d/password-auth ]; then
        if [ -f "$plasma_pam" ] && ! head -n2 "$plasma_pam" | grep -q '^# Installed by the dotfiles installer'; then
            print_info "$(basename "$plasma_pam") is a hand-authored override — leaving as is"
        else
            print_info "Overriding plasmalogin PAM to skip fprintd timeout on password"
            sudo tee "$plasma_pam" >/dev/null <<'PAMEOF'
#%PAM-1.0
# Installed by the dotfiles installer — overrides /usr/lib/pam.d/plasmalogin.
# auth runs through password-auth (system-auth minus pam_fprintd) so the
# password typed at the greeter authenticates instantly instead of waiting
# out the fingerprint timeout. The two lines above the include are a frozen
# copy of system-login's auth preamble (nothing keeps them in sync — deliberate
# for a login stack); the other phases include system-login and track it.

auth        required    pam_shells.so
auth        requisite   pam_nologin.so
auth        include     password-auth
-auth       optional    pam_gnome_keyring.so
-auth       optional    pam_kwallet5.so

account     include     system-login

password    include     system-login
-password   optional    pam_gnome_keyring.so    use_authtok

session     optional    pam_keyinit.so          force revoke
session     include     system-login
-session    optional    pam_gnome_keyring.so    auto_start
-session    optional    pam_kwallet5.so         auto_start
PAMEOF
            print_success "$plasma_pam installed"
        fi
    fi

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
SSH_KEY_FILE="$HOME/.ssh/id_ed25519"

setup_ssh() {
    print_header "SSH Key Setup"

    if [ -f "$SSH_KEY_FILE" ]; then
        print_info "SSH key already exists"
        return 0
    fi

    local opt_restore="Restore from backup (private GitHub repo)"
    local opt_generate="Generate a new SSH key"
    local choice
    # "Skip" is on the menu, so Esc is a cancel rather than a skip.
    choose_or_abort choice --cursor.foreground="212" --header "No SSH key found:" \
        <<< "$(printf '%s\n' "$opt_restore" "$opt_generate" "Skip")" || true

    case "$choice" in
        "$opt_restore")
            if ! restore_ssh_from_backup; then
                if confirm_or_abort "Generate a new SSH key instead?"; then
                    generate_ssh_key
                fi
            fi
            ;;
        "$opt_generate")
            generate_ssh_key
            ;;
    esac
}

generate_ssh_key() {
    local ssh_dir="${SSH_KEY_FILE%/*}"

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    echo ""
    local passphrase
    passphrase=$(gum input --password --placeholder "Enter passphrase (or leave empty)") || true

    ssh-keygen -t ed25519 -f "$SSH_KEY_FILE" -N "$passphrase"
    chmod 600 "$SSH_KEY_FILE"
    SSH_KEY_GENERATED=true

    print_success "SSH key generated"
    echo ""
    gum style --foreground 39 "Public key:"
    cat "$SSH_KEY_FILE.pub"
    echo ""
    print_info "Add this key to your GitHub/GitLab account"
}

# Restore ~/.ssh (and the other home secrets) from the encrypted projects
# backup. Bootstrap for the auth chicken-and-egg: gh's OAuth device flow works
# over HTTPS with no SSH key, so the only secrets needed on a fresh machine
# are the GitHub login and the age passphrase.
restore_ssh_from_backup() {
    if ! command_exists gh; then
        print_info "Installing GitHub CLI..."
        # Optional: fetched because this step needs gh, not because a yaml asked
        # for it. The development group installs its own copy and marks that.
        install_optional_packages github-cli || {
            print_error "Failed to install GitHub CLI"
            return 1
        }
    fi

    if ! gh auth status &>/dev/null; then
        print_info "Authenticating with GitHub via browser device flow (no SSH key needed)..."
        # --git-protocol https so gh can clone the backup repo without a key
        gh auth login --hostname github.com --git-protocol https --web || {
            print_error "GitHub authentication failed"
            return 1
        }
    fi

    "$DOTFILES_DIR/tools/backup-projects.sh" restore --home-only || return 1

    if [ ! -f "$SSH_KEY_FILE" ]; then
        print_warning "Backup restored, but it contained no $SSH_KEY_FILE"
        return 1
    fi
    SSH_KEY_RESTORED=true
    print_success "SSH key restored from backup"
}

# The installer's framing over install/lib/dns-encrypted.sh (`dots update`'s is
# reconcile_encrypted_dns in tools/sync-machine.sh). Not gated on the install
# purpose — unlike the wallpaper below, which is desktop-only: a headless box
# resolves names too, and the lib skips itself where systemd-resolved or
# NetworkManager is absent. Unconditional, since setup has no state to reconcile
# against and re-running costs two file writes and a daemon reload.
setup_encrypted_dns() {
    print_header "Encrypted DNS"
    # A failure is already tracked as a warning by apply_encrypted_dns, and must
    # not abort the install over a resolver — the machine still has the one the
    # network handed it.
    apply_encrypted_dns || return 0
}

# The installer's framing over install/lib/login-wallpaper.sh — the lib holds the
# mechanism, each caller frames it (dots update's framing is
# reconcile_login_wallpaper in tools/sync-machine.sh). Unconditional, since setup
# has no state to reconcile against and re-running the steps costs one
# `install -d` and two config writes.
setup_login_wallpaper() {
    print_header "Login Wallpaper"
    # A failure is already tracked as a warning by apply_login_wallpaper, and must
    # not abort the install over a wallpaper.
    apply_login_wallpaper || return 0
}

# Setup Plymouth boot splash screen (CachyOS usually ships Plymouth
# preconfigured — the check below skips setup when it's already in place)
setup_plymouth() {
    # Skip if Plymouth is already installed and configured
    if command_exists plymouth-set-default-theme \
        && grep -qE '^HOOKS=.*\bplymouth\b' /etc/mkinitcpio.conf 2>/dev/null; then
        print_info "Plymouth is already configured"
        PLYMOUTH_CONFIGURED=true
        return
    fi

    echo ""
    if ! confirm_or_abort "Set up Plymouth boot splash screen?"; then
        return
    fi

    print_header "Plymouth Setup"

    # Install plymouth
    print_info "Installing Plymouth..."
    # Declared in no yaml — setup installs it directly — so a failure is reported
    # here and does not withhold the sync anchor.
    install_optional_packages plymouth || {
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
    choose_or_abort theme --header "Select Plymouth theme" \
        <<< "$(printf '%s\n' "${themes[@]}")" || true

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

    PLYMOUTH_CONFIGURED=true
    print_success "Plymouth configured (theme: $theme)"
}

# Setup shell
setup_shell() {
    print_header "Shell Setup"
    
    local zsh_path
    zsh_path=$(which zsh) || true
    
    if [ -z "$zsh_path" ]; then
        print_error "zsh not found"
        return 1
    fi
    
    if [ "$SHELL" = "$zsh_path" ]; then
        print_info "zsh is already the default shell"
        return 0
    fi
    
    if confirm_or_abort "Change default shell to zsh?"; then
        chsh -s "$zsh_path"
        SHELL_CHANGED=true
        print_success "Default shell changed to zsh"
        print_info "Log out and back in for changes to take effect"
    fi
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

    if [ "$SSH_KEY_GENERATED" = true ]; then
        steps+=("  $next_step. Add your SSH key to GitHub/GitLab")
        next_step=$((next_step + 1))
    fi

    if [ "$SSH_KEY_RESTORED" = true ]; then
        steps+=("  $next_step. Run 'dots backup restore' to re-clone ~/Projects")
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
    # chezmoi just put the manager on PATH; the shell that ran ./dots setup
    # picked up its PATH before that, so it takes a new shell to see it.
    body+=("" "This manager is now on PATH as 'dots' — run it from anywhere" \
              "(new shell required), with tab-completion in zsh.")
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
    USER_SERVICES_TO_ENABLE=()
    PLYMOUTH_CONFIGURED=false
    NODE_TOOLCHAIN_READY=false
    SHELL_CHANGED=false
    SSH_KEY_GENERATED=false
    SSH_KEY_RESTORED=false
    unset GROUP_PACKAGE_MODE GROUP_CUSTOM_PACKAGE_LIST
    declare -gA GROUP_PACKAGE_MODE=()
    declare -gA GROUP_CUSTOM_PACKAGE_LIST=()

    # An already-managed machine has a cheaper, safer path: `dots update` moves
    # it to the current repo without re-asking the questions it already answered
    # (and without a full catalogue that has to be talked back down every time).
    # Setup stays reachable behind --force, because a from-scratch reinstall is
    # a real thing to want.
    if machine_is_managed && ! $FORCE_SETUP; then
        print_header "Already Set Up"
        local synced
        synced=$(profile_get SYNCED_COMMIT)
        print_info "This machine has been through the installer${synced:+ (last synced at ${synced:0:8})}."
        print_info "To bring it in line with the repo, run:  dots update"
        echo ""
        print_warning "To reinstall from scratch anyway: dots setup --force"
        return 0
    fi

    HAS_FINGERPRINT=false
    if has_fingerprint_reader; then
        HAS_FINGERPRINT=true
        print_info "Fingerprint reader detected"
    fi

    # Check for gum
    check_prerequisites
    
    # Welcome (displays the detected distro; support is already hard-gated
    # by setup.sh and the distros/ check above)
    show_welcome

    # Select setup purpose (desktop or terminal)
    select_purpose

    # Auto-populate groups based on purpose and go straight to package filter
    local groups_dir="$DOTFILES_DIR/packages/groups"
    shopt -s nullglob
    local group_files=("$groups_dir"/*.yaml)
    shopt -u nullglob
    mapfile -t group_files < <(printf '%s\n' "${group_files[@]}" | sort | grep -v '^$')
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
        # Skip groups whose required hardware is absent (e.g. biometric with no
        # fingerprint reader). Bitwarden itself lives in 'security' now, so
        # it still installs without one.
        if ! group_hardware_available "$group_file"; then
            continue
        fi
        SELECTED_GROUP_NAMES+=("$group_name")
    done
    select_group_packages
    
    # Confirm and install
    confirm_installation
    
    # Run installation steps
    # A failed system upgrade (e.g. an AUR build error or a held/pinned-package
    # conflict) must not abort the whole installer under `set -e` — otherwise we
    # never reach the package installs below. Warn and continue.
    update_system || track_warning "System update failed; continuing with package installation"
    install_base_packages
    # Bootstrap Node/npm before group packages so npm-based custom installs
    # (e.g. codex in the development group) can run on a fresh machine.
    ensure_node_toolchain
    install_group_packages
    install_common_tools
    setup_dotfiles
    refresh_preinstalled_tools
    # No file list: a full install has no "before" to diff against, so every
    # reconciliation runs.
    run_post_apply
    if [ "$INSTALL_PURPOSE" = "desktop" ]; then
        configure_localsend_firewall
        apply_dark_mode_defaults
    fi
    enable_selected_services
    tune_boot_performance
    setup_clamav
    setup_biometric
    setup_encrypted_dns
    if [ "$INSTALL_PURPOSE" = "desktop" ]; then
        setup_login_wallpaper
        setup_plymouth
    fi
    setup_ssh
    setup_shell

    # Only now, with every step behind us: the marker is what tells setup not to
    # run again and what `dots update` diffs against, so a run that died earlier
    # must not have left one. It also declines by itself if a declared package did
    # not land — an anchor written over a shortfall tells every later delta those
    # packages were dealt with, so they would never be offered again.
    record_synced_state
    if sync_shortfall; then
        track_warning "No sync anchor written: some declared packages are missing"
        print_info "Fix them ('dots packages sync'), then 'dots update' anchors this machine"
    fi

    # Done!
    show_completion
}

# Run main
main
