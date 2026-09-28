---
description: Required update metadata when adding a non-packaged tool to the package YAML files.
paths:
  - packages/**
---

# New non-packaged tool: declare update metadata

When adding a tool to `packages/common.yaml` (`tools:`) or a group's `custom_install:`,
declare its update metadata too — `binary:` (the executable name, which often differs from
the entry name: television ships `tv`), plus `source:` (owner/repo) or `npm:` so
`dots update` can resolve an upstream version. Never let the updater infer the
binary from the entry name.

The one carve-out: an entry whose executable name is already owned by an unrelated
distro package omits `binary:` on purpose. `resolve_owners` resolves it with
`command -v`, so the wrong package answers and the entry is reported as
pacman-managed — its release lookup skipped for good. Cover the probe with
`check:` (a path test) plus `version:` instead, and say so in the entry's comment.
codiff is the example: pahole ships /usr/bin/codiff.

`update:` is only ever a command; who owns updates is the separate closed-set
`updated_by:` — `self` (the tool updates itself), `app` (tracked by the external-apps
tool), `none` (deliberately not updatable), default `dotfiles`. Forgetting the metadata
entirely is reported as a gap rather than silently skipped, so `updated_by: none` is how
you opt an entry out on purpose.
