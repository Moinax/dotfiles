---
description: How `dots update` syncs a machine — phase order, the SYNCED_COMMIT anchor, the package delta and its removal guards, and fork drift.
paths:
  - tools/sync-machine.sh
---

## `dots update` — `tools/sync-machine.sh`

The orchestrator, and the command to run day to day. `dots setup` answers "what
should this machine be?" once and is not built to be re-run — it re-asks every
question, so a laptop that never wanted the gaming group had to say so again
every time. This asks the smaller question: what has the repo gained since this
machine last agreed with it?

Phases: system update (`cachy-update`) → new groups → package delta →
`chezmoi apply` → tool refresh (`tools/manage-updates.sh`, still reachable alone as
`dots update tools`) → `run_post_apply` → login wallpaper → re-stamp the profile →
report fork drift → report a waiting backup.

### The system update runs first, and refusing it is an answer

`update_system_packages` calls `cachy-update` (falling back to `arch-update`, which
is what it symlinks to) before anything installs, and where neither exists — plain
Arch, EndeavourOS, Garuda — it falls through to **`update_system confirm`**, the
distro layer's own upgrade in `install/distros/arch.sh`, the one `dots setup` opens
with and `_recover_stale_db` falls back on. pacman and AUR still *belong* to those
tools — nothing here reimplements an upgrade, and `manage-updates.sh` still covers
only what they cannot see. Running it first is what gives the package delta a
database no older than the mirrors: install against a few-day-old one and every
mirror 404s on a filename that has been rebuilt, which is the failure
`_recover_stale_db` (arch.sh) recovers from after the fact and now has one less
reason to see. Skipping the machine with no updater wrapper meant skipping the one
with the least fresh database of all.

No prompt of ours sits in front of either — both show the transaction and ask for
themselves, and a refusal is a decision, not a failure: the sync goes on to the
packages, the apply and the tools. Only 130 ends the run (the user stopping it),
same rule as `update_tools`. **The two paths report a refusal differently, and that
is the tool's doing, not a choice here:** cachy-update exits **4** for "aborted", so
it is recognised exactly; paru and pacman exit **1** both when you decline and when
the upgrade fails, so the fallback path can only warn in terms that cover both
("declined, or the upgrade failed"). `confirm` is the load-bearing argument on that
call — the argument-less `update_system` is `--noconfirm`, which would be the one
thing this phase must never do. Skipped entirely without a tty: it needs a sudo
password and asks its own questions, so under a pipe it would sit on a prompt nobody
can see.

### The pull is not one of those phases

`dots` runs `sync-machine.sh pull` as its own process and waits for it to exit
before starting the sync. Bash parses a script before running it, so while the
pull lived inside the sync every function was the pre-pull one: a run that fetched
a fix to `dots update` applied the old behaviour anyway. That cost a real package —
`python-pyqt6-webengine` was offered for removal, and removed, by the pre-pull walk
that could not yet see a `requires_packages`, in the very run that pulled the fix.
Every other phase can be re-run; a removal cannot.

Two processes rather than `exec`: two of `do_update`'s three callers are menu loops
that need control back. Only the full sync pulls — `tools` and `help` never touched
the repo. Running `tools/sync-machine.sh` by hand therefore does not pull, which is
the one behaviour this moved; `./dots` is the entry point.

The fork and backup reports run after the anchor is stamped but before the final
verdict, which has to stay the last thing on screen.

`report_backup_available` names a backup another machine pushed that this one has not
restored. It is the *incoming* direction, deliberately — not a "you should back up"
reminder. Two reasons it earns a line in a sync: the archive is cumulative, so a newer one
holds secrets this machine lacks; and `dots backup create` refuses while behind, so a
machine in this state cannot back up at all until it restores. Silent when caught up,
when the remote is unreachable, and when `~/Backups/projects-backup/.git` is absent
(backups are not set up on this machine).

