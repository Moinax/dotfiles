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

Phases: pull → new groups → package delta → `chezmoi apply` → tool refresh
(`tools/manage-updates.sh`, still reachable alone as `dots update tools`) →
`run_post_apply` → re-stamp the profile → report fork drift.

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

Both the `upstream` remote and the key live in the fork's `.git/config`, which
a restore used to drop on the floor — see the sidecar manifests under
`dots backup` below, which is what now carries them back.

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
  needs — three of them for the rofi set — and those are listed separately,
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
before emitting, one row per name. Left to the caller it was a three-line rule a
second caller would omit, and omitting it means handing `pacman -Rs` the wrong
package. `list_installed_packages` is now `cut -f1` of that map rather than a second
parser of the same three fields — the old fallback half never emitted a
package's own name (a separate `pacman -Qq` was bolted in front of it), which is
the drift a rarely-taken branch invites. Both branches verified line-for-line
identical, 2696 names.

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
— `declared_packages_at`, `group_package_states` and `build_manage_json` all used to. It was 21 yq per tree
plus the callers' extra one, and the delta walks two trees, so a scan spent 50
invocations. This machine has **python-yq**, ~180ms of interpreter start each, which
made it ~9s of a ~10s scan; it is now 3.2s. `base_desired_packages` is one call for
the same reason. Both keep their yq-less fallback by delegating to the old parsers.
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

## `install/lib/post-apply.sh`

What has to happen after any `chezmoi apply` for the running desktop to show it:
Hyprland reload (its mid-apply autoreload fails on `conf/general.lua` requiring a
`conf/theme.lua` not yet written), herdr `reload-config`/`migrate-layout`, the
themed surface copies plus the swaync/swayosd/kitty reloads they need, the
declared user services that are enabled but not running, waybar
restart. Shared because these used to live in the installer only — the one script
you stop running once the machine is set up.

### The themed surfaces read a copy, so refreshing it *is* the reconciliation

Five surfaces — kitty, eza, swaync, swayosd, wlogout — read one fixed path
(`style.css`, `theme.yml`, `current-theme.conf`) and express the mode by copying
`style-dark.css` or `style-light.css` over it. None of those copies is managed:
the only thing that ever writes them is a dark/light toggle.

So an apply that rewrites the managed sources reaches *none* of them. Each copy
keeps whatever the last Mod+N put there and the change waits, silently, for the
next one. A font swap surfaced it as tofu across the whole notification panel
while `swaync-client -rs` cheerfully reported `success: true` — the reload
re-read a stylesheet that still named the by-then-uninstalled font. The other
five had the identical staleness and merely nothing visible to show for it,
which is the point: only swaync had a symptom, so only swaync would ever have
been fixed.

**`home/dot_local/lib/theme-copies.sh` owns the list**, deployed to
`~/.local/lib/` and sourced by both callers — `apply-dark-mode.sh` to switch
modes, `reconcile_theme_copies_after_apply` to reconcile after an apply. Two
copies of the list would go stale the first time a surface was added to one and
not the other, which is this bug again, one surface at a time.

**Reload policy deliberately stays with each caller**, because they need
different things. A toggle only changes colours, so swaync takes the cheap
`swaync-client -rs` — restarting on every Mod+N would drop every queued
notification. An apply can change *structure* (a font family), and a running
daemon keeps its old font map, so there the process must be replaced. Same
reason the post-apply restarts are gated on the file list while waybar's is
unconditional: a restart costs queued notifications, a copy costs nothing, so
the copies run unconditionally and only the reloads are gated.

kitty's SIGUSR1 is in that set for a second reason beyond the theme copy: kitty
reads `kitty.conf` once at startup, so a font or keybind change needs the same
signal.

Do **not** reach for `apply-dark-mode.sh` from post-apply. It would fix every
surface in one call, but it also runs `plasma-apply-colorscheme` and repaints
the whole desktop — and it ends by calling `chezmoi apply` itself, so invoking
it from a post-apply hook re-enters the thing that just ran.

Known limit of hanging this off post-apply: it only fires through
`apply_dotfiles`/`run_post_apply`, so a bare hand-run `chezmoi apply` still leaves
all six copies stale. That is the general rule about hand applies, not a special
case — but it is the one path this reconciliation does not cover.

### A user service installed mid-session is enabled but dead

