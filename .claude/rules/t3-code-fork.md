---
description: Why T3 Code is built from our fork and deliberately untracked by dots apps, and why the single launcher entry with its exact --name is load-bearing.
paths:
  - home/dot_local/bin/executable_t3fork
  - tools/provision-droplet.sh
  - tests/test_t3fork_sync.sh
  - home/dot_local/bin/executable_t3-code-launch.sh
  - tools/manage-external-apps.py
---

# The fork is untracked by `dots apps`, on purpose

The AppImage at `~/.local/share/AppImages/t3-code.AppImage` carries our patches on
top of upstream, and `t3fork update` / `t3fork install` are what maintain it
(`t3fork restart` relaunches an already-installed one).

It used to be tracked as a `pingdotgg/t3code` pre-release, so `dots update`
offered that row and accepting it downloaded the upstream nightly *over* the fork
build, silently dropping every patch. The source record was removed — **never
re-add it with `dots apps install-github`**.

**The droplet is the second road onto the same rake.** `phase_fork` in
`tools/provision-droplet.sh` builds this fork there too, and its systemd drop-in
deliberately bypasses `service-launcher.mjs` — the self-update supervisor, which
would `npm install` upstream over our build exactly as `dots apps` did. Restoring
the launcher "so t3 can manage itself" is the same mistake in a second file; see
`docs/adr/0003`.

Upstream movement is reported instead by the fork check at the end of
`dots update` (`fork_drift`, see `sync-machine.md`), which needs no declaration to
pick up the next fork.

# One launcher entry, written by `t3fork install`

Install goes through `dots apps import-appimage "$built" --name "T3 Code"`, never
a bare copy, because the copy leaves no `.desktop` and no icon behind.

Removing that record only half-worked once: a second registration under the slug
`t3-code-alpha` kept pulling the upstream nightly, and every `.desktop` entry and
the `t3code://` handler pointed at *it* while the fork build sat unreferenced.
Nothing reported it — `t3fork restart` execs the target directly.

Two rules fall out:

- **The `--name` is load-bearing.** electron-builder stamps `productName`,
  `T3 Code (Alpha)`, which slugs straight back to `t3-code-alpha` and reinstalls
  the split.
- **There must only ever be one T3 Code in `dots apps list`.** A second row is the
  bug, not a fallback.

# `t3fork` internals, as `fork_drift` sees them

`t3fork` refuses on the same state from both ends (`refuse_if_rebasing`). `install`
is the one that matters: the `&&` in `t3fork update && t3fork install` only guards
the chained form, and a hand-run `install` mid-rebase builds the partially replayed
tree, stamps it `…-moinax.<sha>` — the branch name is the script's variable, not
something git was asked — and installs it over the working AppImage.

**`update` takes in origin before rebasing** (`sync_with_origin`) — `dots backup
create`'s rule applied to a fork: it may only move forward. Rebasing from a checkout
that is behind produces a branch missing another machine's commits, and the
force-push that follows deletes them while the push succeeds and the branch looks
healthy. Behind or level fast-forwards; anything else is judged by **`git cherry`,
not by divergence**, and that is the whole feature — a branch rebased here and not
yet pushed has already diverged by construction, so refusing on divergence would
block every update for anyone who does not push each time. `git cherry` asks the
question that matters, by patch-id: a locally rewritten commit counts as present, a
genuinely foreign one comes back `+`.

**Patch-id alone still cannot say WHICH side wins**, and that is a second question
the first one hides. Two situations give the identical shape — origin holds patches
we lack, we hold patches it lacks: another machine rebased and force-pushed, or
*this* machine rebased and declined the push, leaving on origin the pre-rebase form
of every commit the replay re-resolved. Answering "origin wins" to both reverted the
newer rebase and each conflict resolution in it, then replayed the older form onto
upstream — the reset only moves a ref, so the loss went to the reflog and the next
build shipped the superseded patch. It also read the upstream commits the rebase had
taken in as "our stale iterations" and offered to drop them.

**The rebase base is the discriminator**, because it is the thing a rebase changes:
`merge-base` against `upstream/main` is the upstream commit each side sits on, and
whichever sits on the newer one is the later rebase. That is why `update` fetches
`upstream main` *before* calling `sync_with_origin` rather than after — the
comparison is meaningless against a stale `upstream/main`. Equal bases fall through
to the old rule, where origin genuinely does carry work of its own.
`tests/test_t3fork_sync.sh` holds both directions.

The fetch uses an explicit refspec so `refs/remotes/origin/<branch>` really is
updated. When it fails, one `ls-remote --heads --exit-code` sorts the three reasons
by exit status (0 there, 2 reachable-but-absent, else unreachable) and **only status
2 may claim origin was observed** — saying so anywhere else makes the comparison run
against a stale tracking ref and has `offer_push` announce a published branch as
never pushed.

**Publishing is offered, never done on its own** (`offer_push`). The force-push is
safe *here specifically*: `sync_with_origin` fetched seconds earlier and either took
origin in — leaving what we overwrite patch-equivalent to what we hold — or
established that this checkout is the later rebase and **named on screen** the
commits origin carries that it supersedes. That second arm is a weaker guarantee
than the first and is stated as one: a subject in that list you do not recognise is
another machine's work, and the run says to stop. The lease pins the observed sha
(`--force-with-lease=<branch>:<sha>`) rather than the bare form, which leases against
the local tracking ref — a ref any later fetch in the same process would move
underneath it.

**The droplet rebuild is offered right after a successful push**, not printed as a
next step. `docs/adr/0003` makes the host a consumer of `origin/<branch>`, so the
push is the moment it becomes reachable-and-stale, and a command to remember at the
end of a maintenance run is a command remembered once — a declined push left the
host a day behind with the desktop looking healthy throughout. `dots update`'s fork
report carries the other half: it now counts commits absent from `origin` off the
tracking ref, no fetch, because this machine is the only thing that pushes there.

**Never auto-push.** `t3fork update` is the command the fork report *names*, so
auto-pushing would turn a line of a routine maintenance report into rewriting a
published branch nobody agreed to. Not pushing costs an origin that lags and the
next run takes in; pushing wrongly rewrites a remote.

**The keys are written by every `t3fork` invocation, not just `update`.** They lived
in the `update` branch first, which made them unreachable in practice — they exist
to tell you which command to run *before* you have run it, so the command they name
cannot be the only thing that writes them. The first `dots update` after they landed
printed a bare `git rebase` for exactly that reason. The write is non-fatal: losing
it costs a degraded report line, never the run the user asked for.

Both the `upstream` remote and the key live in the fork's `.git/config`, which
a restore used to drop on the floor — see the sidecar manifests under
`dots backup` (`backup-projects.md`), which is what now carries them back.
