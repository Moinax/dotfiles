#!/usr/bin/env bash
# Nix is optional by group, but deterministic once Development is selected:
# install once, verify daemon + flakes, and never overwrite unknown state.
#
# Run: bash tests/test_nix_install.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$REPO_DIR/tools/install-nix.sh"
DEVELOPMENT="$REPO_DIR/packages/groups/development.yaml"

failures=0
check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ok   $label"
    else
        echo "  FAIL $label: expected '$expected', got '$actual'"
        failures=$((failures + 1))
    fi
}

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/bin" "$stage/state"
export NIX_TEST_STATE="$stage/state"
export NIX_TEST_NIX_LOG="$stage/nix.log"
export NIX_TEST_CURL_LOG="$stage/curl.log"
export NIX_TEST_INSTALL_ARGS_LOG="$stage/install-args.log"
export NIX_TEST_NIX_BIN="$stage/nix/var/nix/profiles/default/bin/nix"

cat > "$stage/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF

cat > "$stage/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -u
state=${NIX_TEST_STATE:?}
unit=${*: -1}
case "$1" in
    list-unit-files) exit 0 ;;
    is-active)  [ -f "$state/active-$unit" ] ;;
    is-enabled) [ -f "$state/enabled-$unit" ] ;;
    enable)     touch "$state/enabled-$unit" ;;
    start)      touch "$state/active-$unit" ;;
    *) exit 1 ;;
esac
EOF

cat > "$stage/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'called\n' >> "${NIX_TEST_CURL_LOG:?}"
bin=${NIX_TEST_NIX_BIN:?}
root=${DOTFILES_NIX_ROOT:?}
mkdir -p "$(dirname "$bin")" \
         "$root/var/nix/profiles/default/etc/profile.d"
cat > "$bin" <<'NIX'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NIX_TEST_NIX_LOG:?}"
case "${1:-}" in
    --version) echo 'nix (Determinate Nix test) 3.0.0' ;;
    flake) [ "${2:-}" = metadata ] ;;
    *) exit 0 ;;
esac
NIX
chmod +x "$bin"
printf ':\n' > "$root/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
printf '{}\n' > "$root/receipt.json"
cat <<'INSTALLER'
printf '%s\n' "$*" > "${NIX_TEST_INSTALL_ARGS_LOG:?}"
INSTALLER
EOF
chmod +x "$stage/bin/"*

test_path="$stage/bin:/usr/bin:/bin"

echo "Development group declaration"
# shellcheck source=../install/lib/common.sh
source "$REPO_DIR/install/lib/common.sh"
# Read by the sourced group helpers.
# shellcheck disable=SC2034
DISTRO_FAMILY=arch
# shellcheck disable=SC2034
INSTALL_PURPOSE=terminal
row=$(group_declared_packages "$DEVELOPMENT" | awk -F '\t' '$1 == "nix" { print $1 ":" $2 }')
check "Nix belongs to Development as a custom install" "nix:custom" "$row"
check "Nix uses the repository installer" \
      'bash "$DOTFILES_DIR/tools/install-nix.sh" install' \
      "$(parse_custom_install_cmd "$DEVELOPMENT" nix)"

CHEZMOI_CONF="$stage/chezmoi.toml"
printf '[data]\n    install_development = false\n' > "$CHEZMOI_CONF"
group_enabled "$DEVELOPMENT" && enabled=yes || enabled=no
check "Development-disabled machines do not enable the group" no "$enabled"
printf '[data]\n    install_development = true\n' > "$CHEZMOI_CONF"
group_enabled "$DEVELOPMENT" && enabled=yes || enabled=no
check "Development selection enables the group" yes "$enabled"

echo "Fresh install and verification"
PATH="$test_path" DOTFILES_NIX_ROOT="$stage/nix" \
    bash "$INSTALLER" install > "$stage/first.out" 2>&1
check "first install succeeds" 0 "$?"
check "Determinate installer is downloaded once" 1 \
      "$(wc -l < "$NIX_TEST_CURL_LOG")"
check "installer leaves shell profiles to chezmoi" \
      "install linux --no-confirm --init systemd --no-modify-profile" \
      "$(cat "$NIX_TEST_INSTALL_ARGS_LOG")"
check "daemon service is active" yes \
      "$([ -f "$NIX_TEST_STATE/active-nix-daemon.service" ] && echo yes || echo no)"
check "daemon socket is enabled" yes \
      "$([ -f "$NIX_TEST_STATE/enabled-nix-daemon.socket" ] && echo yes || echo no)"
check "nix --version was checked" 1 \
      "$(grep -c '^--version$' "$NIX_TEST_NIX_LOG")"
