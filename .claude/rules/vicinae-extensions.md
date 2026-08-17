---
description: Why the vicinae launcher loads build output rather than the chezmoi tree, what re-triggers the build, the three places a deleted command lives, and how a provider id breaks every deeplink silently.
paths:
  - home/dot_local/share/vicinae/extensions-src/**
  - home/run_onchange_build-vicinae-extensions.sh.tmpl
---

# The launcher loads build output, not the source tree

vicinae loads `~/.local/share/vicinae/extensions/<name>/`, which is *build
output*; the chezmoi-managed tree under `extensions-src/` is only source.

`home/run_onchange_build-vicinae-extensions.sh.tmpl` runs `npm install &&
npm run build` after an apply, and it re-triggers because it interpolates a
sha256 of every source file — so editing a `.tsx` is enough, but **adding a
source file that nothing else imports is not**.

## Deleting a command

Drop the `.tsx` (the source dirs are `exact_`, so chezmoi removes it) **and** drop
it from `commands` in `package.json` — the manifest is what vicinae registers
from, so an orphan bundle is inert but misleading. The build script prunes the
stale `.js`.

## Deeplinks are the keybind API, and the provider id is not the name

A local extension's provider id is `@<author>/<name>` from the manifest, not
`<name>` — `vicinae://launch/@moinax/moinax/dev`.

Never guess it: `vicinae cmd ls` prints every registered id. Renaming a command
or the author in `package.json` breaks every `vicinae://` consumer **silently**,
so grep `home/` for `vicinae://` before renaming (today: `binds.lua.tmpl` and
waybar's `modules.jsonc.tmpl`).