A user unit is almost always `WantedBy=graphical-session.target`, and systemd
pulls in `Wants` only when the target **activates**. So a package installed while
you are logged in gets its unit enabled and never started: it reads `enabled`,
the journal is empty, and it stays that way until the next login.

vicinae shipped exactly like that. `dots update` installed `vicinae-bin` at
10:42, one minute after graphical-session.target had been reached, its own
systemd preset enabled it, and the server never ran — with every Hyprland keybind
firing a `vicinae://` deeplink at nothing. It looked like a broken config; the
config was fine and `hyprctl binds` had all 131 binds loaded.

Nothing in the repo closed that before: `services:` is the **system** half and
goes through sudo, and `enable_selected_services` lives in the installer — the
script you stop running once the machine is set up. That left `dots update`, the
one path that installs packages onto a live desktop, as the one path that could
leave a daemon dead.

`user_services:` in a group yaml is the per-user list, read by
`parse_user_services` — one of four one-line wrappers over `parse_yaml_list`,
along with `parse_dotfiles`, `parse_services` and `parse_desktop_only`. Adding
this key is what forced that generalisation: the yq-less fallback loop existed in
three hand-copied versions, and **only the `desktop_only` copy ever learned to
strip an inline comment**, so `- vicinae.service  # the launcher` parsed cleanly
as one list and yielded a unit name with the comment glued on as another. The yq
path never had the bug, so it lived only on the fallback nobody tests. Add a list
to the schema by adding a wrapper, never another copy of the loop.

**Which systemd instance a unit belongs to is data, not something to infer.**
Nothing in `vicinae.service` says it is a user unit, so the two lists stay
separate rather than being sniffed from the name — guessing wrong means either a
sudo prompt for a unit root cannot see, or a system unit silently enabled in the
user instance. `_systemctl_query` / `_systemctl_admin` in services.sh are the
only two places that difference is spelled out, and they encode the reason for
the split: queries (`is-enabled`, `is-active`) never need root, and the user
instance must never see sudo at all, because `sudo systemctl --user` does not
fail — it acts on *root's* session, which is the worst failure available here.

`for_each_service <verb> <names…>` is where the dedupe lives, and it takes the
verb because the four system/user × enable/disable combinations differ in nothing
else. There was briefly a `parse_declared_services` reading both lists in one yq
call for the install path — deleted: that loop already spends several yq calls
per group plus four per custom entry, so folding two of them saved ~170ms of a
multi-minute install and cost a second tagged-row format to keep beside
`group_declared_lists`. A saving that only the once-per-machine path can collect
is not worth a parallel protocol.

**`reconcile_declared_services` in sync-machine.sh is the one that matters on an
existing machine**, and it covers base *and* every enabled group, both instances.
It was scoped to base first, which was a notch too narrow and made the
`user_services:` declaration above inert everywhere but a fresh install:
`enable_selected_services` is installer-only, `sync_group_after_change` fires
only for groups a *package* change touched (a group that merely gained a service
is never visited), and `start_user_services_after_apply` never enables. So
vicinae kept working only because vicinae-bin ships its own systemd preset —
precisely the coincidence that declaring it was meant to replace.

**`start_user_services_after_apply` starts only what is already enabled, and
never enables anything.** That is what makes it safe to run on every update:
`is-enabled` cannot distinguish a unit nobody has enabled yet from one the user
deliberately disabled, so enabling here would silently undo a
`systemctl --user disable` at the next `dots update` — the same nagging the
anchor design exists to prevent. Enabling belongs to the two places with a reason
to believe it is wanted: `enable_selected_services`, and a group being switched
on in `dots packages`.

It is also the one reconciliation deliberately **not** gated on the changed-file
list, because its trigger is a *package* install, which leaves no trace in the
files an apply touched. Being ungated on a path that runs every time is what
makes the order of its guards the entire cost of the feature, so they escalate:
`systemctl` exists (free) → a graphical session is active (~9ms) → `grep -l
'^user_services:'` across the group files (~9ms) → `group_enabled` → yq. The
first version asked none of that and simply parsed all eight group files, which
is **~1.2s of every apply** to read a line that exists in one of them — the whole
budget the catalogue-scan optimisation above bought back, re-spent on a more
frequent path. With the guards it is ~0.2s on a desktop and ~5ms headless.

The graphical-session check is deliberately asked twice: once here as a
machine-wide precondition (if it fails, nothing can be started, so the scan is
pure waste) and once per unit inside `start_user_service_if_needed`, which
`enable_user_service` calls directly and which therefore cannot rely on this
caller having asked.

