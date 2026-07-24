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
./manage.sh update              # check, then pick which non-pacman updates to apply
./manage.sh update check        # report only, change nothing
./manage.sh update all          # apply every available update without prompting
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

# ./manage.sh update (tools/manage-updates.sh) deliberately does NOT update the
# system: pacman + AUR belong to cachy-update (a symlink to arch-update, which
# picks up paru on its own). It covers only what cachy-update can't see — curl
# binaries, global npm packages, the fnm-managed Node, cargo installs, and
# tracked external apps. Anything whose binary turns out to be owned by a
# pacman/AUR package is reported as managed and skipped, never refreshed:
# several entries also exist as distro packages, and re-running their curl
# installer would shadow the packaged copy (/usr/local/bin over /usr/bin).
#
# GitHub release lookups go through manage-external-apps.py (shared concurrent
# cache) and use `gh auth token` when available — unauthenticated api.github.com
# allows only 60 requests/hour, which one scan plus an app check can exhaust,
# vs 5000 authenticated. An exhausted quota is reported as such: rows show
# 'unknown' rather than silently reading as up to date.

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
- **New non-packaged tool**: When adding a tool to `packages/common.yaml` (`tools:`) or a group's `custom_install:`, declare its update metadata too — `binary:` (the executable name, which often differs from the entry name: television ships `tv`), plus `source:` (owner/repo) or `npm:` so `./manage.sh update` can resolve an upstream version. Never let the updater infer the binary from the entry name. `update:` is only ever a command; who owns updates is the separate closed-set `updated_by:` — `self` (the tool updates itself), `app` (tracked by the external-apps tool), `none` (deliberately not updatable), default `dotfiles`. Forgetting the metadata entirely is reported as a gap rather than silently skipped, so `updated_by: none` is how you opt an entry out on purpose
- **Keybinding changes**: When modifying keybindings in Hyprland (`home/dot_config/hypr/conf/binds.lua.tmpl`), always update `KEYBINDINGS.md` at the repo root to keep the reference in sync
- **Herdr layout changes**: When modifying the workspace layout — pane/tab structure or labels in `herdr-agent-layout`, `dev-herdr`, or `herdr-pane-cmd` — run `herdr-clients migrate-layout` after `chezmoi apply`. Existing workspaces persist their old layout (dev-herdr reattaches as-is, never migrates), so without this the previous iteration silently comes back at the next server restart
- **Herdr config.toml changes**: When modifying `home/dot_config/herdr/config.toml` (keybindings, popups, UI), run `herdr-clients reload-config` after `chezmoi apply`. Servers read config.toml only at boot, so without this every running session but the current one keeps the old config. Not a job for `migrate-layout` — that reconciles persisted session.json structure, never the config
- **Anything that runs per pane, per session, or on a timer**: measure one invocation, then multiply by the real fanout before calling it cheap. A normal desktop runs ~15 agent panes across ~15 workspaces, so a per-unit cost is a two-orders-of-magnitude cost in practice. Two instances of this have already been fixed: the statusline ran `npx -y ccstatusline@latest` (0.44s CPU per refresh × every session × every tick ≈ 1.4 cores), and review panes ran hunk through its node wrapper (an idle ~80MB node process per pane ≈ 1GB). Both looked free at one unit. In particular, never launch a long-lived pane command through `npx`/`npm exec` or a language wrapper around a native binary — resolve the real executable, dynamically, with a fallback to the wrapper. Also prefer stable paths over per-shell ones: `~/.local/share/fnm/aliases/default/bin/` survives node upgrades, `/run/user/*/fnm_multishells/*` does not
