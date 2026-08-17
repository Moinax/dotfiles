---
description: Why T3 Code is built from our fork and deliberately untracked by dots apps, and why the single launcher entry with its exact --name is load-bearing.
paths:
  - home/dot_local/bin/executable_t3fork
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

The fetch uses an explicit refspec so `refs/remotes/origin/<branch>` really is
updated. When it fails, one `ls-remote --heads --exit-code` sorts the three reasons
by exit status (0 there, 2 reachable-but-absent, else unreachable) and **only status
2 may claim origin was observed** — saying so anywhere else makes the comparison run
against a stale tracking ref and has `offer_push` announce a published branch as
never pushed.

**Publishing is offered, never done on its own** (`offer_push`). The force-push is
safe *here specifically*: `sync_with_origin` fetched seconds earlier and refused to
continue if origin held anything this checkout lacked, so what it overwrites is
patch-equivalent to what we hold. The lease pins the observed sha
(`--force-with-lease=<branch>:<sha>`) rather than the bare form, which leases against
the local tracking ref — a ref any later fetch in the same process would move
underneath it.

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
