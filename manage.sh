#!/bin/bash
# Dotfiles Management Script — single entry point for all dotfiles operations
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared utilities
source "$SCRIPT_DIR/install/lib/common.sh"
source "$SCRIPT_DIR/install/lib/detect.sh"

install_interrupt_trap

CHEZMOI_CONF="$HOME/.config/chezmoi/chezmoi.toml"

# ── Helpers ──────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage: ./manage.sh [command]

Commands:
  packages    Manage packages (add/remove from groups)
  apps        Manage AppImages and Distrobox apps
  cursor      Manage Cursor extensions
  reconfig    Reconfigure chezmoi data flags
  whisper     Update whisper model for hyprvoice dictation
  setup       Run full installer (bootstrap + interactive setup)
  update      Update system packages and refresh vibewatch from source
  grub-theme  Manage GRUB bootloader themes
  lazy-lock   Sync nvim lazy-lock.json back to dotfiles source
  help        Show this help message

Run without arguments for an interactive menu.
EOF
}

is_desktop_install() {
    [ -f "$CHEZMOI_CONF" ] && grep -Eq '^[[:space:]]*install_purpose[[:space:]]*=[[:space:]]*"desktop"' "$CHEZMOI_CONF"
}

external_apps_available() {
    is_desktop_install && command_exists distrobox-enter
}

# ── Actions ──────────────────────────────────────────────────────────────────

do_setup() {
    "$SCRIPT_DIR/tools/setup.sh"
}

do_update() {
    local family
    family=$(get_distro_family "$(detect_distro)")
    if [ "$family" = "unknown" ]; then
        print_error "Unsupported distro, cannot update"
        return 1
    fi

    source "$SCRIPT_DIR/install/distros/${family}.sh"
    # "confirm" → list the available updates and prompt before applying.
    if ! update_system confirm; then
        print_info "System update cancelled."
        return 0
    fi

    if ! command_exists vibewatch; then
        print_info "vibewatch not installed, skipping"
        return 0
    fi

    local local_sha
    if spin_capture local_sha "Checking vibewatch..." \
        bash "$SCRIPT_DIR/tools/vibewatch-check-current.sh" --print-sha; then
        print_info "vibewatch already up to date (${local_sha:-unknown})"
        return 0
    fi

    print_info "Refreshing vibewatch (from ${local_sha:-unknown})..."
    if ! curl -fsSL https://raw.githubusercontent.com/Moinax/vibewatch/main/install.sh | sh; then
        print_warning "vibewatch refresh failed (system update already applied)"
        return 0
    fi
    print_success "vibewatch updated"

    if systemctl --user restart vibewatch.service 2>/dev/null; then
        print_success "vibewatch.service restarted"
    fi
}

# Read a string value from chezmoi.toml [data] section
get_chezmoi_data() {
    local key="$1"
    if [ -f "$CHEZMOI_CONF" ]; then
        grep "$key" "$CHEZMOI_CONF" 2>/dev/null | sed 's/.*= *"\?\([^"]*\)"\?/\1/' || true
    fi
}

# Set a string value in chezmoi.toml [data] section (upsert)
set_chezmoi_data() {
    local key="$1" value="$2"
    if [ ! -f "$CHEZMOI_CONF" ]; then
        print_warning "chezmoi.toml not found, skipping $key update"
        return
    fi
    if grep -q "${key} = " "$CHEZMOI_CONF"; then
        sed -i 's/'"${key}"' = .*/'"${key}"' = "'"${value}"'"/' "$CHEZMOI_CONF"
    else
        sed -i '/^\[data\]/a\    '"${key}"' = "'"${value}"'"' "$CHEZMOI_CONF"
    fi
}

