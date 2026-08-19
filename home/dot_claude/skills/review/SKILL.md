---
name: review
description: >-
  Review the current diff for correctness bugs AND reuse/simplification/
  efficiency/altitude/conventions cleanups in ONE pass — six read-only agents
  fan out in parallel, then their reports are adjudicated and fixed in the
  working tree. Replaces running /code-review and /simplify back to back.
  Trigger on "/review", "relis le diff", "review avant de ship".
argument-hint: "[--dry] [<target>]"
allowed-tools: Agent, Bash, Read, Edit, Write, Glob, Grep
---

# Review — six angles in parallel, one fix pass

One fan-out, one adjudication, one fix pass. `/code-review` reports without
fixing; `/simplify` fixes without hunting bugs; this does both, and never falls
back to a single inline pass without saying so.

`$ARGUMENTS` is an optional target (a branch, a path, a PR number, or a commit
SHA). Empty is the normal case: the current diff. `--dry` stops after Phase 2 and
reports instead of fixing.

## Phase 0 — The scope and the repo

```bash
git diff @{upstream}...HEAD    # or `git diff main...HEAD` with no upstream
git diff HEAD                  # working tree — this often runs before the commit
```

Both, always: the second is the point when the review runs mid-work. A target
in `$ARGUMENTS` replaces them — and a target that is a commit SHA means
`git show <sha>`: review that commit as if it were the change under review, with
the working tree already checked out at it. An empty scope is a stop — say so and do not
spawn anything.

Read the diff yourself before fanning out. You are about to adjudicate six
reports; you cannot do that on a scope you have not seen.

Then establish, in this context, the three repo facts the agents cannot see:

- **the one-liner** — stack, framework, and the layout of the changed area, in
  one or two sentences (from the root `CLAUDE.md`/`AGENTS.md`/`README`, plus
  what the diff itself shows);
- **the shared code** — the directories a re-implementation would duplicate:
  the utility/lib/hooks/components modules, the test fixtures, the chassis or
  core package if the repo has one;
- **the gates** — the lint / typecheck / test commands this repo actually
  uses, and how to scope them to the changed files. Look at the task runner
  (`justfile`, `Makefile`, `package.json` scripts, `pyproject.toml`) and at CI.

Pass the first two into every agent prompt. The gates are for Phase 3.

## Phase 1 — Six agents, one message

Spawn **six `reviewer` agents in a single message** so they run concurrently.
They are read-only by construction, which is what makes the parallelism safe.

Each prompt is self-contained — a subagent shares none of this context. Give
every one of them:

- the review scope: the exact `git diff` commands from Phase 0, or the target;
- the repo one-liner and the shared-code directories from Phase 0;
- **its angle, verbatim from the list below, and only its angle**;
- the output contract: the JSON array from the `reviewer` agent definition.

Do not run any angle yourself in parallel with an agent that owns it — a
duplicated angle is wasted tokens and a doubled finding.

### Angle 1 — Line-by-line diff scan

> Read every hunk line by line, then Read the enclosing function of each hunk —
> bugs in unchanged lines of a touched function are in scope, the change
> re-exposes them. For every line: what input, state, timing or platform makes
> this line wrong? Inverted or wrong conditions, off-by-one, null/undefined
> deref, missing `await`, falsy-zero checks, wrong-variable copy-paste, error
> swallowed in a catch that should propagate, unescaped regex metachars. Then
> the pitfalls specific to this stack — name them from what the diff touches
> (an ORM query evaluated inside a loop, a side effect firing inside a
> transaction, a React hook whose dep array lies, a `useEffect` that writes the
> state it reads, an unawaited promise in a handler).

### Angle 2 — Removed behaviour and blast radius

> Two halves, both about what the change breaks elsewhere.
> For every line the diff DELETES or replaces: name the invariant or behaviour
> it enforced, then find where the new code re-establishes it. You cannot find
> it — that is a candidate: a removed guard, a dropped error path, a narrowed
> validation, a deleted test that covered a real case.
> For every function the diff changes: Grep for its callers and check each call
> site against the new precondition, return shape, exception or ordering
> dependency. Check the callees too — does another hunk of this same diff make
> one of these calls unsafe?

