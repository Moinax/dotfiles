#!/usr/bin/env bash
# Install Nix as a project-toolchain provider on an Arch/CachyOS workstation.
#
# This deliberately owns only the system Nix installation. Project packages
# stay in flakes and are entered with `nix develop`; pacman/paru and chezmoi
# remain the owners of the host and home configuration respectively.
set -euo pipefail

NIX_ROOT="${DOTFILES_NIX_ROOT:-/nix}"
NIX_DEFAULT_PROFILE="$NIX_ROOT/var/nix/profiles/default"
NIX_BIN="$NIX_DEFAULT_PROFILE/bin/nix"
NIX_DAEMON_SH="$NIX_DEFAULT_PROFILE/etc/profile.d/nix-daemon.sh"
NIX_RECEIPT="$NIX_ROOT/receipt.json"
NIX_INSTALLER_URL="https://install.determinate.systems/nix"

info() { printf '[INFO]    %s\n' "$1"; }
ok()   { printf '[SUCCESS] %s\n' "$1"; }
warn() { printf '[WARNING] %s\n' "$1" >&2; }
err()  { printf '[ERROR]   %s\n' "$1" >&2; }

run_root() {
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        err "sudo is required to manage the Nix daemon"
        return 1
    fi
}

# A non-canonical Nix command is intentionally enough to satisfy the package
# selector. It may be pacman-owned, single-user, or managed by another installer;
# none of those gives this script permission to replace it.
foreign_nix() {
    local found
    found=$(command -v nix 2>/dev/null || true)
    if [ -n "$found" ] && [ "$found" != "$NIX_BIN" ]; then
        printf '%s\n' "$found"
    fi
}

daemon_active() {
    command -v systemctl >/dev/null 2>&1 \
        && systemctl is-active --quiet nix-daemon.service
}

check_installation() {
    if [ -x "$NIX_BIN" ]; then
        daemon_active
        return
    fi
    [ -n "$(foreign_nix)" ]
}

require_systemd() {
    command -v systemctl >/dev/null 2>&1 || {
        err "systemd is required for this multi-user Nix installation"
        return 1
    }
    systemctl list-unit-files >/dev/null 2>&1 || {
        err "systemd is not running; refusing to install a daemon-less Nix"
        return 1
    }
}

ensure_daemon() {
    require_systemd || return 1

    if ! systemctl is-enabled --quiet nix-daemon.socket 2>/dev/null; then
        info "Enabling the Nix daemon socket"
        run_root systemctl enable nix-daemon.socket
    fi
    if ! systemctl is-active --quiet nix-daemon.socket 2>/dev/null; then
        run_root systemctl start nix-daemon.socket
    fi
    if ! daemon_active; then
        info "Starting the Nix daemon"
        run_root systemctl start nix-daemon.service
    fi
}

activate_nix() {
    if [ -r "$NIX_DAEMON_SH" ]; then
        # shellcheck disable=SC1090
        . "$NIX_DAEMON_SH"
    fi
    hash -r 2>/dev/null || true
}

verify_installation() {
    [ -x "$NIX_BIN" ] || {
        err "Nix binary is missing at $NIX_BIN"
        return 1
    }
    daemon_active || {
        err "nix-daemon.service is not active"
        return 1
    }

    activate_nix

    local version flake_dir
    version=$("$NIX_BIN" --version) || {
        err "nix --version failed"
        return 1
    }
    ok "$version"
    ok "nix-daemon.service is active"

    # Exercise flake evaluation locally: this validates the feature without a
    # network fetch and without leaving a lock file in the user's project.
    flake_dir=$(mktemp -d)
    printf '{ outputs = { self }: { }; }\n' > "$flake_dir/flake.nix"
    if ! "$NIX_BIN" flake metadata --no-write-lock-file "path:$flake_dir" >/dev/null; then
        rm -rf "$flake_dir"
        err "nix flake metadata failed; flakes are not functional"
        return 1
    fi
    rm -rf "$flake_dir"
    ok "flakes work (nix flake metadata)"
}

install_nix() {
    local existing

    if [ -x "$NIX_BIN" ]; then
        if [ -f "$NIX_RECEIPT" ]; then
            info "Determinate Nix is already installed; the installer will not run again"
        else
            warn "A compatible multi-user Nix already exists at $NIX_BIN"
            warn "No Determinate receipt was found; leaving the installation files untouched"
        fi
        ensure_daemon
        verify_installation
        return
    fi

    existing=$(foreign_nix)
    if [ -n "$existing" ]; then
        warn "Another Nix installation is already available at $existing"
        warn "Leaving it untouched; migrate or remove it explicitly before using this installer"
        return 0
    fi

    if [ -e "$NIX_ROOT" ]; then
        err "$NIX_ROOT already exists but does not contain the expected multi-user Nix binary"
        err "Refusing to overwrite a partial or differently managed installation"
        return 1
    fi

    command -v curl >/dev/null 2>&1 || {
        err "curl is required to install Nix"
        return 1
    }
    require_systemd

    info "Installing Determinate Nix (multi-user, systemd, flakes enabled)"
    # Same installer and Linux/systemd plan as provision-droplet.sh. Determinate
    # Nix enables nix-command and flakes by default. Chezmoi owns shell startup,
    # so the installer must not add a competing profile hook.
    curl --proto '=https' --tlsv1.2 -sSfL "$NIX_INSTALLER_URL" \
        | sh -s -- install linux --no-confirm --init systemd --no-modify-profile

    ensure_daemon
    verify_installation
}

usage() {
    cat <<'EOF'
Usage: tools/install-nix.sh <command>

Commands:
  check    Exit 0 when Nix is already managed or another installation exists
  install  Install, repair and verify multi-user Determinate Nix
  verify   Verify the daemon, nix --version and local flake evaluation
EOF
}

case "${1:-}" in
    check)   check_installation ;;
    install) install_nix ;;
    verify)  verify_installation ;;
    help|--help|-h|"") usage ;;
    *) usage >&2; exit 2 ;;
esac
