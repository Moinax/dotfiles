---
description: What `dots backup` archives and what it deliberately does not — the forward-only rule, the sidecar manifests, and what a restore cannot bring back.
paths:
  - tools/backup-projects.sh
---

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

### One archive for every machine, so a backup may only move forward

`create` refuses when the backup repo has commits this machine does not, and says to
`restore` first. That is not politeness about git hygiene: the archive has a single
filename shared by every machine, so backing up from a machine that is behind replaces a
superset with a subset — and the loss is *invisible*, because the push succeeds and HEAD
looks healthy while another machine's secrets survive only in history. Restore-then-backup
is what makes the archive cumulative; a restore pulls the missing repos and secret files
onto this machine, so its own backup then really does contain everything.

Before the check existed, git's own rejection of a diverged push was doing this work by
accident. Do not "fix" that rejection by resetting onto the remote — that was tried, and
it converts a loud failure into a silent overwrite. The check runs before the scan so a
refusal does not cost a passphrase prompt, and an unreachable remote warns instead of
blocking (nothing can be overwritten while nothing can be pushed).

### What a restore does *not* bring back

Repos are re-cloned from `manifest/repos.tsv`, so everything that never left the machine
is gone: **unpushed commits, local-only branches, stashes, submodules, worktrees, hooks,
sparse-checkout and LFS objects.** The design rests on the code itself living on GitHub —
this tool backs up the *secrets beside* the code, not the code. Say so when the question
comes up; `usage()` says it too.

`manifest/remotes.tsv` (`rel`, name, url) is the one exception, and only because a clone
restores `origin` and nothing else: without it a fork came back with no `upstream`, and
`fork_drift` (`sync-machine.md`) then went quiet rather than complaining, "not a fork" being
indistinguishable from "no upstream remote". It is a sidecar rather than a fourth column
in `repos.tsv` because restore reads that file with `read -r rel remote branch`, so a
fourth column would land inside `branch`; a file an older restore does not know about is
simply ignored. Read through `read_config_lines`, which makes a missing manifest a
non-event.

Re-adding is additive by construction — `git remote add` on an existing name fails and
changes nothing — which is why extras are applied to repos that are *already on disk*
too. That is the repair path for a machine restored before this manifest existed.

**Additive means a *wrong* remote is never repaired, only a missing one.** A restore
re-clones only the repos that are absent; for one already on disk it can add the
`upstream` it lacks but cannot notice that its `origin` points somewhere else
entirely. t3code sat on a clone of a different fork of the same upstream for exactly
this reason, and no number of restores was ever going to move it — that is a
`git remote set-url` by hand. Worth saying out loud when someone expects a restore to
have fixed a remote.

Per-repo `dotfiles.*` config keys are deliberately **not** carried. `t3fork` re-asserts
its own `dotfiles.forkUpdate` and `dotfiles.forkBranch` on every run instead, which
self-heals after any loss rather than only after a restore — and losing them costs one
degraded suggestion line (`fork_drift` falls back to a plain `git rebase` against
`HEAD`), not a silent failure.