It is the one phase here that may *act*, and only with a tty: on a terminal it offers to
run the restore, everywhere else it prints the command and stops. A restore re-clones repos
and writes secrets to disk, so starting one where nobody can answer is not a default worth
having — the same `[ -t 0 ]` reasoning as `t3fork install`'s restart prompt. Declining
prints the command too. A failed restore warns rather than failing the sync: it runs after
the anchor is stamped, so the cost is the restore and nothing else.

### The two reconcilers that moved out

`reconcile_login_wallpaper` and `reconcile_encrypted_dns` are phases of this
script, but their subject matter lives with the thing they configure:
`.claude/rules/login-wallpaper.md` and `.claude/rules/dns-encrypted.md`. Both
share one shape worth stating here, because it is the reason they exist at all
and it applies to the next one too.

**A privileged step that only `dots setup` owns reaches no machine that already
exists.** Setup is not re-run, so a feature shipped as an installer step plus a
dotfile leaves every existing machine with the dotfile half and none of the
privileged half — silently, because every piece involved is behaving as designed.
The fix is always the same: the steps go in a lib, `dots setup` calls it, and a
`reconcile_*` here offers it off **machine state**, never off `CHANGED_FILES`
(the anchor moves past the commit long before anyone notices the symptom).

**That is not a future risk, it is the current state of six other steps.**
`configure_localsend_firewall`, `tune_boot_performance`, `setup_clamav`,
`setup_biometric`, `setup_ssh` and `setup_plymouth` are all privileged, one-time,
and reachable from nothing but `dots setup` — grep `tools/` and `install/lib/`
for any of them and you get nothing. `setup_biometric` is the live instance worth
knowing about: enabling the `biometric` group later through `dots packages manage`
installs `fprintd` and reconciles the declared services but never lays down the
PAM stack, the polkit rule or the enrolment unit — the wallpaper bug's exact
shape, already shipped. Anything moved out of that list wants the same treatment.

**Neither asks first.** sudo already prompts for a password, which is the same
question with a way out built in, and the alternative to answering it is a broken
machine. Both are gated on a tty, since sudo under a pipe would sit unanswered.

### Fork drift is discovered, not declared

`fork_drift` treats the `upstream` remote as the registry: any main checkout
under the `dev-projects root` tree that has one is a fork, so a new one is picked
up without touching the dotfiles. It reports and never acts — a rebase stops on
conflicts and wants a human — and it runs after the anchor is stamped but
*before* the final verdict, so it can neither leave a sync half-done nor trail a
warning after a green "Machine in sync". Every failure path is a silent
`continue`: offline, a vanished upstream, a repo mid-rebase — none is worth a
warning on a sync that already succeeded, and the next run asks again.

The root comes from `dev-projects root`, the single source of truth for the
project tree — not a knob of its own, which is what made a machine with
`DEV_PROJECTS_ROOT` set invisible to this check. `-type d` on the walk is
load-bearing in the other direction: linked worktrees share the main checkout's
remotes, so without it a fork with three worktrees reports the same drift four
times under four names.

The command it prints comes from `git config dotfiles.forkUpdate` **in the fork**,
not from a table here, because rebasing is rarely the whole job (t3code has to
rebuild and reinstall an AppImage, which only `t3fork` knows) — and because a
table of fork→command in the dotfiles is the t3code-specific coupling this was
built to avoid. Without the key it falls back to a plain `git rebase`.

**Which branch to measure is the fork's answer too**, `dotfiles.forkBranch`,
falling back to `HEAD`. `HEAD` alone is right only for a fork whose trunk *is* its
patch branch: a fork maintained by rebasing one branch leaves every other branch
stale on purpose, so counting whatever happens to be checked out measures a branch
nobody maintains. A number that looks like a finding and is about the wrong branch.

