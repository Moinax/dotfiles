#!/bin/bash
# Dotfiles Management Script — single entry point for all dotfiles operations
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared utilities
source "$SCRIPT_DIR/install/lib/common.sh"
source "$SCRIPT_DIR/install/lib/hyprvoice.sh"

install_interrupt_trap

# ── Helpers ──────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage: ./manage.sh [command]

Commands:
  packages    Manage packages (add/remove from groups, sync missing)
  apps        Manage standalone apps (AppImage / Distrobox)
  reconfig    Reconfigure chezmoi data flags
  whisper     Update whisper model for hyprvoice dictation
  setup       Run full installer (bootstrap + interactive setup)
  gaming      Gaming helpers (HDR launch string for Steam)
  backup      Backup/restore ~/Projects secrets (encrypted, manifest-based)
  lazy-lock   Sync nvim lazy-lock.json back to dotfiles source
  help        Show this help message

Run without arguments for an interactive menu.
EOF
}

# ── Actions ──────────────────────────────────────────────────────────────────

do_setup() {
    "$SCRIPT_DIR/tools/setup.sh"
}

do_whisper() {
    if ! command_exists hyprvoice; then
        print_error "hyprvoice is not installed"
        return 1
    fi

    local current_provider current_model
    current_provider=$(chezmoi_data_get 'hyprvoice_provider')
    current_model=$(chezmoi_data_get 'hyprvoice_model')
    : "${current_provider:=whisper-cpp}"

    # Choose provider
    local provider
    provider=$(hyprvoice_choose_provider "Select transcription provider (current: $current_provider):") || {
        echo "Cancelled."
        return
    }

    local chosen=""
    if [ "$provider" = "whisper-cpp" ]; then
        # Mark the currently configured model in the list
        local models=()
        local entry name
        while IFS= read -r entry; do
            name="${entry%% -*}"
            name="${name%% *}"
            if [ "$name" = "$current_model" ] && [ "$provider" = "$current_provider" ]; then
                models+=("$entry (current)")
            else
                models+=("$entry")
            fi
        done < <(hyprvoice_list_models)

        if [ ${#models[@]} -eq 0 ]; then
            print_error "No whisper models found"
            return 1
        fi

        chosen=$(printf '%s\n' "${models[@]}" | gum choose --cursor.foreground="212" \
            --header "Select whisper model:") || {
            echo "Cancelled."
            return
        }

        # Strip " (current)" suffix and description to get model name
        chosen="${chosen% (current)}"
        chosen="${chosen%% -*}"
        chosen="${chosen%% *}"

        hyprvoice_download_model "$chosen" || {
            print_error "Failed to download model '$chosen'"
            return 1
        }
    elif [ "$provider" = "groq" ]; then
        chosen=$(hyprvoice_choose_groq_model) || {
            echo "Cancelled."
            return
        }

        setup_groq_api_key --allow-change
    fi

    if [ "$chosen" = "$current_model" ] && [ "$provider" = "$current_provider" ]; then
        print_info "Provider '$provider' with model '$chosen' is already the current configuration"
        return
    fi

    chezmoi_data_set "hyprvoice_provider" "$provider"
    chezmoi_data_set "hyprvoice_model" "$chosen"
    print_success "Updated hyprvoice config in chezmoi.toml (provider=$provider, model=$chosen)"

    print_info "Re-applying hyprvoice config..."
    chezmoi apply --force ~/.config/hyprvoice

    # Offer to clean up local models when switching to a cloud provider
    if [ "$provider" != "whisper-cpp" ]; then
        local model_dir="$HOME/.local/share/hyprvoice/models/whisper"
        local model_size
        model_size=$(du -sh "$model_dir" 2>/dev/null | cut -f1) || true
        if [ -n "$model_size" ]; then
            if gum confirm "Remove local whisper models to free up ${model_size}?"; then
                rm -f "$model_dir"/*.bin
                print_success "Local whisper models removed (freed ${model_size})"
            fi
        fi
    fi

    whisper_restart_daemon
}

whisper_restart_daemon() {
    local action="Starting"
    if hyprvoice status 2>/dev/null | grep -q "status="; then
        action="Restarting"
        hyprvoice stop &>/dev/null || true
        sleep 1
    fi
    print_info "$action hyprvoice daemon..."
    hyprvoice serve &>/dev/null &
    disown
    for _ in $(seq 1 10); do
        sleep 0.5
        hyprvoice status 2>/dev/null | grep -q "status=" && break
    done
    print_success "Hyprvoice daemon ${action,,}ed"
}

do_reconfig() {
    if [ ! -f "$CHEZMOI_CONF" ]; then
        print_error "chezmoi.toml not found at $CHEZMOI_CONF"
        print_info "Run the full installer first: ./manage.sh setup"
        return 1
    fi

    print_header "Reconfigure Chezmoi Data"

    # Read boolean flags from [data] section
    local flags=()
    local in_data=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[data\] ]]; then
            in_data=true
            continue
        fi
        if $in_data; then
            # Stop at next section
            [[ "$line" =~ ^\[.+\] ]] && break
            # Match boolean flags like: install_hyprland = true
            if [[ "$line" =~ ^[[:space:]]*([a-z_]+)[[:space:]]*=[[:space:]]*(true|false) ]]; then
                local key="${BASH_REMATCH[1]}"
                local val="${BASH_REMATCH[2]}"
                flags+=("$key = $val")
            fi
        fi
    done < "$CHEZMOI_CONF"

    if [ ${#flags[@]} -eq 0 ]; then
        print_warning "No boolean flags found in [data] section"
        return
    fi

    # Show current flags, let user select which to toggle. A fixed boolean list
    # is a checkbox picker, not a fuzzy search — gum choose is the right widget
    # and, unlike gum filter, reacts to ESC instantly (no text-input escape
    # disambiguation), so cancelling returns to the menu without a lag.
    print_info "Select flags to toggle (space to select, enter to confirm):"
    local selected
    selected=$(printf '%s\n' "${flags[@]}" \
        | gum choose --no-limit --cursor.foreground="212" --header "Toggle flags:") || {
        echo "Cancelled."
        return
    }

    if [ -z "$selected" ]; then
        print_info "No flags selected"
        return
    fi

    # Toggle each selected flag
    while IFS= read -r entry; do
        local key="${entry%% =*}"
        local val="${entry##*= }"
        local new_val
        if [ "$val" = "true" ]; then
            new_val="false"
        else
            new_val="true"
        fi
        chezmoi_data_set "$key" "$new_val"
        print_info "Toggled $key: $val → $new_val"
    done <<< "$selected"

    print_success "Flags updated in chezmoi.toml"

    # Offer to apply immediately
    if gum confirm "Apply dotfiles now?"; then
        print_info "Applying dotfiles..."
        chezmoi apply --force
        print_success "Dotfiles applied"
    fi
}

do_packages() {
    "$SCRIPT_DIR/tools/manage-packages.sh" "$@"
}

# Everything package-shaped under one submenu: the unified add/remove manager,
# the "install what the dotfiles gained" sync, and standalone apps.
do_packages_menu() {
    while true; do
        local options=()
        options+=("Add / remove packages")
        options+=("Sync missing packages")
        if install_purpose_is desktop; then
            options+=("Standalone apps (AppImage / Distrobox)")
        fi
        options+=("Back")

        local choice
        choice=$(printf '%s\n' "${options[@]}" | gum choose --cursor.foreground="212" --header "Packages:") || break

        case "$choice" in
            "Add / remove packages")   do_packages || true ;;
            "Sync missing packages")   do_packages sync || true; pause_for_user ;;
            "Standalone apps (AppImage / Distrobox)") do_apps || true ;;
            "Back")                    break ;;
        esac
    done
}

# Distrobox availability is NOT checked here: only some apps subcommands need
# it, and the tool gates those itself (require_distrobox).
do_apps() {
    if ! install_purpose_is desktop; then
        print_error "External apps helper is only available for desktop installs"
        return 1
    fi

    "$SCRIPT_DIR/tools/manage-external-apps.py" "$@"
}

do_gaming() {
    # Only HDR-launch for now; dispatch on subcommand so it can grow later.
    case "${1:-hdr-launch}" in
        hdr-launch) "$SCRIPT_DIR/tools/gaming-hdr-launch.sh" ;;
        *)
            print_error "Unknown gaming subcommand: $1"
            print_info "Available: hdr-launch"
            return 1
            ;;
    esac
}

do_backup() {
    "$SCRIPT_DIR/tools/backup-projects.sh" "$@"
}

do_lazy_lock() {
    local src="$HOME/.config/nvim/lazy-lock.json"
    local dest="$SCRIPT_DIR/home/dot_config/nvim/lazy-lock.json"

    if [[ ! -f "$src" ]]; then
        print_error "No lazy-lock.json found at $src"
        return 1
    fi

    cp "$src" "$dest"
    print_success "Synced lazy-lock.json to dotfiles source"
    print_info "Review with 'git diff' and commit when ready"
}

# ── Interactive menu ─────────────────────────────────────────────────────────

do_menu() {
    if ! command_exists gum; then
        print_error "gum is not installed. Run './manage.sh setup' first or install gum manually."
        exit 1
    fi

    # HDR availability doesn't change mid-session — probe once (the gaming
    # script owns the detection via --check), not on every menu redraw.
    local has_hdr=false
    if "$SCRIPT_DIR/tools/gaming-hdr-launch.sh" --check 2>/dev/null; then
        has_hdr=true
    fi

    while true; do
        print_header "Dotfiles Manager"

        # Build menu options dynamically
        local options=()
        options+=("Setup")
        options+=("Manage packages")
        options+=("Reconfigure flags")
        if command_exists hyprvoice; then
            options+=("Update whisper model")
        fi
        if $has_hdr; then
            options+=("Gaming HDR launch")
        fi
        options+=("Backup projects")
        options+=("Exit")

        local choice
        choice=$(printf '%s\n' "${options[@]}" | gum choose --cursor.foreground="212" --header "What would you like to do?") || break

        # A child tool returning non-zero (e.g. missing dependency, user
        # cancelled inside it) must not kill the menu — swallow it here.
        case "$choice" in
            "Setup")                   do_setup || true ;;
            "Manage packages")         do_packages_menu || true ;;
            "Reconfigure flags")       do_reconfig || true ;;
            "Update whisper model")    do_whisper || true ;;
            "Gaming HDR launch")       do_gaming || true ;;
            "Backup projects")         do_backup || true ;;
            "Exit")                    break ;;
        esac
    done
}

# ── CLI dispatch ─────────────────────────────────────────────────────────────

case "${1:-}" in
    setup)      do_setup ;;
    whisper)    do_whisper ;;
    reconfig)   do_reconfig ;;
    packages)   shift; do_packages "$@" ;;
    apps)       shift; do_apps "$@" ;;
    gaming)     shift; do_gaming "$@" ;;
    backup)     shift; do_backup "$@" ;;
    lazy-lock)  do_lazy_lock ;;
    help|--help|-h) usage ;;
    *)          do_menu ;;
esac
