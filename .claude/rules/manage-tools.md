---
description: How the backup, external-apps, and update helpers behind dots actually work — ownership boundaries, state formats, and rate-limit behavior.
paths:
  - tools/backup-projects.sh
  - tools/manage-external-apps.py
  - tools/manage-updates.sh
  - tools/sync-machine.sh
  - install/lib/post-apply.sh
---

# dots helper internals

## `dots update` — `tools/sync-machine.sh`

The orchestrator, and the command to run day to day. `dots setup` answers "what
should this machine be?" once and is not built to be re-run — it re-asks every
question, so a laptop that never wanted the gaming group had to say so again
every time. This asks the smaller question: what has the repo gained since this
machine last agreed with it?

Phases: pull → new groups → new packages → `chezmoi apply` → tool refresh
(`tools/manage-updates.sh`, still reachable alone as `dots update tools`) →
`run_post_apply` → re-stamp the profile.

**The anchor is the whole design.** `SYNCED_COMMIT` in
`~/.local/state/dotfiles/profile.env` (see `profile_get`/`profile_set` in
common.sh) records the commit this machine last agreed with, and the delta is
computed against it. Without an anchor the only question available is "what is
missing here?" — which cannot tell a package that is new from one the user
removed on purpose, and therefore re-offers the removed one forever. That is
also why this does not replace `dots packages sync`: the full "everything
missing" scan stays, as the explicit catch-up for a machine that has drifted.

The delta is computed by exporting `packages/` at the anchor with `git archive`
and running the *same enumerators* over both trees, rather than diffing text —
so reformatting a list, or moving an entry between groups, is not mistaken for
new packages. Those enumerators are `base_desired_packages` and
`get_group_packages` in common.sh, the pair `dots packages sync` and the manage
view also go through, and they take the packages root as an argument precisely
so one walk can serve both a checkout and an exported older commit. Do not grow
a second walk here: the first version of this file did, read a
`packages/base.yaml` that has never existed (the real path is
`packages/arch/base.yaml`, keyed `core`/`aur`/`desktop`/`desktop_aur`), and
silently returned nothing for the base half of every delta.

`declared_packages_at` emits `pkg<TAB>group-file`, the file empty for a distro
package and set for a `custom_install` entry — the two have different install
paths and different installed-checks, so the caller needs the split anyway, and
carrying it out of the walk is what avoids re-parsing every group file to
rebuild it. Group enabledness is always read from this machine's chezmoi data,
never from the old file, so a group disabled here stays out of both sides.

Two states are deliberately not errors, because both are routine in a repo whose
history is kept linear by rebasing: **no anchor** (first run after this landed —
re-anchors silently and points at `dots packages sync` for the catch-up) and
**an anchor that no longer exists** (rewritten by a rebase — warns, then
re-anchors). Both skip the delta rather than guessing.

A dirty tree asks before stashing. The dotfiles are reviewed with hunk, which
watches *unstaged* changes, so autostashing a review in progress out from under
the user is not an acceptable default.

## `install/lib/post-apply.sh`

What has to happen after any `chezmoi apply` for the running desktop to show it:
Hyprland reload (its mid-apply autoreload fails on `conf/general.lua` requiring a
`conf/theme.lua` not yet written), herdr `reload-config`/`migrate-layout`, waybar
restart. Shared because these used to live in the installer only — the one script
you stop running once the machine is set up.

`run_post_apply` takes the list of files an update changed and fires only the
reconciliations that list justifies; called with no arguments (a full install,
where there is no "before") it runs all of them. Waybar goes last, after the
caller's tool refresh: the bar's custom modules are long-lived `exec` children
(`vibewatch status --watch` streams until killed), so a bar restarted before the
binary underneath it moves keeps running the old one.