**Two states are reported instead of counted**: a rebase stopped on a conflict, and
a declared branch missing from the checkout (what a clone of the wrong fork looks
like — that same t3code had `origin` on a different fork of the same upstream). Both
are read from local files, before the fetch, because a fork stuck in either is stuck
until somebody acts, which means paying that fetch on every run forever. The rebase
one matters most because it is invisible: git moves the branch ref only when the
rebase *completes*, so the count comes out identical and the fork reads exactly as it
did. In both, the thing to avoid is a plausible number.

Use `rev-parse --path-format=absolute --git-path` to find the rebase, never the bare
form — it answers relative to the repo, so a walk running from wherever `dots update`
was started tests a path under the *caller's* cwd and finds no rebase anywhere, ever.

Rows carry the repo path rather than its name, so the reporter can build the
`git -C <repo> rebase --continue` line itself, and every row still names the fork's
own command. Naming it on the rebase row is not redundant: once the rebase finishes
the drift is zero and the fork drops out of the report entirely, so that is the last
chance to say the AppImage still needs rebuilding.

`t3fork` refuses to build on a partially replayed tree, and the rest of its
internals — taking in origin before a rebase, the leased force-push, where the
config keys are written — are in `t3-code-fork.md`, with the script they belong
to.

The default branch is resolved by trying `upstream/HEAD`, then `main`, then
`master`, through `rev-parse --verify` rather than `symbolic-ref`: a *dangling*
`upstream/HEAD` (its branch deleted upstream) resolves fine for `symbolic-ref`
and then fails the count, which dropped the fork from the report entirely.

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

The delta scan runs behind `spin_capture`, which is why `package_delta` is a
separate function that prints its answer instead of filling arrays: a
`git archive` export plus two full yq walks plus the installed-checks is ~10s of
silence otherwise. Two consequences the split forces — it prints no diagnostics
of its own (the spinner discards that pass's stderr, so an unreadable anchor is
exit status 1 and `sync_packages` words the warning), and the installed indexes
stay inside the background pass, which is safe only because nothing after the
scan reads them.

**The delta runs both ways off that one scan.** `package_delta` emits
`op<TAB>pkg<TAB>detail`, `op` being `add` or `drop`; `sync_packages` splits the
stream by op and passes each half its own rows — to `install_new_packages` then
`remove_dropped_packages`, in that order, so a replacement lands before the
thing it replaces leaves. The two sets are each other's complement — `seen` is
the whole current declaration by the time the add loop ends — so the drop half
costs no third walk, and asking the question backwards in a scan of its own
would have paid the ~3s twice for an answer already in memory.

Those rows are **arguments, not shared scope.** The halves were briefly two
argument-less functions reading the caller's arrays, which bash permits since
`local` is dynamically scoped — but it is a contract that exists only in a
comment, and renaming an array in `sync_packages` would have left the other half
reading nothing, silently and with no signal at the call site. Which name a
dropped package left the yaml under is settled before `list_explicit_packages`
runs, too: that is pure array work, so a run where the repo only *gained*
packages — much the commoner case — never spawns the install-reason query.

Four things guard the removal, because it is the one phase here that cannot be
undone by re-running:

- **A dropped `custom_install` entry is reported, never removed.** It was
  installed by a bespoke `install_cmd` and there is no counterpart. Reported
  rather than silently skipped: a curl-installed binary nothing declares any
  more is exactly what no one remembers to clean up. The wording is
  `warn_custom_uninstall` in common.sh, shared with both removal paths in
  manage-packages.sh — the three sites used to say the same thing three
  different ways, which reads as three rules instead of one repeated fact. If
  these entries ever gain an `uninstall_cmd`, that helper is the single place
  that stops being true.
- **Installed-as-a-dependency is left alone.** `list_explicit_packages`
  (arch.sh) is the filter. `expac` itself reads as a dependency on this machine
  because cachyos-fish-config requires it, so a yaml dropping it would be no
  reason at all to take it off the disk.
- **pacman decides what is removable, not us.** `plan_removal` is
  `pacman -Rs --print`, a query needing no root: it returns the full transaction
  for the preview *and* fails when something else still requires a target. On
  failure the whole batch is retried one at a time, so one blocked package does
  not veto the rest, and the blocked ones are named in a warning.