It resolves the groups directory from `BASH_SOURCE`, **not** from `$DOTFILES_DIR`.
That variable is a caller precondition and `dots` does not meet it — it sets only
`SCRIPT_DIR` — so `dots reconfig`, which applies through `apply_dotfiles`, globbed
`/packages/groups/*.yaml`, matched nothing and reconciled nothing, silently.

Note the explicit `return 0` at the end. The `for` loop's exit status is whatever
its last iteration left, and a disabled group exits via `continue` after a failed
`group_enabled` — so without it the function returns 1 on any machine whose last
group file alphabetically is switched off, and installer.sh's `set -e` reads that
as a failure and aborts between there and the waybar restart, silently.

`post-apply.sh` sources `services.sh` itself rather than trusting its callers:
installer.sh sources it only inside `enable_selected_services`, and
sync-machine.sh not at all, so the helper would have been undefined on precisely
the `dots update` path it was written for.

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
`fork_drift` above then went quiet rather than complaining, "not a fork" being
indistinguishable from "no upstream remote". It is a sidecar rather than a fourth column
in `repos.tsv` because restore reads that file with `read -r rel remote branch`, so a
fourth column would land inside `branch`; a file an older restore does not know about is
simply ignored. Read through `read_config_lines`, which makes a missing manifest a
non-event.

Re-adding is additive by construction — `git remote add` on an existing name fails and
changes nothing — which is why extras are applied to repos that are *already on disk*
too. That is the repair path for a machine restored before this manifest existed.

Per-repo `dotfiles.*` config keys are deliberately **not** carried. `t3fork` re-asserts
its own `dotfiles.forkUpdate` on every run instead, which self-heals after any loss
rather than only after a restore — and losing it costs one degraded suggestion line
(`fork_drift` falls back to a plain `git rebase`), not a silent failure.

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
run also drops the Node candidate (a setup re-run offers back the entries setup skipped,
and the toolchain underneath them is not one of those) and the external-apps check
(`dots apps`' inventory, never a yaml entry, and it spends the same GitHub quota the
filtered lookups need).

### Moving Node has to carry the global npm packages

A global npm package lives inside the Node version's own tree, so `fnm default` landing on
a new LTS leaves an empty `node_modules` and every one of them gone — hunk, ccstatusline
and pnpm all vanished this way on the v24.18 → v24.19 bump, taking the review pane and the
statusline with them. Nothing downstream recovered that: `packages sync` can't see it (a
`check: command -v hunk` that passed on the old version passes on nothing afterwards), and
the updater reported the package as a non-actionable row — so the old advice to "run
`dots update` again to reinstall any that moved" was simply false.

**Prevention** is `install_node_lts`'s job in common.sh: `list_global_npm_packages` reads
the names off the version being left, and `reinstall_global_npm_packages` puts back
whatever the version landed on is missing. Both go through `FNM_GLOBALS_DIR`, one constant,
because the path is stable while its target moves. A package npm can't fetch is warned
about and left, never fatal — Node itself did move, and rolling that back over one package
would be worse.

It sits in `install_node_lts` rather than in the updater's `apply_row` because it belongs
welded to the `fnm default` that causes the stranding: a future caller that moves Node
inherits the repair without having to know it needs one. Note that `dots update` is the
only caller that can trigger it today — `ensure_node_toolchain` reaches `install_node_lts`
only inside `if ! fnm ls | grep -q 'lts\|v[0-9]'`, so the installer provisions Node but
never bumps it, and on that path the read finds nothing and costs one stat. Do not "fix"
the placement on the grounds that the installer never uses it; coupling is the reason.

**Recovery**, for a machine already stranded, is the `missing` report status. It exists
apart from `absent` because the two absences are not equally fixable: a global npm
package's entire install command is `npm install -g`, which `apply_row`'s npm case already
runs — and npm treats install-over and install-fresh alike, so one apply path serves an
outdated row and a missing one — whereas an absent *binary* entry needs its yaml
`install:` and stays pointed at `dots packages sync`. Folding them into one status would
have forced `actionable_rows` to either skip the recoverable half or offer the other half
an action it cannot carry out. A `missing` row shows `—` for both versions because neither
`npm outdated -g` nor `npm ls -g` lists a package that isn't installed, and its selection
label reads "install" rather than "refresh (—)".

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
