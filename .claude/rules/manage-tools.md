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
files plus `~/.npmrc`, `~/.ssh`, `~/.config/gh`, `~/.config/tea/config.yml` — age-encrypted
with a passphrase. Anything holding a bearer token belongs here rather than in the public
chezmoi tree (that's why the tea logins are backed up instead of templated). User
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

### Installed version of a Distrobox app comes from the container, not from state

`VERSION` in `sources/*.env` is only ever written by this tool, so an app that updates
itself inside its container leaves it stale and then reports an update it already has.
(Real case: Falco ships electron-updater, which — after `gksudo`/`kdesudo`/`pkexec`/
`beesu` all miss — falls back to plain `sudo dpkg -i`, and distrobox's passwordless sudo
lets it succeed.) So for `APP_TYPE=distrobox`, `installed_version_for_source()` asks the
container's package database and treats `VERSION` as a fallback only.

That makes the two sides of the comparison different currencies — a GitHub tag (`v4.7.4`)
never matches a native package version (`4.7.4-1`, `1:4.7.4`) literally — so both go
through `normalize_version()`, which drops an epoch, a leading `v`, and a *numeric*
trailing revision only, leaving `1.2.3-beta1` distinct from `1.2.3`.

Which of the two is newer is then decided by **ordering**, not inequality:
`version_is_outdated(installed, latest)` is true only when `latest` sorts above what is
installed. An app that self-updates routinely runs *ahead* of its tracked tag, and under
an equality test that reads as a permanent update the user can apply but never clear —
each `update` re-downloading the older release as a downgrade. `manage-updates.sh`
consumes these rows verbatim and never re-applies its own `version_is_outdated`, so this
is the only place the ordering can be enforced for apps.

`version_key()` deliberately does *not* mirror `sort -V`, which puts `1.2.3-beta1`
*after* `1.2.3`. That is harmless for the self-reported binary versions
`manage-updates.sh` compares, but wrong for release tags: it would offer a beta of a
release already installed the moment a repo is switched to the pre-release channel.
Prerelease suffixes sort before their bare release, and their digits compare numerically
so `rc10` follows `rc9`.

`versions_match()` survives alongside it for the one question that really is equality:
whether the recorded tag may be re-stamped (see below).

The package to query is `PACKAGE_NAME` in `distrobox/*.env`. `save_distrobox_metadata()`
is the sole writer of that file and resolves the key itself — from the exported desktop
id via `dpkg -S` / `rpm -qf` / `pacman -Qoq` — rather than taking it as an argument or
carrying it over, since install, update and adopt can each change the package behind the
desktop id. `distrobox_package_name()` back-fills the same lookup for state files written
before the key existed.

`check-updates` and `list` query **only already-running containers** — a read-only check
must not boot a container as a side effect, so a stopped one falls back to `VERSION`.
`update` passes `allow_start=True`: it is about to enter the container anyway, and
finding the app already current there skips re-downloading a large asset for nothing. It
re-syncs `VERSION` to the tag on the way out, but only when `versions_match()` says the
container really is on that release — an app running ahead of the tag keeps its recorded
value rather than being stamped with a release it does not have.

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