- **The preview shows the cascade.** `-Rs` drags in dependencies nothing else
  needs — and those are listed separately,
  because they are the part the user did not ask for and cannot predict.

**A declined removal does not `mark_sync_shortfall`, and that asymmetry is
deliberate.** The flag means "this machine is missing something the repo asks
for", which a kept package is not. For an install, "no" fairly reads as "not
yet" and the anchor is held back so it is offered again; for a removal, "no"
means *keep it*, and re-asking at every update would be the exact nagging the
anchor exists to prevent. Letting the anchor advance past the commit that
dropped the package is what makes the answer stick.

**A declared name is not necessarily a removable one.** `installed_package_aliases`
(arch.sh) maps every name a package answers to — its own, its provides, its
replaces — onto the installed package, and the drop rows carry that resolved
name. The dotfiles declared `rofi-wayland` while the machine held `rofi`, which
replaced it, and `pacman -R rofi-wayland` is a "target not found": without the
mapping the feature would have silently skipped the very package that motivated
it. **A package's own name always beats another package's `provides`**, and that
rule lives in the primitive rather than in the caller's fold: the raw emitter is
a multimap whose keys can collide — `dbus-broker-units` provides `dbus-units`,
which is itself installed here — so `installed_package_aliases` resolves it
before emitting, one row per name. `list_installed_packages` is now `cut -f1` of that map rather than a second
parser of the same three fields — the old fallback half never emitted a
package's own name (a separate `pacman -Qq` was bolted in front of it), which is
the drift a rarely-taken branch invites.

**One yq call per group file, and it is not an optimisation you may undo.**
`group_declared_lists` (common.sh) reads *everything* a caller can want from a group
file in a single query, as tagged rows: `N` name, `I` icon, `E` pkg=description,
`D` desktop_only, `C` custom name, `P` package. Two consumers sit on it —
`classify_declared_rows` (stdin → `pkg<TAB>custom`, applying the terminal-install
`desktop_only` filter) and `load_group_meta` (sets `GROUP_NAME`, `GROUP_ICON`,
`DESCRIPTIONS`, and leaves the raw rows in `GROUP_ROWS` so the same read can be
classified without touching the file again). `group_declared_packages` is the two
composed; `get_group_packages` is that, names only.

The split exists so a view can pay once: every `dots packages` screen used to open
by fetching the name, the icon, the descriptions and a package list separately —
four invocations per group, ~5.9s of a 7.1s catalogue scan, now 1.2s. The three
helpers that served the first three are deleted; `load_group_meta` is the one read.
`group_package_states` takes those rows as an optional second argument for the same
reason. Callers take the custom flag from the row instead of parsing the names again
— `declared_packages_at`, `group_package_states` and `build_manage_json` all used to. This machine has **python-yq**, ~180ms of interpreter start
per call, so the invocation count dominated the scan. `base_desired_packages` is one call for
the same reason. Neither has a yq-less fallback any more: `tools/setup.sh` installs
yq alongside gum, before the installer's first parse, so every parser can assume it.
`list_installed_packages` prefers `expac -Q '%n %S %R'` (48ms) over the
`pacman -Qi | awk` pass (830ms) for the identical name+provides+replaces set —
which is why base.yaml declares expac; it was previously present only as somebody
else's dependency.

**Re-anchoring is conditional, and that is part of the anchor's meaning.**
`mark_sync_shortfall` (common.sh) is set by whatever leaves the machine without a
declared package — a failed `_install_with_db_recovery`, a declined delta, an
`install_custom_pkg` that skipped or failed — and `record_synced_state` declines to
stamp while it is set. Stamping HEAD anyway would compute
every future delta from a commit the machine never caught up with, and the skipped
packages would never be offered again — the anchor would claim they had been dealt
with. Everything else in the run still happens; the cost of holding it back is one
re-offer. Note the failure path was worse than a wrong anchor before: the call was
`[ n -gt 0 ] && install_packages …`, a bare failing `&&` list under `set -e`, so
one 404 exited the script mid-phase and skipped the apply, the tool refresh, the
surface reloads and the stamp — silently, since the exit looked like a clean end.