### Angle 3 — Reuse

> Flag new code that re-implements something this codebase already has. Grep the
> shared and utility modules and the files adjacent to the change — the
> directories named in the prompt, plus `lib/`, `utils/`, `hooks/`,
> `components/`, and the test fixtures. Name the existing helper to call
> instead; a finding without a named replacement is not a finding.

### Angle 4 — Simplification and altitude

> Two questions about shape.
> Unnecessary complexity the diff ADDS: redundant or derivable state,
> copy-paste with slight variation, deep nesting, dead code left behind. Name
> the simpler form that does the same job.
> And the depth: is each change made where it belongs, or is it a bandaid? A
> special case layered onto shared infrastructure is the sign the fix is not
> deep enough — prefer generalizing the underlying mechanism: the shared module
> rather than the one consumer, one guard in the common function rather than
> one per caller.

### Angle 5 — Efficiency

> Wasted work the diff introduces: redundant computation, repeated I/O, N+1
> queries (a missing eager-load/join), independent operations run sequentially
> that could run together, blocking work added to startup or to a hot path.
> Flag long-lived objects built from closures or captured environments — they
> keep the whole enclosing scope alive for the object's lifetime. Name the
> cheaper alternative.

### Angle 6 — Conventions

> Find the CLAUDE.md / AGENTS.md files governing the changed code:
> `~/.claude/CLAUDE.md`, the repo root one, and any in a directory that is an
> ancestor of a changed file. Read each, then flag clear violations — quote the
> exact rule and the exact line that breaks it. No style preferences, no
> "spirit of the doc". The kinds a diff breaks most often: comments that
> narrate what the code plainly does, a generated artefact not regenerated
> after the source changed (API schema, types, migrations, lockfile), a
> translation key added to one locale but not the others, a file placed outside
> the layout the doc mandates.
> Also flag the missing test: non-trivial logic added with no test in the same
> change. Name the file it belongs in.

## Phase 2 — Adjudicate, once all six have reported

Wait for all six. Then, in this context, on the pooled list:

1. **Dedup** — same defect, same location, same reason: keep the one with the
   most concrete failure scenario, and note that two angles found it (that is
   signal, not noise).
2. **Judge each survivor yourself** against the diff and the file. Three states:
   - **CONFIRMED** — you can name the inputs or state that trigger it.
   - **PLAUSIBLE** — the mechanism is real, the trigger is uncertain. Keep it.
     A race, a rare-but-reachable path, a falsy zero, a boundary the code does
     not exclude: all plausible, none speculative.
   - **REFUTED** — provable from the code: quote the line that says otherwise,
     or the guard that already handles it, or the type that makes it impossible.
     Uncertainty is not a refutation.
3. **Rank** — correctness above cleanup, always.

## Phase 3 — Fix

**`--dry` stops here.** Report the adjudicated survivors as a JSON array in a
```json fence and nothing else — `file`, `line`, `angle`, `summary`,
`failure_scenario`, `verdict` — then stop. Do not edit, do not run gates.

Fix each survivor directly in the working tree. Leave the changes **unstaged**.

Skip a finding when the fix would change intended behaviour, when it would
require changes well outside the reviewed diff, or when you judge it a false
positive. Note the skip in one line; do not argue with it at length.

Then re-run the gates identified in Phase 0, scoped to what you touched. A fix
that reddens a gate is a fix to revisit, not to leave in.

## Phase 4 — Report

Rendered markdown in the user's language — never a monospace fence, which wraps
unreadably in a terminal: one bullet per finding under a `## Fixed — N` /
`## Skipped — N` heading (themed sub-groups past ~5 bullets), each bullet the
**`file:line`** in bold, the defect in one sentence, then the angle(s) that
caught it in italics.

Then: which gates you re-ran and their result **as a small table**, and one
line saying six agents ran in parallel and all six reported. **If the `Agent` tool was unavailable and
you worked the six angles inline instead, say that in the first line of the
report** — a single-pass review and a six-agent fan-out are not the same
evidence, and the reader must not have to guess which one ran.
