---
description: How a herdr pane's purpose is stored — the role sidecar that revive-panes reads, and why pane and tab labels are display-only and safe to rename.
paths:
  - home/dot_local/bin/executable_herdr-*
  - home/dot_local/bin/executable_dev-herdr
  - home/dot_local/bin/executable_dev-agent-argv
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

## What the labels are for now

Purely what you read. The agent pane's label is its provider (short, stable,
matches the sidebar's `agent` token) and its reported `title` is the task, which
the pane border renders in preference to the label — verified against herdr
0.7.5 with a probe: a reported title of `ZZPROBE` on a pane labeled `logs`
renders as `ZZPROBE`. `herdr-agent-title` keeps the title and the tab label in
step and re-reports on `SessionStart`, since a restart drops reported metadata.
None of that is load-bearing: if it drifts, the border shows a slightly stale
name and every command still comes back.
