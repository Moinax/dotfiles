---
description: The two things a Hyprland keybinding edit owes — the KEYBINDINGS.md reference, and the vicinae provider id that a deeplink bind cannot guess.
paths:
  - home/dot_config/hypr/conf/binds.lua.tmpl
---

# Editing the keybindings

**Update `KEYBINDINGS.md` at the repo root in the same change.** It is the human
reference and nothing regenerates it.

**A `vicinae://` bind cannot guess its target.** A local extension's provider id is
`@<author>/<name>` from the manifest, not `<name>` —
`vicinae://launch/@moinax/moinax/dev`. Run `vicinae cmd ls`, which prints every
registered id; the rest of that mechanism is in `vicinae-extensions.md`.
