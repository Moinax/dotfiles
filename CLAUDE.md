# CLAUDE.md

<!--
Keep this file short. It loads in full on every request, so the bar for a line
here is "every session needs this, whatever it is working on". Anything tied to
particular files belongs in .claude/rules/ with `paths:` frontmatter, which loads
only when those files are read; anything derivable by reading the code belongs
nowhere.

The one thing a path-scoped rule cannot do is fire before you open the file — so a
trap whose trigger is a *command* (running `dots update`, restarting a service,
checking whether DNS is encrypted) or a file that does not exist yet (a new script,
a new TUI config) stays here, as one line plus a pointer. That is the only reason
anything below names a subsystem.
-->

## Overview

Personal dotfiles for CachyOS (Arch-based), managed with [Chezmoi](https://www.chezmoi.io/), installed through an interactive TUI powered by [gum](https://github.com/charmbracelet/gum). Other Arch derivatives work on a best-effort basis; non-Arch distros are unsupported.

The one exception is `tools/provision-droplet.sh`, which targets Ubuntu because it provisions a *remote* host (`.claude/rules/droplet.md`). Anything that applies to the local machine stays Arch-only.

NVIDIA policy: install no drivers and apply no workarounds (no env vars, modprobe options, or kernel parameters) — CachyOS's stock NVIDIA stack is used as-is.

## Key Commands

`./dots` at the repo root is the single entry point; `home/dot_local/bin/executable_dots`
puts it on `PATH` as `dots`, callable from anywhere. Bare invocation opens a gum menu.

**Do not document its commands here** — run them instead, they are the source of
truth and cost one cheap call: `dots help`, then `dots <command> help`. A copy here
went stale before, listing commands that never existed.

## Architecture

**Installer pipeline**: `dots` → `tools/setup.sh` → `install/installer.sh` → `install/distros/arch.sh` + package YAML files.

**Packages** (`packages/`): every file in `packages/groups/` is one selectable group — `ls` it rather than trusting a list. `packages/arch/base.yaml` is what every machine gets regardless of selection; its `services:` key carries the same `core`/`desktop` purpose gating as its package sections. A service declared by two groups is the smell: each is asserting a baseline rather than a need of its own.

**Chezmoi source** (`home/`): `home/.chezmoiignore` gates configs on template variables (`.install_hyprland`, `.install_development`, …) — one flag per group, plus one per `custom_install` entry marked `chezmoi_flag: true`, so unticking a single app also reaches the files chezmoi owns for it. Both kinds are written by `dots setup` and backfilled by `reconcile_group_flags` — chezmoi *errors* on a key that was never written, so a gate must never reference a flag nothing seeds.

## Conventions

- Shell scripts use `set -e` and the color-coded output helpers from `install/lib/common.sh` (`print_info`, `print_success`, `print_error`, `print_warning`)
- **Never call bare `gum confirm` / `gum choose`** — use `confirm_or_abort` and `choose_or_abort` from `common.sh`. gum reports "no" and "cancelled" with the same status, and Esc sends no signal at all, so a bare call reads a cancel as a deliberate "no" — which has already recorded a group as permanently disabled
- **A privileged step that only `dots setup` owns reaches no machine that already exists.** Setup is not re-run, so shipping one as an installer step plus a dotfile leaves every existing machine with the dotfile half, silently. Put the steps in a lib, call it from setup, and add a `reconcile_*` to `dots update` driven off **machine state** — never off the changed-file list. Six installer-only steps still have this shape (`sync-machine.md` names them)
- **`apply_dotfiles` is the sanctioned apply**, never a bare `chezmoi apply`: it is the apply plus the reconciliations the running desktop needs (`install/lib/post-apply.sh`). Working on the dotfiles means applying by hand, and a hand apply reconciles nothing — so the per-surface rules fall to you
- **Never give a TUI config an explicit background colour.** The panes are translucent, so an explicit bg paints an opaque slab over the wallpaper; a highlight on the focused row is not this defect. Which files encode it, in `.claude/rules/terminal-ui-theming.md`
- **Restarting waybar needs no permission** — `systemctl --user restart waybar.service` is idempotent, and the bar re-execs its modules. Never leave a change merely applied: restart, then look at the result
- **Never `systemctl restart systemd-logind` on a live graphical session** — it revokes the display from the running session and respawns the greeter, and only a reboot clears it. `reload` applies config changes with no session impact; details in `.claude/rules/lock-and-sleep.md`
- **Never report encrypted DNS as working off `resolvectl status`** — it shows the configuration whether or not TLS negotiated. `ss -tn | grep :853` shows the real connection; the rest is in `.claude/rules/dns-encrypted.md`
- **Never `git add`, `git commit` or `git push` here** unless the user or a user-invoked skill asks for it. Finish the work, leave it **unstaged**, and say it is ready — hunk (the user's reviewer) watches unstaged changes, so staging a file removes it from review. That applies to `git add` on its own: staging is not a harmless intermediate step, and not a nicer way to present a rename. Each authorization covers only the change in front of you — "commit this" is not standing consent for a follow-up edit or a fix made seconds later, "commit" never implies push, and pushing one commit never implies pushing the next
- **`dots update` only sees committed `packages/` edits**: the scan is gated on a `packages/*` path in the git diff `SYNCED_COMMIT..HEAD`, never the working tree — so an uncommitted YAML edit is ignored silently, and the anchor still advances. Commit first — *asking* first, per the rule above, which this does not license — or use `dots packages manage`
- **Anything that runs per pane, per session, or on a timer**: multiply one invocation by the real fanout (~15 agent panes) before calling it cheap — `npx -y ccstatusline@latest` in the statusline cost ~1.4 cores. Never launch a long-lived pane command through `npx`/`npm exec` or a language wrapper around a native binary, and prefer `~/.local/share/fnm/aliases/default/bin/` over per-shell paths

## Agent skills

- **Issue tracker**: GitHub Issues on `Moinax/dotfiles`, via the `gh` CLI. See `docs/agents/issue-tracker.md`
- **Triage labels**: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`
- **Domain docs**: single-context — `CONTEXT.md` and `docs/adr/` at the repo root, created lazily. See `docs/agents/domain.md`
