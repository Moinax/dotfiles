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
| `herdr-clients revive-panes` | bootstraps missing roles, then prunes dead pane ids — and does the same sweep for `herdr-agent-title`'s entries, which are keyed the same way |

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
`dev-herdr` opens a tab under the run's own name rather than the provider,
because the sidebar's row 2 is the tab label and row 1 already dims the provider.
`herdr-nav agent-tab` does the same for a tab you name in the picker; an unnamed
one still gets the `<provider>[ N]` placeholder, since there is nothing better to
say yet, and a longer display name (`ws (claude 2)`) to tell two of them apart.
None of that is load-bearing: if it drifts, the border shows a slightly stale
name and every command still comes back.

**Every name a pane wears is written by a verb of `herdr-agent-title`**, one per
moment: `seed` at tab creation (herdr-agent-layout), `restore` at boot
(herdr-clients revive-panes), `sync` at turn end (the Claude Code hook). Reporting
the title and recording what the hook may replace are one act, so `seed` does
both in one call. `herdr-agent-layout` used to open-code the `report-metadata
--source dots:agent-title --title X --token task=X` triple itself, which put the
contract in a second file, and revive-panes would have made a third.

**The seed/pin/set entries are durable, and that is what makes boot safe.** They
live beside `herdr-pane-role`'s sidecar under `$XDG_STATE_HOME/dots/`, keyed by
the same never-reused pane ids, and are swept by the same `prune` off the same
live list. They used to sit in `$XDG_RUNTIME_DIR`, and every defect in the naming
path traces back to that one choice:

- Because the entries died with the machine, `revive-panes` had to **reconstruct**
  the state machine from tab labels at boot and write its guess back — keying
  machine state off decoration, the thing this whole file exists to forbid. A
  prompt-derived launch label (`dev -- "fix the flaky updater tests"`) came back
  as a user-typed `pin` and then froze, beating the title Claude had since
  settled on.
- Because the runtime dir survives a **server** restart while that guess ran
  anyway, a plain `herdr-clients stop-all && open-all` overwrote a live `set`
  entry with a `pin` and an empty SEEN, swallowing any title that moved while the
  server was down.
- Because the directory was created by whichever writer got there first, a
  `: >"$stamp"` redirect into it found no directory on the first sync of a boot
  and `set -e` ended the script mid-name: pane renamed, tab not, no entry written,
  so every later turn repeated the half-rename and died at the same line — the
  whole machine dead for the boot, silently, because the hook is `async`.

So: `restore` **reads and never writes**. It reports the recorded name back onto
panes whose title the restart wiped, skipping any pane that already has one (a
resumed agent re-reports for itself at `SessionStart`, and stamping an older name
over that recreates the tab/pane disagreement the verb exists to prevent). A pane
with no entry gets a fallback name from revive-panes — reported, never recorded,
so the next turn end goes through `sync`'s ordinary no-entry adoption instead of
a guess made from outside. The directory itself is made once per run by
`cache_ready`, so a new write inherits the guarantee rather than having to
remember a call — the same reason every herdr call there goes through `h`.

**Nothing in the naming path may be fatal — but silence is not the same as
non-fatal.** A name must never end a turn, so every external call is time-boxed
and every write swallowed. A *state directory that cannot be made* is a real
fault, though, and degrading silently to "no memory" means re-adopting the tab
label at every turn end forever, overwriting a hand-typed name each time with
nothing said anywhere. `cache_ready` therefore reports that one case and carries
on, and `herdr-agent-layout` no longer swallows a failing `seed`: it is the only
thing filling the title slot now, and a pane stuck on its bare provider is
otherwise indistinguishable from one that simply has no task yet.
