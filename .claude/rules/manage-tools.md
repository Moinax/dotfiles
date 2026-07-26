---
description: How the backup, external-apps, and update helpers behind ./manage.sh actually work — ownership boundaries, state formats, and rate-limit behavior.
paths:
  - tools/backup-projects.sh
  - tools/manage-external-apps.py
  - tools/manage-updates.sh
---

# manage.sh helper internals

## `./manage.sh backup` — `tools/backup-projects.sh`

Repos are NOT archived (only a manifest of remote+branch), just gitignored env/config
files plus `~/.npmrc`, `~/.ssh`, `~/.config/gh` — age-encrypted with a passphrase. User
config in `~/.config/projects-backup/`: `extra-includes` (repo-relative path regexes),
`extra-home-includes` (paths relative to `~`), `extra-exclude-dirs` (dir-name regexes).

`restore --home-only` restores just the home secrets; the installer's SSH setup uses it
to bootstrap a fresh machine (gh OAuth device flow over HTTPS needs no SSH key, so
GitHub login + age passphrase are the only secrets).

## `./manage.sh apps` — `tools/manage-external-apps.py`

A wizard-driven helper (Python, stdlib-only). State files in
`~/.local/state/dotfiles/external-apps/` are bash-quoted `KEY=VALUE` .env files kept
compatible with the former shell version.

Each tracked app follows one release channel, stored as `PRERELEASE=0|1` in its
`sources/*.env`. A missing key reads as stable, so state written before the flag existed
still loads. Stable resolves through `/releases/latest` (GitHub excludes drafts and
pre-releases there); the pre-release channel has no equivalent endpoint, so it reads the
first page of `/releases` and takes the newest non-draft entry — which is the last stable
tag when no newer pre-release exists. The session release cache is therefore keyed by
`(repo, prerelease)`, not by repo alone.

Switching channels is a plain `set-source --prerelease` / `--stable`: every option but
`--name` is inherited from the saved source. Going back to stable leaves a newer
pre-release tag recorded as installed, so the app reports the stable tag as an available
"update" and the next `update` reinstalls it — the downgrade is the intended path back,
not a bug. `set-source` re-validates the saved asset pattern against the target channel
and fails loudly if it matches nothing there.

`latest-release` (used by `manage-updates.sh` for non-app tools) is stable-only by
design — those are curl/npm/cargo binaries, not opt-in nightly channels.

## `./manage.sh update` — `tools/manage-updates.sh`

Deliberately does NOT update the system: pacman + AUR belong to cachy-update (a symlink
to arch-update, which picks up paru on its own). It covers only what cachy-update can't
see — curl binaries, global npm packages, the fnm-managed Node, cargo installs, and
tracked external apps. Anything whose binary turns out to be owned by a pacman/AUR
package is reported as managed and skipped, never refreshed: several entries also exist
as distro packages, and re-running their curl installer would shadow the packaged copy
(`/usr/local/bin` over `/usr/bin`).

GitHub release lookups go through `manage-external-apps.py` (shared concurrent cache) and
use `gh auth token` when available — unauthenticated api.github.com allows only 60
requests/hour, which one scan plus an app check can exhaust, vs 5000 authenticated. An
exhausted quota is reported as such: rows show 'unknown' rather than silently reading as
up to date.
