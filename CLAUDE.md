# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Personal dotfiles for Arch Linux, Fedora, and Debian/Ubuntu, managed with [Chezmoi](https://www.chezmoi.io/). Uses an interactive TUI installer powered by [gum](https://github.com/charmbracelet/gum).

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
./manage.sh cursor export       # save current Cursor extensions list
./manage.sh cursor install      # install Cursor extensions from saved list
./manage.sh apps import-appimage ~/Downloads/App.AppImage
./manage.sh apps install-github owner/repo --name App          # install latest GitHub release (AppImage or deb/rpm) + track updates
./manage.sh apps set-source --name App --repo owner/repo       # attach a release source to an already-installed app
./manage.sh apps check-updates                                 # compare installed versions vs latest GitHub releases
./manage.sh apps update --all                                  # update all tracked apps (or --name App)
./manage.sh apps remove-appimage --name App
./manage.sh apps install-distrobox --container ubuntu --package ~/Downloads/app.deb
./manage.sh apps install-distrobox --container ubuntu --package ~/Downloads/app.deb --args "--disable-gpu"
./manage.sh apps update-distrobox --name app --package ~/Downloads/app-new.deb
./manage.sh update              # update system packages

# ./manage.sh apps opens a wizard-driven helper backed by tools/manage-external-apps.sh

# Direct chezmoi usage
chezmoi diff                    # see what would change
chezmoi apply                   # apply source state to $HOME
chezmoi edit ~/.zshrc           # edit a managed file (writes back to source)
```

## Architecture

### Installer pipeline
`manage.sh` → `tools/setup.sh` → `install/installer.sh` → distro-specific scripts + package YAML files

- `install/distros/{arch,fedora}.sh` — package manager wrappers per distro
- `install/lib/common.sh` — shared utilities
- `install/lib/detect.sh` — distro detection
- `install/lib/services.sh` — systemd service enablement

### Package definitions (`packages/`)
YAML files define packages per distro. Groups (`packages/groups/`) are selectable during install: `hyprland`, `niri`, `development`, `gaming`, `multimedia`, `productivity`.

- `packages/common.yaml` — cross-distro tools installed via custom methods (zoxide, fnm, etc.)
- `packages/{arch,fedora,debian}/base.yaml` — distro base packages

### Chezmoi source directory (`home/`)
The `home/` directory is the Chezmoi source. Files use Chezmoi naming conventions:
- `dot_` prefix → `.` (e.g., `dot_zshrc.tmpl` → `~/.zshrc`)
- `.tmpl` suffix → Go template, rendered with Chezmoi data
- `home/.chezmoiignore` — conditionally excludes configs based on template variables like `.install_hyprland`, `.install_niri`, `.install_development`, `.install_productivity`

### Managed configs (`home/dot_config/`)
Hypr, Niri, Waybar, Rofi, SwayNC, Wlogout (Wayland compositors/desktop), Kitty (terminal), Neovim (AstroNvim-based), Delta (git diffs), Starship (prompt), Yazi (file manager), Cursor (editor).

## Adding a new distribution

1. Create `install/distros/<distro>.sh` with package manager functions
2. Create `packages/<distro>/base.yaml`
3. Add distro-specific entries to `packages/groups/*.yaml`
4. Update `install/lib/detect.sh` if needed

## Conventions

- Shell scripts use `set -e` and consistent color-coded output helpers (`print_info`, `print_success`, `print_error`, `print_warning`)
- Base package YAML supports `core`, `desktop`, and distro-specific extras such as `aur`, `desktop_aur`, `copr`, and `ppa`
- Wayland desktop components (waybar, rofi, swaync) are shared between Hyprland and Niri
- **Keybinding changes**: When modifying keybindings in Hyprland (`home/dot_config/hypr/conf/binds.conf`) or Niri (`home/dot_config/niri/config.kdl.tmpl`), always update `KEYBINDINGS.md` at the repo root to keep the side-by-side reference in sync