do_whisper() {
    if ! command_exists hyprvoice; then
        print_error "hyprvoice is not installed"
        return 1
    fi

    local current_provider current_model
    current_provider=$(get_chezmoi_data 'hyprvoice_provider')
    current_model=$(get_chezmoi_data 'hyprvoice_model')
    : "${current_provider:=whisper-cpp}"

    # Choose provider
    local provider
    provider=$(printf '%s\n' "whisper-cpp (local)" "groq (cloud, free tier)" | \
        gum choose --cursor.foreground="212" \
        --header "Select transcription provider (current: $current_provider):") || {
        echo "Cancelled."
        return
    }
    provider="${provider%% (*}"

    local chosen=""
    if [ "$provider" = "whisper-cpp" ]; then
        # Parse available local models from hyprvoice output (whisper-cpp section)
        local model_list
        model_list=$(hyprvoice model list 2>/dev/null)
        local models=()
        local model_names=()
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*\[.\][[:space:]]+(.+)$ ]]; then
                local entry="${BASH_REMATCH[1]}"
                local name="${entry%% -*}"
                name="${name%% *}"
                if [ "$name" = "$current_model" ] && [ "$provider" = "$current_provider" ]; then
                    models+=("$entry (current)")
                else
                    models+=("$entry")
                fi
                model_names+=("$name")
            fi
        done <<< "$model_list"

        if [ ${#models[@]} -eq 0 ]; then
            print_error "No whisper models found"
            return 1
        fi

        local cursor_arg=""
        if [ -n "$current_model" ] && [ "$provider" = "$current_provider" ]; then
            for i in "${!model_names[@]}"; do
                if [ "${model_names[$i]}" = "$current_model" ]; then
                    cursor_arg="$((i + 1))"
                    break
                fi
            done
        fi

        chosen=$(printf '%s\n' "${models[@]}" | gum choose --cursor.foreground="212" \
            ${cursor_arg:+--cursor-prefix="> " --selected-prefix="> "} \
            --header "Select whisper model:") || {
            echo "Cancelled."
            return
        }

        # Strip " (current)" suffix and description to get model name
        chosen="${chosen% (current)}"
        chosen="${chosen%% -*}"
        chosen="${chosen%% *}"

        print_info "Downloading whisper model: $chosen"
        if hyprvoice model download "$chosen"; then
            print_success "Model '$chosen' downloaded"
        else
            print_error "Failed to download model '$chosen'"
            return 1
        fi
    elif [ "$provider" = "groq" ]; then
        chosen=$(printf '%s\n' "${GROQ_WHISPER_MODELS[@]}" | gum choose --cursor.foreground="212" \
            --header "Select Groq model:") || {
            echo "Cancelled."
            return
        }
        chosen="${chosen%% *}"

        setup_groq_api_key --allow-change
    fi

    if [ "$chosen" = "$current_model" ] && [ "$provider" = "$current_provider" ]; then
        print_info "Provider '$provider' with model '$chosen' is already the current configuration"
        return
    fi

    set_chezmoi_data "hyprvoice_provider" "$provider"
    set_chezmoi_data "hyprvoice_model" "$chosen"
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
        sed -i "s/${key} = ${val}/${key} = ${new_val}/" "$CHEZMOI_CONF"
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

do_cursor() {
    "$SCRIPT_DIR/tools/manage-cursor-extensions.sh" "$@"
}

do_packages() {
    "$SCRIPT_DIR/tools/manage-packages.sh" "$@"
}

do_apps() {
    if ! is_desktop_install; then
        print_error "External apps helper is only available for desktop installs"
        return 1
    fi

    if ! command_exists distrobox-enter; then
        print_error "distrobox-enter is not installed"
        print_info "Run the desktop installer or install Distrobox first."
        return 1
    fi

    "$SCRIPT_DIR/tools/manage-external-apps.sh" "$@"
}

do_grub_theme() {
    "$SCRIPT_DIR/tools/manage-grub-theme.sh" "$@"
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

    while true; do
        print_header "Dotfiles Manager"

        # Build menu options dynamically
        local options=()
        options+=("Setup")
        options+=("Manage packages")
        if external_apps_available; then
            options+=("External apps")
        fi
        if command_exists cursor; then
            options+=("Cursor extensions")
        fi
        options+=("Reconfigure flags")
        if command_exists hyprvoice; then
            options+=("Update whisper model")
        fi
        if [ -f /etc/default/grub ]; then
            options+=("GRUB theme")
        fi
        options+=("Update system")
        options+=("Exit")

        local choice
        choice=$(printf '%s\n' "${options[@]}" | gum choose --cursor.foreground="212" --header "What would you like to do?") || break

        # A child tool returning non-zero (e.g. missing dependency, user
        # cancelled inside it) must not kill the menu — swallow it here.
        case "$choice" in
            "Setup")                   do_setup || true ;;
            "Manage packages")         do_packages || true ;;
            "External apps")           do_apps || true ;;
            "Cursor extensions")       do_cursor || true ;;
            "Reconfigure flags")       do_reconfig || true ;;
            "Update whisper model")    do_whisper || true ;;
            "GRUB theme")              do_grub_theme || true ;;
            "Update system")           do_update || true ;;
            "Exit")                    break ;;
        esac
    done
}

# ── CLI dispatch ─────────────────────────────────────────────────────────────

case "${1:-}" in
    setup)      do_setup ;;
    update)     do_update ;;
    whisper)    do_whisper ;;
    reconfig)   do_reconfig ;;
    packages)   shift; do_packages "$@" ;;
    cursor)     shift; do_cursor "$@" ;;
    apps)       shift; do_apps "$@" ;;
    grub-theme) shift; do_grub_theme "$@" ;;
    lazy-lock)  do_lazy_lock ;;
    help|--help|-h) usage ;;
    *)          do_menu ;;
esac