**`apply_dotfiles` is the sanctioned apply**, and `chezmoi apply` should not
appear anywhere else: it is `chezmoi_apply` + `run_post_apply`, so "an apply is
always reconciled" is an invariant rather than a convention each caller has to
remember. `dots reconfig` and `dots packages` both used to forget it, and they
apply at exactly the moment a group flag has just rewritten the bar and the hypr
tree. The one exception is `dots update`, which calls the two halves itself
because the tool refresh has to land between them — see the waybar rule above.

The herdr layout trigger matches **any** `executable_herdr-*` / `dev-herdr`
script, not the three that happen to build panes today. A missed
`migrate-layout` does not fail; it brings the old layout back at the next server
restart, hours later, with nothing tying it to the update that caused it. A name
list would go stale silently, and over-triggering costs one idempotent call that
the full-install path already makes unconditionally.

## `dots backup` — `tools/backup-projects.sh`

Repos are NOT archived (only a manifest of remote+branch), just gitignored env/config
files plus `~/.npmrc`, `~/.ssh`, `~/.config/gh`, `~/.config/tea/config.yml` — age-encrypted
with a passphrase. Anything holding a bearer token belongs here rather than in the public
chezmoi tree (that's why the tea logins are backed up instead of templated). User
config in `~/.config/projects-backup/`: `extra-includes` (repo-relative path regexes),
`extra-home-includes` (paths relative to `~`), `extra-exclude-dirs` (dir-name regexes).

`restore --home-only` restores just the home secrets; the installer's SSH setup uses it
to bootstrap a fresh machine (gh OAuth device flow over HTTPS needs no SSH key, so
GitHub login + age passphrase are the only secrets).

## `dots apps` — `tools/manage-external-apps.py`

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

## `dots update` — `tools/manage-updates.sh`

Deliberately does NOT update the system: pacman + AUR belong to cachy-update (a symlink
to arch-update, which picks up paru on its own). It covers only what cachy-update can't
see — curl binaries, global npm packages, the fnm-managed Node, cargo installs, and
tracked external apps. Anything whose binary turns out to be owned by a pacman/AUR
package is reported as managed and skipped, never refreshed: several entries also exist
as distro packages, and re-running their curl installer would shadow the packaged copy
(`/usr/local/bin` over `/usr/bin`).

### `refresh NAME…` — the installer's post-install pass

`dots setup` only ever fills gaps: a `custom_install`/`tools` entry whose `check` passes is
left at whatever build it was first installed with, since `check` asks *whether* a tool
exists and never *which version*. So a long-lived machine kept its original binary across
every re-run (a July vibewatch survived a `dots setup` three releases later). `refresh`
closes that: the installer collects the entries it skipped into `PREINSTALLED_TOOLS` and
hands them here, and one `gum confirm` covers the whole batch — a setup re-run started for
an unrelated reason must not silently spend minutes on a `cargo install --git`.

The name list sets `ONLY_NAMES`, filtered in `collect_section_candidates` *before* the
per-entry yq read, so a two-name refresh doesn't pay for a twenty-entry scan. A filtered
run also drops the Node candidate (moving Node strands the global npm packages installed
against the old one) and the external-apps check (`dots apps`' inventory, never a yaml
entry, and it spends the same GitHub quota the filtered lookups need).

Ordering in the installer matters and is not incidental: the refresh runs *after*
`setup_dotfiles`, because `group_enabled` reads chezmoi data that `setup_dotfiles` has only
just written — an earlier scan finds no enabled group and reports nothing to do. The waybar
restart then runs *after* the refresh, because the bar's custom modules are long-lived
`exec` children (`vibewatch status --watch` streams until killed), so a bar restarted
before the binary moves keeps running the old one.

GitHub release lookups go through `manage-external-apps.py` (shared concurrent cache) and
use `gh auth token` when available — unauthenticated api.github.com allows only 60
requests/hour, which one scan plus an app check can exhaust, vs 5000 authenticated. An
exhausted quota is reported as such: rows show 'unknown' rather than silently reading as
up to date.
