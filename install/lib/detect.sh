#!/bin/bash
# Distro detection functions — this repo targets CachyOS (Arch-based).

# Detect the current Linux distribution
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/arch-release ]; then
        echo "arch"
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

# Check if distro is supported. CachyOS is the tested target; plain Arch and
# other Arch derivatives (ID_LIKE=arch) work on a best-effort basis since
# everything installs via pacman/paru.
is_supported_distro() {
    [ "$(get_distro_family "$1")" = "arch" ]
}

# Get the distro family. Anything Arch-based (cachyos, arch, endeavouros, ...)
# maps to "arch", which is both the package-manager wrapper to source
# (install/distros/arch.sh) and the key used in the package YAML files.
get_distro_family() {
    local distro="$1"
    case "$distro" in
        arch|cachyos|manjaro|endeavouros|garuda)
            echo "arch"
            return
            ;;
    esac
    # Fall back to ID_LIKE for unlisted Arch derivatives
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case " ${ID_LIKE:-} " in
            *" arch "*) echo "arch"; return ;;
        esac
    fi
    echo "unknown"
}

# Get list of supported (tested) distros
get_supported_distros() {
    echo "cachyos (and other Arch-based distros, best-effort)"
}

# Check if the system has a fingerprint reader.
# Pre-install detection: scan lsusb for "fingerprint"/"biometric" strings or for the
# vendor IDs of dedicated fingerprint chip makers — Goodix (27c6), Validity (138a),
# AuthenTec (08ff), Upek (147e).
has_fingerprint_reader() {
    command -v lsusb &>/dev/null || return 1
    lsusb 2>/dev/null | grep -qiE 'fingerprint|biometric|ID (27c6|138a|08ff|147e):'
}
