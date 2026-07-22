# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Personal dotfiles for CachyOS (Arch-based), managed with [Chezmoi](https://www.chezmoi.io/). Uses an interactive TUI installer powered by [gum](https://github.com/charmbracelet/gum). Other Arch derivatives work on a best-effort basis; non-Arch distros are unsupported.

NVIDIA policy: the dotfiles deliberately install no drivers and apply no NVIDIA workarounds (no env vars, modprobe options, or kernel parameters) — CachyOS's stock NVIDIA stack is used as-is.

## Key Commands

```bash
# Interactive management menu (single entry point)
./manage.sh

# CLI subcommands
./manage.sh setup               # bootstrap: installs gum + git, then launches installer
./manage.sh apply               # apply dotfiles via chezmoi
./manage.sh diff                # view dotfiles diff
./manage.sh whisper             # update whisper model for hyprvoice
./manage.sh reconfig            # toggle chezmoi data flags
./manage.sh apps import-appimage ~/Downloads/App.AppImage
./manage.sh apps install-github owner/repo --name App          # install latest GitHub release (AppImage or deb/rpm) + track updates
./manage.sh apps set-source --name App --repo owner/repo       # attach a release source to an already-installed app
./manage.sh apps check-updates                                 # compare installed versions vs latest GitHub releases
./manage.sh apps update --all                                  # update all tracked apps (or --name App)
./manage.sh apps remove-appimage --name App
./manage.sh apps install-distrobox --container ubuntu --package ~/Downloads/app.deb
./manage.sh apps install-distrobox --container ubuntu --package ~/Downloads/app.deb --args "--disable-gpu"
./manage.sh apps update-distrobox --name app --package ~/Downloads/app-new.deb
./manage.sh packages sync       # install packages newly added to base.yaml / enabled groups
./manage.sh backup create       # encrypted backup of ~/Projects secrets + repo manifest → private GitHub repo
./manage.sh backup restore      # re-clone all repos and restore secret files on a fresh machine
./manage.sh backup list         # inspect backup contents

# ./manage.sh backup is backed by tools/backup-projects.sh: repos are NOT archived
# (only a manifest of remote+branch), just gitignored env/config files plus
# ~/.npmrc, ~/.ssh, ~/.config/gh — age-encrypted with a passphrase. User config in
# ~/.config/projects-backup/: extra-includes (repo-relative path regexes),
# extra-home-includes (paths relative to ~), extra-exclude-dirs (dir-name regexes).
# `restore --home-only` restores just the home secrets; the installer's SSH
# setup uses it to bootstrap a fresh machine (gh OAuth device flow over HTTPS
# needs no SSH key, so GitHub login + age passphrase are the only secrets).

# ./manage.sh apps opens a wizard-driven helper backed by tools/manage-external-apps.py
# (Python, stdlib-only; state files in ~/.local/state/dotfiles/external-apps/ are
# bash-quoted KEY=VALUE .env files kept compatible with the former shell version)

# Direct chezmoi usage
chezmoi diff                    # see what would change
chezmoi apply                   # apply source state to $HOME
chezmoi edit ~/.zshrc           # edit a managed file (writes back to source)
```

## Architecture

### Installer pipeline
`manage.sh` → `tools/setup.sh` → `install/installer.sh` → `install/distros/arch.sh` + package YAML files

- `install/distros/arch.sh` — pacman/paru package manager wrappers
- `install/lib/common.sh` — shared utilities
- `install/lib/detect.sh` — distro detection (maps CachyOS/Arch derivatives to the `arch` family)
- `install/lib/services.sh` — systemd service enablement

### Package definitions (`packages/`)
YAML files define packages (key `arch`, plus `aur`/`desktop_aur` in base). Groups (`packages/groups/`) are selectable during install: `hyprland`, `development`, `gaming`, `multimedia`, `productivity`.

- `packages/common.yaml` — tools installed via custom methods (zoxide, fnm, etc.)
- `packages/arch/base.yaml` — base packages

### Chezmoi source directory (`home/`)
The `home/` directory is the Chezmoi source. Files use Chezmoi naming conventions:
- `dot_` prefix → `.` (e.g., `dot_zshrc.tmpl` → `~/.zshrc`)
- `.tmpl` suffix → Go template, rendered with Chezmoi data
- `home/.chezmoiignore` — conditionally excludes configs based on template variables like `.install_hyprland`, `.install_development`, `.install_productivity`

### Managed configs (`home/dot_config/`)
Hypr, Waybar, Rofi, SwayNC, Wlogout (Wayland desktop), Kitty (terminal), Neovim (AstroNvim-based), Hunk (git diffs and reviews), Starship (prompt), Yazi (file manager), Cursor (editor).

## Conventions

- Shell scripts use `set -e` and consistent color-coded output helpers (`print_info`, `print_success`, `print_error`, `print_warning`)
- Base package YAML supports `core`, `desktop`, `aur`, and `desktop_aur` sections
- **Keybinding changes**: When modifying keybindings in Hyprland (`home/dot_config/hypr/conf/binds.lua.tmpl`), always update `KEYBINDINGS.md` at the repo root to keep the reference in sync
- **Herdr layout changes**: When modifying the workspace layout — pane/tab structure or labels in `herdr-agent-layout`, `dev-herdr`, or `herdr-pane-cmd` — run `herdr-clients migrate-layout` after `chezmoi apply`. Existing workspaces persist their old layout (dev-herdr reattaches as-is, never migrates), so without this the previous iteration silently comes back at the next server restart
