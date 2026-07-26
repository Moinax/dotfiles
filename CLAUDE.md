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
```

Internals of the `backup` / `apps` / `update` helpers (ownership boundaries, state
formats, rate limits) live in `.claude/rules/manage-tools.md`, loaded when you touch
`tools/backup-projects.sh`, `tools/manage-external-apps.py`, or `tools/manage-updates.sh`.

## Architecture

### Installer pipeline
`manage.sh` → `tools/setup.sh` → `install/installer.sh` → `install/distros/arch.sh` + package YAML files

### Package definitions (`packages/`)
YAML files define packages (key `arch`, plus `aur`/`desktop_aur` in base). Groups (`packages/groups/`) are selectable during install: `hyprland`, `development`, `gaming`, `multimedia`, `productivity`.

### Chezmoi source directory (`home/`)
The `home/` directory is the Chezmoi source.
- `home/.chezmoiignore` — conditionally excludes configs based on template variables like `.install_hyprland`, `.install_development`, `.install_productivity`

## Conventions

- Shell scripts use `set -e` and consistent color-coded output helpers (`print_info`, `print_success`, `print_error`, `print_warning`)
- **New non-packaged tool**: adding one to `packages/common.yaml` or a group's `custom_install:` requires update metadata (`binary:`, plus `source:` or `npm:`) — see `.claude/rules/package-metadata.md`, loaded when you touch `packages/`
- **Keybinding changes**: When modifying keybindings in Hyprland (`home/dot_config/hypr/conf/binds.lua.tmpl`), always update `KEYBINDINGS.md` at the repo root to keep the reference in sync
- **Herdr layout changes**: When modifying the workspace layout — pane/tab structure or labels in `herdr-agent-layout`, `dev-herdr`, or `herdr-pane-cmd` — run `herdr-clients migrate-layout` after `chezmoi apply`. Existing workspaces persist their old layout (dev-herdr reattaches as-is, never migrates), so without this the previous iteration silently comes back at the next server restart
- **Herdr config.toml changes**: When modifying `home/dot_config/herdr/config.toml` (keybindings, popups, UI), run `herdr-clients reload-config` after `chezmoi apply`. Servers read config.toml only at boot, so without this every running session but the current one keeps the old config. Not a job for `migrate-layout` — that reconciles persisted session.json structure, never the config
- **Anything that runs per pane, per session, or on a timer**: measure one invocation, then multiply by the real fanout before calling it cheap. A normal desktop runs ~15 agent panes across ~15 workspaces, so a per-unit cost is a two-orders-of-magnitude cost in practice. Two instances of this have already been fixed: the statusline ran `npx -y ccstatusline@latest` (0.44s CPU per refresh × every session × every tick ≈ 1.4 cores), and review panes ran hunk through its node wrapper (an idle ~80MB node process per pane ≈ 1GB). Both looked free at one unit. In particular, never launch a long-lived pane command through `npx`/`npm exec` or a language wrapper around a native binary — resolve the real executable, dynamically, with a fallback to the wrapper. Also prefer stable paths over per-shell ones: `~/.local/share/fnm/aliases/default/bin/` survives node upgrades, `/run/user/*/fnm_multishells/*` does not
