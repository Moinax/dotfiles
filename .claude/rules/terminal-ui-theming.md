---
description: Which TUI configs encode the no-explicit-background rule and by what mechanism, and the ccstatusline setting that plated the whole statusline.
paths:
  - home/dot_config/hunk/config.toml.tmpl
  - home/dot_config/tuicr/config.toml.tmpl
  - home/dot_config/starship.toml.tmpl
  - home/dot_config/ccstatusline/settings.json.tmpl
  - home/dot_config/nvim/lua/polish.lua
  - home/dot_config/yazi/**
  - home/dot_config/gh-dash/**
---

# Where the no-background rule is already encoded

The law itself is in `CLAUDE.md` — an explicit bg on a translucent pane paints an
opaque slab, and matching the terminal's base colour only changes the slab's hue.
This is which file does it how, so you do not undo one by "fixing" it.

- `hunk/config.toml.tmpl`, `tuicr/config.toml.tmpl` — `transparent_background = true`
- `nvim/lua/polish.lua` — clears `Normal` and `NormalFloat`
- `ccstatusline/settings.json.tmpl` — `overrideBackgroundColor` plus
  `flexMode: "full"` plated the whole statusline; both stay unset

**A background on the *focused row only* is a highlight, not this defect**, and
stays: `gh-dash`'s `background.selected`, a yazi mode chip.
