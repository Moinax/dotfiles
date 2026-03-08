#!/bin/bash
# Distro detection functions

# Detect the current Linux distribution
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/arch-release ]; then
        echo "arch"
    elif [ -f /etc/fedora-release ]; then
        echo "fedora"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    else
        echo "unknown"
    fi
}

# Get the pretty name of the distro
get_distro_name() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$PRETTY_NAME"
    else
        echo "Unknown Linux Distribution"
    fi
}

# Check if distro is supported
is_supported_distro() {
    local distro="$1"
    case "$distro" in
        arch|manjaro|endeavouros|garuda|\
        fedora|rhel|centos|rocky|alma|\
        ubuntu|debian|linuxmint|pop|elementary|neon|zorin|kali)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Get the distro family (maps individual distros to their package manager family)
get_distro_family() {
    local distro="$1"
    case "$distro" in
        ubuntu|debian|linuxmint|pop|elementary|neon|zorin|kali) echo "debian" ;;
        arch|manjaro|endeavouros|garuda) echo "arch" ;;
        fedora|rhel|centos|rocky|alma) echo "fedora" ;;
        *) echo "unknown" ;;
    esac
}

# Get list of supported distros
get_supported_distros() {
    echo "arch manjaro endeavouros garuda fedora rhel centos rocky alma ubuntu debian linuxmint pop elementary neon zorin kali"
}
