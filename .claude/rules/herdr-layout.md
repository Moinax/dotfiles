---
description: How a herdr pane's purpose is stored — the role sidecar that revive-panes reads, and why pane and tab labels are display-only and safe to rename.
paths:
  - home/dot_local/bin/executable_herdr-*
  - home/dot_local/bin/executable_dev-herdr
  - home/dot_local/bin/executable_dev-agent-argv
  - home/dot_local/bin/executable_wtclean
  - home/dot_local/bin/executable_dev-clean
---

# herdr pane identity: roles are state, labels are decoration

**Every name you can see is cosmetic.** Rename a pane (`prefix+shift+p`), clear
its name, rename a tab, rename a workspace — nothing breaks. What each pane is
*for* lives in `herdr-pane-role`, and that is the only thing `revive-panes`
reads when it rebuilds commands after a server restart.

## Why a sidecar, and not something in herdr

herdr persists exactly three fields per pane to `session.json`: `cwd`, `label`
and `agent_session`. Measured against what we need:

| slot | survives a restart | user-editable | usable |
|---|---|---|---|
| `label` | yes | **yes** — `keys.rename_pane`, "Clear pane name" | no |
| `agent_session` | yes | no | only for agents herdr itself recorded |
| `cwd` | yes | no | not a purpose |
| reported `title` / tokens | **no** | no | no |
| `pane split --env` | **no** | not readable back | no |

So there is no durable, non-user-editable per-pane slot to own, and the fact has
to live outside herdr. Pane ids are the key because they are stable across
restarts — verified by booting a session twice and diffing `pane list`:
byte-identical ids. They are unique per session only, hence one file per session.

The label was used as this slot for a long time, and it cost two silent
regressions (`ca57584`, `f213ae7`): each time something wrote a task name there,
`revive-panes` stopped recognising the pane and it came back a bare shell on
every restart, with no error anywhere. A user pressing `prefix+shift+p` had the
same effect. That failure mode is now structurally impossible.

## The roles

`herdr-pane-role set|get|list|prune`, storing `pane_id<TAB>role` under
`~/.local/state/dots/herdr-roles/<session>.tsv`:

- `agent:<provider>` — an agent pane. The provider is the durable half: herdr's
  own `.agent` is live detection only, and `agent_session` exists only for agents
  it managed to record.
- `shell` — known to have nothing to run (the `dev` and `logs` panes). Recording
  these is the point of storing a role for *every* pane rather than only the
  interesting ones: it lets `revive-panes` tell "meant to be bare" from "I don't
  recognise this pane", which used to be the same silent `continue`.
- a `herdr-pane-cmd` label (`review`, `nvim`, `files`, `git`, `tuicr`) — a
  utility pane, resolved to its command at revive time, so a change to that
  command reaches existing panes.

Roles are validated on write against those same two owners, so a typo fails at
the call site instead of becoming a pane that silently never returns.

## Who writes what

| writer | when |
|---|---|
| `herdr-agent-layout` | agent tab creation — all four panes in one call |
| `herdr-nav tool_tab` | on-demand `files`/`git`/`review` tabs |
| `dev-herdr util_tab` | per-workspace utility tabs |
| `herdr-clients migrate-layout` | alongside every pass that changes what a pane is |
| `herdr-clients revive-panes` | bootstraps missing roles, then prunes dead pane ids |

`revive-panes` runs at every boot (via `ensure_servers`), so panes that predate
the sidecar are inferred once from their label and tab shape and then recorded —
after which the label no longer matters. That bootstrap trusts the label, which
is why `migrate-layout` sets the role wherever it fixes a label: running them in
the other order would otherwise teach the bootstrap a stale label as a permanent
role.

## Workspaces: the checkout path is the identity

The same rule one level up — a workspace label is cosmetic, so **never look a
workspace up by its label**. `herdr-workspace for-paths` owns path → workspace
and needs two keys, because only one of them exists per workspace:

| key | set for |
|---|---|
| `worktree.checkout_path` | workspaces opened through `herdr worktree open` (dev-herdr's linked-checkout path) |
| a pane's `cwd` | everything else — `workspace create --cwd` (dev-herdr's fallback for a non-linked checkout) leaves no worktree metadata at all, and `workspace list` has no `cwd` field of its own |

Matching only the first is a silent leak: `wtclean` deleted the checkout and left
a live workspace pointing at a directory that no longer existed. `labs/vibewatch`
is a real workspace with `worktree: null`, so it is the case to test against.

Resolve **before** destroying anything — the session comes from `dev-projects
session`, which needs the directory to still be there.

`dev-herdr`'s reattach asks by path only — no label fallback, because a label
match binds `dev` to whichever workspace happens to carry the project's name. A
path miss means "not open yet", and the create path handles that safely.

Whether a checkout may be destroyed is also settled here, as a `busy`/`free`
column: an **allow-list** over herdr's statuses, because the binary ships more of
them (`running`, `unknown`, `error`, `ready`) than this setup has seen, and a
status we do not recognise has to read as "an agent may be in there". The
asymmetry is the point — guessing `free` wrongly destroys an agent's work,
guessing `busy` wrongly just leaves a worktree for the next run.

**Never hand these rows from jq to `read` as tab-separated fields.** `read`
cannot see an empty field between two tabs — tab is IFS *whitespace*, so a run of
them collapses into one delimiter and every later field shifts left. Since
`worktree.checkout_path` is empty for most workspaces, `wA<TAB><TAB>working`
parsed as path=`working`, status=`""`, and *every* workspace read back as idle,
i.e. free to destroy: a `working` agent's checkout was reported `free`, inverting
the polarity the paragraph above exists to protect. `herdr-workspace` and
`wtclean` therefore join jq's fields with US (`0x1f`), which is not IFS
whitespace and so delimits exactly one field however empty its neighbours are.

## What the labels are for now

Purely what you read. The agent pane's label is its provider (short, stable,
matches the sidebar's `agent` token) and its reported `title` is the task, which
the pane border renders in preference to the label — verified against herdr
0.7.5 with a probe: a reported title of `ZZPROBE` on a pane labeled `logs`
renders as `ZZPROBE`. `herdr-agent-title` keeps the title and the tab label in
step and re-reports on `SessionStart`, since a restart drops reported metadata.
None of that is load-bearing: if it drifts, the border shows a slightly stale
name and every command still comes back.
