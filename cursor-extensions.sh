#!/bin/bash
# Cursor Extensions Manager
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTENSIONS_FILE="$SCRIPT_DIR/home/dot_config/Cursor/extensions.txt"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if cursor CLI is available
check_cursor() {
    if ! command -v cursor &> /dev/null; then
        print_error "cursor command not found. Is Cursor installed?"
        exit 1
    fi
}

# Export extensions
do_export() {
    check_cursor
    print_info "Exporting Cursor extensions..."
    mkdir -p "$(dirname "$EXTENSIONS_FILE")"
    cursor --list-extensions | sort > "$EXTENSIONS_FILE"
    local count=$(grep -v '^#' "$EXTENSIONS_FILE" 2>/dev/null | grep -v '^$' | wc -l | tr -d ' ')
    print_success "Exported $count extensions to:"
    echo "  $EXTENSIONS_FILE"
}

# Install extensions
do_install() {
    check_cursor
    if [ ! -f "$EXTENSIONS_FILE" ]; then
        print_error "Extensions file not found: $EXTENSIONS_FILE"
        print_info "Run export first to create the extensions list."
        exit 1
    fi
    
    local count=0
    local total=$(grep -v '^#' "$EXTENSIONS_FILE" | grep -v '^$' | wc -l | tr -d ' ')
    
    print_info "Installing $total Cursor extensions..."
    while IFS= read -r ext || [ -n "$ext" ]; do
        [[ -z "$ext" || "$ext" =~ ^# ]] && continue
        count=$((count + 1))
        echo "  [$count/$total] $ext"
        cursor --install-extension "$ext" --force 2>/dev/null || true
    done < "$EXTENSIONS_FILE"
    print_success "Done! Installed $count extensions."
}

# Main menu
main() {
    echo ""
    echo "Cursor Extensions Manager"
    echo "========================="
    echo ""
    
    # Use gum if available, otherwise simple select
    if command -v gum &> /dev/null; then
        ACTION=$(gum choose "Export (update list)" "Install extensions" "Cancel") || ACTION="Cancel"
    else
        echo "1) Export (update list)"
        echo "2) Install extensions"
        echo "3) Cancel"
        echo ""
        read -p "Choose an option [1-3]: " choice
        case $choice in
            1) ACTION="Export (update list)" ;;
            2) ACTION="Install extensions" ;;
            *) ACTION="Cancel" ;;
        esac
    fi
    
    case "$ACTION" in
        "Export (update list)") do_export ;;
        "Install extensions") do_install ;;
        *) echo "Cancelled." ;;
    esac
}

# Allow direct command: ./cursor-extensions.sh export|install
case "${1:-}" in
    export) do_export ;;
    install) do_install ;;
    *) main ;;
esac
