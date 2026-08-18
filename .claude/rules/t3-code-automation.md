---
description: What t3-thread is pinned to inside T3 Code — the sqlite projection columns, the dispatch payload, the three userdata files and the fork-built CLI — and which of those upstream can move without warning.
paths:
  - home/dot_local/bin/executable_t3-thread
  - home/dot_local/bin/executable_t3-code-launch.sh
  - home/dot_local/share/vicinae/extensions-src/moinax/exact_src/t3.tsx
  - home/dot_local/share/vicinae/extensions-src/moinax/exact_src/exact_lib/t3*.ts*
  - home/dot_local/share/vicinae/extensions-src/moinax/exact_src/exact_lib/thread-list.tsx
---

# t3-thread rides on T3 Code's private state, not on a public API

T3 Code ships a `t3` CLI that manages **projects only** — `add`, `remove`,
`rename`, and not even a `list`. There are no thread verbs at all, so everything
the picker does about threads is done against internals upstream never promised
to keep. That is the whole risk of this feature, and it is concentrated in
`t3-thread`: the vicinae extension only shapes what that script prints.

## The three doors, and why each one

- **read → `~/.t3/userdata/state.sqlite`, opened read-only.** No auth, no server
  round trip, and it is the same projection the app's sidebar renders — so a
  list here cannot disagree with what is on screen. Columns relied on:
  `projection_projects(project_id, title, workspace_root, default_model_selection_json, deleted_at)`,
  `projection_threads(thread_id, title, project_id, model_selection_json, updated_at, deleted_at, archived_at)`,
  `projection_thread_sessions(thread_id, status)` and
  `projection_pending_approvals(thread_id, status)`.
- **write → `POST /api/orchestration/dispatch`**, which takes a whole
  `ClientOrchestrationCommand`. The only way to create a thread. Bearer-auth'd;
  the token is minted in-process by the CLI (it needs the sqlite handle *and*
  the signing key under `userdata/secrets/`), which is why no pure-shell path to
  a token exists.
- **focus → the deep-link socket** `$XDG_RUNTIME_DIR/t3code-deeplink.sock`,
  ~10ms against ~1.4s for `xdg-open`. Only one route exists:
  `t3code://threads/<environmentId>/<threadId>`, and the environment id comes
  from `~/.t3/userdata/environment-id`.

`~/.t3/userdata/server-runtime.json` is discovery only — it carries `origin` and
holds no token.

## What breaks silently when upstream moves

A renamed projection column makes a *verb* fail, loudly. Two things fail
quietly instead, and are worth checking after any rebase that touches them:

- **The `thread.create` payload.** `modelSelection` is required and is never
  invented here — it is copied, in one COALESCE: the project's default, else
  the newest thread of that project, else the newest thread anywhere. A model
  that no longer parses would make T3 fall back to its own, and a thread would
  quietly open on the wrong agent. `interactionMode` is deliberately omitted so
  the app's default is the only one.
- **The socket, which is our own patch.** It is fork-only
  (`apps/desktop/src/app/DesktopDeepLinkRouter.ts`); a rebase that drops it
  leaves `focus` with nothing to write to. The fallback is starting the app and
  writing again, not `xdg-open`.

## The CLI is the fork's build, not a published `t3`

`run_cli` runs `$T3CODE_REPO/apps/server/dist/bin.mjs` — version-locked to the
AppImage actually running, which matters because the server validates the token
it mints with its own signing key. `npx t3` would be a different build. Node is
resolved through fnm's *default alias*, never bare `node`: this runs from the
vicinae extension host and from a keybind, neither of which has sourced fnm.

## Focus has to be handed off, never awaited

Hyprland refuses a focus request from an unfocused client, so after the deep
link the compositor must be told separately — that is `t3-code-launch.sh`. It
has to run **detached**: a vicinae action still owns the keyboard while it runs,
and the compositor hands focus back to whatever vicinae took it from as the
launcher closes. Raised in the foreground, the confirm loop is polling for a
state that cannot occur until the caller returns, so it always burns its full
budget and then works by accident.
