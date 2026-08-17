---
description: How a herdr pane's purpose is stored — the role sidecar that revive-panes reads, why pane and tab labels are display-only, and the two reconciliations a layout or config change needs after an apply.
paths:
  - home/dot_local/bin/executable_herdr-*
  - home/dot_local/bin/executable_dev-herdr
  - home/dot_local/bin/executable_dev-agent-argv
  - home/dot_local/bin/executable_wtclean
  - home/dot_local/bin/executable_dev-clean
  - home/dot_config/herdr/config.toml
---

# Two reconciliations, and neither is the other's job

**A layout change needs `herdr-clients migrate-layout` after the apply.** That
means pane/tab structure or labels in `herdr-agent-layout`, `dev-herdr` or
`herdr-pane-cmd`. Existing workspaces persist their old layout (dev-herdr
reattaches as-is, never migrates), so without it the previous iteration silently
comes back at the next server restart.

**A `config.toml` change needs `herdr-clients reload-config`** — keybindings,
popups, UI. Servers read `config.toml` only at boot, so without it every running
session but the current one keeps the old config. This is *not* a job for
`migrate-layout`, which reconciles persisted `session.json` structure and never
the config.

Both run inside `apply_dotfiles` and `dots update` — but not in a hand
`chezmoi apply`, so they fall to you.

# Agent tabs are named after the task, not the provider

A tab label is "fix-flaky-updater-tests", set from the name typed in the
ctrl+alt+a picker or written later by `herdr-agent-title` (a Claude Code
Stop/SessionStart hook that follows Claude's own session title). So never identify
an agent tab by parsing its label — go through its panes (`pane.agent`, or the
recorded role), the way `herdr-nav agent-tab` picks its insertion point.

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

**Anything that creates a pane must record its role in the same breath — that is
the one rule.** The table below lists today's writers, not the eligible ones: a
new pane-creating script inherits the obligation without appearing here.

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
(herdr-clients revive-panes), `rename` on ctrl+shift+t (herdr-nav rename-tab),
`sync` at turn end (the Claude Code hook). Reporting the title and recording what
the hook may replace are one act, so `seed` does both in one call.
`herdr-agent-layout` used to open-code the `report-metadata --source
dots:agent-title --title X --token task=X` triple itself, which put the contract
in a second file, and revive-panes would have made a third.

## `-n` carries only what a human wrote

`claude -n NAME` is not a display option: Claude Code **persists NAME into the
transcript as a `custom-title`**, which is the exact record `sync` reads back as
the agent's own account of its work. Handing it a generated label therefore
closed a loop — launch label → custom-title → read back as evidence → applied to
the tab → re-read as `-n` at the next relaunch. Observed on
`jacket.CI-5480`: Claude had settled on `employee-api-refactor-cleanup`, a
relaunch fed the tab label back in, and the two sessions after it are titled
`jacket.CI 5480`. Worse, Claude never titled that work at all — it does not
overwrite a custom title that already exists, so `/rename` was the only way out.

So `-n` is passed only for a name a human wrote: `herdr-agent-layout` gates it on
`-k pin`, and `revive-panes` asks `herdr-agent-title pins` rather than reusing
the tab label it restores the border from. A `set` name is only this machine's
reading of a conversation that has ended; writing it into a *new* session's title
would make the fresh work answer to the old work's name forever. codex and
opencode take no name flag and never had the problem.

## A rename is one act, not four surfaces catching up

herdr's native `rename_tab` writes the tab label and nothing else. Everything
downstream — the pane border, the sidebar `$task` token, vibewatch — moved only
when `sync`'s drift check next ran, which needs the agent to end a turn: on an
idle pane, never. And the check was gated on a `set`/`pin` entry, so with a
`seed` (every wtstart run, for its first turn) or no entry at all it never ran,
and the agent's title was re-applied straight over the name the user had typed.

Both are fixed at their own level: the drift check is ungated and lifted above
every other arm, so "a hand rename means pin" is written once (a pane whose agent
had not titled itself used to `exit 0` before reaching it, and the pin gate
carried a second copy that banked SEEN differently). ctrl+shift+t goes through
`herdr-nav rename-tab` → `herdr-agent-title rename`, which writes all four in one
call and pins. `prefix+shift+t` keeps herdr's native rename as an escape hatch,
still covered by the slower path.

**A writer with no transcript in hand writes SEEN empty.** `rename` runs from a
keypress and cannot see the agent's title, and empty is already what this machine
means by "unknown, adopt the next sighting" — `moved` needs a non-empty SEEN, so
the pin holds, and the pin arm's `banked="${seen:-$title}"` fills it at the next
turn end. Carrying the previous SEEN across looks more careful and is the
opposite: Claude's `/rename` fires no hook, so a title that moved since the last
sync is invisible from out here, and carrying that stale sighting made the next
turn end compute `moved=1`, skip the pin gate, and apply the agent's title
straight over the name just typed. Everything before a hand rename is settled by
definition.

The agent session id vibewatch keys its override by is **banked in the entry**,
out of the hook payload, on every sync. herdr's own `pane.agent_session` is a
fallback and not the source: it exists only for agents herdr's integration
registered, which was 6 of 19 agent panes when this was measured, so sourcing it
from there left `rename`'s vibewatch leg dead on two thirds of them.

**The record is US-separated (`0x1f`), not tab** — the same lesson as
`herdr-workspace`, re-learned here. Tab is IFS *whitespace*, so `read` collapses a
run of them and an empty field between two tabs disappears, shifting every later
field left. It was harmless while SEEN was last and only ever trailing-empty; the
moment SID went after it, a pane renamed by hand read its own session id back as
SEEN, `moved` went true, and the pin fell through the gate that exists to hold
it. `cache_read` and `write_cache` are the only two things that know the layout,
precisely so this is one decision and not four. The `pins` stdout protocol and
the hook payload's own `jq` join follow the same rule, for the same reason.

**The recorded NAME is the label the *tab* wears, never the one the border
shows.** It is what the drift check compares the live label against, so recording
anything the tab never wore makes the first sync read as a hand rename.
`herdr-nav agent-tab` diverges the two on purpose for an unnamed tab — "claude 2"
on the tab, "ws (claude 2)" on the border, to tell two of them apart — and
recording the border name pinned every such tab to its own placeholder on its
first turn, froze it there, and made it `-n`-eligible at the next boot, reopening
the custom-title loop with the placeholder as the poison. Hence `seed -l`.

**Our own `-n` coming back is not the agent's title moving.** A revived pin
relaunches as `claude -n "<pin name>"`, which Claude persists as the new session's
custom-title; comparing that against the SEEN banked from the *previous*
conversation makes `moved` true and demotes the pin to `set` on the first turn
after every boot. `moved` therefore also requires `title != applied`.

**A name is only recorded once it has actually been applied.** `rename`'s herdr
calls are all swallowed — a name must never be fatal — so a timed-out `pane get`
used to leave the entry claiming a label the tab never took, which the next turn
end read as a hand rename in the opposite direction and reverted. It now fails
loudly and writes nothing, leaving the pane exactly as it was.

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
