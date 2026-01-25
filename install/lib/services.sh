#!/bin/bash
# Service management functions

# Source common functions (use local var to avoid overwriting parent's SCRIPT_DIR)
_SERVICES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SERVICES_DIR/common.sh"

# Enable and start a systemd service
enable_service() {
    local service="$1"
    
    if systemctl is-enabled "$service" &>/dev/null; then
        print_info "Service $service is already enabled"
    else
        print_info "Enabling service: $service"
        if sudo systemctl enable --now "$service"; then
            print_success "Service $service enabled and started"
        else
            print_warning "Failed to enable service $service"
        fi
    fi
}

# Enable multiple services
enable_services() {
    local services=("$@")
    
    for service in "${services[@]}"; do
        enable_service "$service"
    done
}

# Disable a service
disable_service() {
    local service="$1"
    
    if systemctl is-enabled "$service" &>/dev/null; then
        print_info "Disabling service: $service"
        sudo systemctl disable --now "$service"
    else
        print_info "Service $service is already disabled"
    fi
}

# Check service status
check_service() {
    local service="$1"
    
    if systemctl is-active "$service" &>/dev/null; then
        print_success "Service $service is running"
        return 0
    else
        print_warning "Service $service is not running"
        return 1
    fi
}

# Add user to a group (e.g., docker)
add_user_to_group() {
    local group="$1"
    local user="${2:-$USER}"
    
    if groups "$user" | grep -q "\b$group\b"; then
        print_info "User $user is already in group $group"
    else
        print_info "Adding user $user to group $group"
        sudo usermod -aG "$group" "$user"
        print_success "User added to $group group (logout/login required)"
    fi
}
