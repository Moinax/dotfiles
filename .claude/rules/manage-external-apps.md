---
description: How `dots apps` tracks external apps — state file format, release channels, and version comparison across GitHub tags and container packages.
paths:
  - tools/manage-external-apps.py
---

## `dots apps` — `tools/manage-external-apps.py`

A wizard-driven helper (Python, stdlib-only). State files in
`~/.local/state/dotfiles/external-apps/` are bash-quoted `KEY=VALUE` .env files kept
compatible with the former shell version.

Each tracked app follows one release channel, stored as `PRERELEASE=0|1` in its
`sources/*.env`. A missing key reads as stable, so state written before the flag existed
still loads. Stable resolves through `/releases/latest` (GitHub excludes drafts and
pre-releases there); the pre-release channel has no equivalent endpoint, so it reads the
first page of `/releases` and takes the newest non-draft entry — which is the last stable
tag when no newer pre-release exists.

`TAG_PREFIX` in the same file (`--tag-prefix`, empty = no filter) narrows every lookup to
releases whose tag starts with it, and forces that same listing path since
`/releases/latest` cannot be filtered. **It is not a nicety — a repo that cuts one release
per platform is untrackable without it.** getagentseal/codeburn publishes Linux under
`desktop-v*`, macOS under `mac-v*` and Windows under `windows-v*`, so `/releases/latest`
is whichever platform shipped last: the install fails as "no Linux build in this release",
and an app pinned by hand would compare its `desktop-v…` tag against a `windows-v…` one
and read as outdated forever. On the stable channel the listing scan also has to re-apply
the pre-release test that `/releases/latest` was doing implicitly, or a tag prefix would
quietly start following betas.

The session release cache is therefore keyed by `(repo, prerelease, tag_prefix)`, not by
repo alone.

**A tag prefix must come off before the tag is read as a version**, which is what
`strip_tag_prefix()` is for and why `version_is_outdated`, `versions_match` and
`derive_asset_pattern` all take one. It is not cosmetic — the prefix otherwise lands
inside the version string and hijacks the `partition("-")` in `version_key()`:
`desktop-v1.0.0` parses as release `desktop` (empty numeric part) plus suffix `v1.0.0`.
Two things break at once. It sorts below every bare version, so a Distrobox app — whose
installed version comes from the container's package database and is therefore never
prefixed — reads as current against every future release and silently stops updating. And
`desktop-v1.0.0-beta1` sorts *above* `desktop-v1.0.0`, inverting the single ordering
`version_key()` exists to guarantee. Both sides of every comparison go through the strip,
including the side that never carries a prefix, so that neither can be forgotten.

The same applies to `derive_asset_pattern`: an asset is named after the version, never
after the platform tag it is published under, so without the strip `desktop-v0.9.20` finds
nothing in `CodeBurn-0.9.20.AppImage` and the pattern gets pinned to that exact filename —
matching no later release and failing every update in `pick_release_asset`.

**Only the CLI can create a tag-prefixed app.** The interactive wizard carries a saved
`TAG_PREFIX` over on `set-source` rather than prompting for it — it describes how the repo
publishes, which the wizard cannot usefully change — but "Install from GitHub release" has
no field for one. A new per-platform repo has to go through
`dots apps install-github … --tag-prefix …`.

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