The flag lives in common.sh rather than in this script because **`dots setup` had
the same question and answered it the other way**: `installer.sh` stamped the anchor
even while `INSTALL_WARNINGS` held "Some base packages failed to install", so a
package that failed during setup was never offered by any later delta — the delta
only looks forward from the anchor. Marking the shortfall where it happens and
reading it in the single writer of the anchor is what stops the two commands
disagreeing. It is per-process on purpose: it describes this run, and the next run
that installs everything it was asked to has nothing to report.

The commonest reason that install fails is a stale pacman database: only `dots
setup` guarantees a fresh one (it opens with `update_system`), so the paths you run
months later ask the mirrors for versions they have already rebuilt and every one
404s. `install_packages` recovers by offering the upgrade — see
`_recover_stale_db`/`_install_with_db_recovery` in `install/distros/arch.sh`, which
own it for all three install entry points. Offered on the failure that proves it is
needed, never run up front, so the rule that pacman/AUR upgrades belong to
cachy-update still holds.

**Anything other than taking that upgrade ends the run** — the button, Esc,
Ctrl+C, a failed upgrade, or no TTY to ask on. `_recover_stale_db` returns 0 or
does not return, and every `install_packages` call site is a plain call in the main
shell, so its `exit` really does end the process. A stale database is not a
shortfall the machine can carry like a broken AUR build: it means none of the
repo's packages can be installed here, so continuing would apply the configs, the
tool refresh and the reloads around a hole and then report success. That is the
state to avoid at all costs — a machine that looks synced and is missing what the
configs it just applied were written for. `DELTA_APPLIED` covers the shortfalls
that *are* carryable; this one is not one of them.

Prompts go through `confirm_or_abort`, and pickers through `choose_or_abort`, not
the bare gum commands: gum reports "no" and "cancelled" both as a non-zero status,
and cancelling with Esc sends no signal at all, so the interrupt trap never sees it
and bare `gum confirm` reads a cancel as a deliberate "no". Where the two answers
differ ("Install them?", the stash prompt) that let a cancel skip a phase the user
meant to stop; where the answer is persisted it was worse — a cancelled group-flag
prompt recorded the group as disabled permanently, since answering either way
writes the flag and never asks again. The one deliberate exception is
`installer.sh`'s "Cancel installation?", where stopping *is* the yes answer.

`choose_or_abort` returns its choice through a **variable name**, like
`spin_capture`, and that is not a style preference: a helper whose output is
captured (`sel=$(… | choose_or_abort …)`) runs inside a command substitution, so
its `exit` would end that subshell only and leave the caller going with an empty
selection. Feed its options in with a redirect, never a pipe, for the same reason.

`install_interrupt_trap` installs a trap in **every** shell. It used to skip when it
found its own exported marker already set, which meant no script `dots` runs ever
had one — `dots` installs the first, and every tool is its child. gum exits 130
rather than dying from the signal, and bash only exits by itself when the foreground
command was *killed*, so those shells carried on with an answer nobody gave. The
marker still decides who prints: inner shells stop silently, the outermost one
announces (`tools/manage-external-apps.py` reads it for the same reason).

Two states are deliberately not errors, because both are routine in a repo whose
history is kept linear by rebasing: **no anchor** (first run after this landed —
re-anchors silently and points at `dots packages sync` for the catch-up) and
**an anchor that no longer exists** (rewritten by a rebase — warns, then
re-anchors). Both skip the delta rather than guessing.

A dirty tree asks before stashing. The dotfiles are reviewed with hunk, which
watches *unstaged* changes, so autostashing a review in progress out from under
the user is not an acceptable default.