check "flake metadata was evaluated" 1 \
      "$(grep -c '^flake metadata ' "$NIX_TEST_NIX_LOG")"

echo "Idempotence"
PATH="$test_path" DOTFILES_NIX_ROOT="$stage/nix" \
    bash "$INSTALLER" install > "$stage/second.out" 2>&1
check "second run succeeds" 0 "$?"
check "second run does not download or reinstall" 1 \
      "$(wc -l < "$NIX_TEST_CURL_LOG")"
PATH="$test_path" DOTFILES_NIX_ROOT="$stage/nix" \
    bash "$INSTALLER" check
check "healthy install satisfies the package check" 0 "$?"

echo "Conflicting installations"
mkdir -p "$stage/foreign-bin"
cat > "$stage/foreign-bin/nix" <<'EOF'
#!/usr/bin/env bash
echo 'foreign nix'
EOF
chmod +x "$stage/foreign-bin/nix"
PATH="$stage/foreign-bin:$test_path" DOTFILES_NIX_ROOT="$stage/foreign-root" \
    bash "$INSTALLER" install > "$stage/foreign.out" 2>&1
check "foreign Nix is left untouched" 0 "$?"
check "foreign Nix does not trigger a download" 1 \
      "$(wc -l < "$NIX_TEST_CURL_LOG")"
check "foreign install is reported explicitly" 1 \
      "$(grep -c 'Another Nix installation' "$stage/foreign.out")"

mkdir -p "$stage/partial-root"
PATH="$test_path" DOTFILES_NIX_ROOT="$stage/partial-root" \
    bash "$INSTALLER" install > "$stage/partial.out" 2>&1
check "partial /nix state is refused" 1 "$?"
check "partial state does not trigger a download" 1 \
      "$(wc -l < "$NIX_TEST_CURL_LOG")"

echo "Shell integration"
check "Nix is loaded from zshenv" 1 \
      "$(grep -c '^  source /nix/.*/nix-daemon.sh$' "$REPO_DIR/home/dot_zshenv.tmpl")"
check "Nix PATH additions are appended" 1 \
      "$(grep -c 'PATH="${PATH:+$PATH:}$_nix_dir"' "$REPO_DIR/home/dot_zshenv.tmpl")"
check "no global Nix profile install is introduced" 0 \
      "$(rg -n 'nix profile install' "$INSTALLER" "$DEVELOPMENT" 2>/dev/null | wc -l)"

if command -v chezmoi >/dev/null 2>&1 && command -v zsh >/dev/null 2>&1; then
    printf '[data]\ninstall_development = false\ninstall_hyprland = false\n' \
        > "$stage/zsh-disabled.toml"
    chezmoi execute-template --config "$stage/zsh-disabled.toml" \
        < "$REPO_DIR/home/dot_zshenv.tmpl" > "$stage/zshenv-disabled"
    check "Development-disabled template has no Nix integration" 0 \
          "$(grep -c 'nix-daemon.sh' "$stage/zshenv-disabled" || true)"

    printf '[data]\ninstall_development = true\ninstall_hyprland = false\n' \
        > "$stage/zsh-enabled.toml"
    chezmoi execute-template --config "$stage/zsh-enabled.toml" \
        < "$REPO_DIR/home/dot_zshenv.tmpl" > "$stage/zshenv-enabled"
    zsh -n "$stage/zshenv-enabled"
    check "Development-enabled zshenv parses" 0 "$?"

    fake_profile="$stage/nix-profile/etc/profile.d/nix-daemon.sh"
    mkdir -p "$(dirname "$fake_profile")" "$stage/home"
    printf 'export NIX_PROFILES="test-profile"\nexport PATH="$HOME/.nix-profile/bin:%s/nix-default/bin:$PATH"\n' \
        "$stage" > "$fake_profile"
    sed "s#/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh#$fake_profile#g" \
        "$stage/zshenv-enabled" > "$stage/zshenv-path-test"
    rendered_path=$(HOME="$stage/home" PATH=/usr/bin:/bin \
        zsh -f -c 'source "$1"; print -r -- "$PATH"' _ "$stage/zshenv-path-test")
    case "$rendered_path" in
        *"/usr/bin:/bin:$stage/home/.nix-profile/bin:$stage/nix-default/bin"*) ordered=yes ;;
        *) ordered=no ;;
    esac
    check "system PATH remains ahead of Nix profiles" yes "$ordered"
else
    echo "  SKIP chezmoi/zsh unavailable; rendered shell checks skipped"
fi

echo ""
if [ "$failures" -eq 0 ]; then
    echo "all checks passed"
else
    echo "$failures check(s) failed"
    exit 1
fi
