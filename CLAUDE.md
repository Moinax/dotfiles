# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Personal dotfiles for CachyOS (Arch-based), managed with [Chezmoi](https://www.chezmoi.io/). Uses an interactive TUI installer powered by [gum](https://github.com/charmbracelet/gum). Other Arch derivatives work on a best-effort basis; non-Arch distros are unsupported.

NVIDIA policy: the dotfiles deliberately install no drivers and apply no NVIDIA workarounds (no env vars, modprobe options, or kernel parameters) — CachyOS's stock NVIDIA stack is used as-is.

## Key Commands

`./dots` at the repo root is the single entry point; `home/dot_local/bin/executable_dots`
puts it on `PATH` as `dots`, callable from anywhere. Bare invocation opens a gum menu.

**Do not document its commands here** — run them instead, they are the source of truth
and cost one cheap call: `dots help` for the command list, then
`dots <command> help` (`packages`, `update`, `apps`, `backup`) for subcommands and
flags. A copy in this file went stale before, listing an `apply` and a `diff` command
that never existed.

Internals of the `backup` / `apps` / `update` helpers (ownership boundaries, state
formats, rate limits) live in `.claude/rules/manage-tools.md`, loaded when you touch
`tools/backup-projects.sh`, `tools/manage-external-apps.py`, or `tools/manage-updates.sh`.

## Architecture

### Installer pipeline
`dots` → `tools/setup.sh` → `install/installer.sh` → `install/distros/arch.sh` + package YAML files

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
- **Both of the above are automatic in every `dots` apply** — `apply_dotfiles` in `install/lib/post-apply.sh` is `chezmoi apply` + the reconciliations, and `dots update` fires them off the list of files it changed. Never call `chezmoi apply` from a script without it. The rules still stand for you, because working on the dotfiles means applying by hand, and a hand apply reconciles nothing
- **Herdr agent tabs are named after the task, not the provider**: a tab label is "fix-flaky-updater-tests", set from the name typed in the ctrl+alt+a picker or written later by `herdr-agent-title` (a Claude Code Stop/SessionStart hook that follows Claude's own session title). So never identify an agent tab by parsing its label — go through its panes (`pane.agent`, or the recorded role — see `herdr-pane-role`), the way `herdr-nav agent-tab` picks its insertion point
- **What a herdr pane is FOR lives in `herdr-pane-role`, never in a label**: every visible name (pane, tab, workspace) is cosmetic and safe to rename, because `revive-panes` rebuilds commands from the recorded role. Anything that creates a pane must record its role in the same breath — that is the one rule. Why herdr offers no usable slot of its own, the role vocabulary, and who writes when are in `.claude/rules/herdr-layout.md`, loaded when you touch the `herdr-*` / `dev-herdr` / `dev-agent-argv` scripts
- **Never give a terminal UI an explicit background colour**: the panes are translucent, and a terminal only makes its *default* background see-through — a cell carrying an explicit bg is painted fully opaque, so it renders as a solid slab floating over the wallpaper. Matching the terminal's base colour does not help, it only changes the slab's hue; the fix is always to leave the background unset. This is why `hunk/config.toml.tmpl` and `tuicr/config.toml.tmpl` set `transparent_background = true`, `nvim/lua/polish.lua` clears `Normal`/`NormalFloat`, and `starship.toml.tmpl` / `ccstatusline/settings.json.tmpl` carry no bg at all (ccstatusline's `overrideBackgroundColor` plus `flexMode: "full"` plated the whole statusline). A background on the *focused row only* — `gh-dash`'s `background.selected`, a yazi mode chip — is a highlight, not this defect, and stays
- **Anything that runs per pane, per session, or on a timer**: measure one invocation, then multiply by the real fanout before calling it cheap. A normal desktop runs ~15 agent panes across ~15 workspaces, so a per-unit cost is a two-orders-of-magnitude cost in practice. Two instances of this have already been fixed: the statusline ran `npx -y ccstatusline@latest` (0.44s CPU per refresh × every session × every tick ≈ 1.4 cores), and review panes ran hunk through its node wrapper (an idle ~80MB node process per pane ≈ 1GB). Both looked free at one unit. In particular, never launch a long-lived pane command through `npx`/`npm exec` or a language wrapper around a native binary — resolve the real executable, dynamically, with a fallback to the wrapper. Also prefer stable paths over per-shell ones: `~/.local/share/fnm/aliases/default/bin/` survives node upgrades, `/run/user/*/fnm_multishells/*` does not

## Git

- **Never `git add`, `git commit` or `git push`** unless the user or a user-invoked skill asks for it. Finish the work, leave it **unstaged** in the working tree, and say it is ready — hunk (the user's reviewer) watches unstaged changes, so staging a file removes it from review. This applies to `git add` on its own: staging is not a harmless intermediate step, and not a nicer way to present a rename.
- **Each authorization covers only the change in front of you.** "Commit this" is not standing consent for the rest of the session, for follow-up edits, or for a fix made seconds later; ask again. "Commit" never implies push, and "push" of one commit never implies pushing later ones.
- **Never create a branch or a worktree** unless the user or a user-invoked skill asked for it. Work on the current branch, even when the change feels branch-worthy — say so and let the user decide.
