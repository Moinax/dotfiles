#!/bin/bash
# Hyprvoice (dictation) configuration helpers, shared by the installer's
# first-time setup and `manage.sh whisper`. Everything that encodes a hyprvoice
# or Groq interface (model-list output format, provider names, API key flow)
# lives here so the two wizards can't drift apart.
#
# Requires common.sh (print helpers, set_secret, SECRETS_CONF) to be sourced.

# Available Groq whisper models (single source of truth)
GROQ_WHISPER_MODELS=(
    "whisper-large-v3-turbo - Faster with slight accuracy tradeoff"
    "whisper-large-v3 - Best accuracy; generous free tier"
)

# Parse `hyprvoice model list` output into one "name - description" entry per
# line (the listing marks each model with a [x]/[ ] checkbox prefix).
hyprvoice_list_models() {
    local line
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*\[.\][[:space:]]+(.+)$ ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
        fi
    done < <(hyprvoice model list 2>/dev/null)
}

# Provider menu. Prints the bare provider name (whisper-cpp | groq);
# propagates gum's cancel status so callers pick their own fallback.
hyprvoice_choose_provider() {
    local header="$1" choice
    choice=$(printf '%s\n' "whisper-cpp (local)" "groq (cloud, free tier)" | \
        gum choose --cursor.foreground="212" --header "$header") || return 1
    printf '%s\n' "${choice%% (*}"
}

# Groq model menu. Prints the bare model name; propagates cancel status.
hyprvoice_choose_groq_model() {
    local choice
    choice=$(printf '%s\n' "${GROQ_WHISPER_MODELS[@]}" | gum choose --cursor.foreground="212" \
        --header "Select Groq model:") || return 1
    printf '%s\n' "${choice%% *}"
}

# Download a local whisper model. Prints progress and success; returns
# non-zero on failure so callers pick their own severity (abort vs fallback).
hyprvoice_download_model() {
    print_info "Downloading whisper model: $1"
    if hyprvoice model download "$1"; then
        print_success "Whisper model '$1' downloaded"
        return 0
    fi
    return 1
}

# Ensure a Groq API key is configured. Checks env, then secrets.conf, then prompts.
# Returns 1 only if the user cancels or provides no key.
setup_groq_api_key() {
    local existing_key="${GROQ_API_KEY:-}"
    if [ -z "$existing_key" ] && [ -f "$SECRETS_CONF" ]; then
        existing_key=$(grep '^GROQ_API_KEY=' "$SECRETS_CONF" 2>/dev/null | cut -d= -f2- || true)
    fi

    if [ -n "$existing_key" ]; then
        local masked="${existing_key:0:8}...${existing_key: -4}"
        print_success "Groq API key found: $masked"
        if [ "${1:-}" = "--allow-change" ] && ! gum confirm "Keep current API key?"; then
            existing_key=""
        fi
    fi

    if [ -z "$existing_key" ]; then
        print_info "Get a free Groq API key at: https://console.groq.com/keys"
        local api_key
        api_key=$(gum input --placeholder "Paste your Groq API key (gsk_...)" --password \
            --header "Groq API Key:") || api_key=""

        if [ -z "$api_key" ]; then
            return 1
        fi

        set_secret "GROQ_API_KEY" "$api_key"
        print_success "Groq API key saved to $SECRETS_CONF"

        export GROQ_API_KEY="$api_key"
        systemctl --user import-environment GROQ_API_KEY 2>/dev/null || true
    fi
}
