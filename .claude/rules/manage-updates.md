---
description: What the tool refresh covers that cachy-update cannot see — `refresh NAME…`, global npm packages across a Node bump, and GitHub rate limits.
paths:
  - tools/manage-updates.sh
---

## `dots update` — `tools/manage-updates.sh`

Deliberately does NOT update the system: pacman + AUR belong to cachy-update (a symlink
to arch-update, which picks up paru on its own), which the sync now calls as its own
phase before this one (`sync-machine.md`). It covers only what cachy-update can't
see — curl binaries, global npm packages, the fnm-managed Node, cargo installs, and
tracked external apps. Anything whose binary turns out to be owned by a pacman/AUR
package is reported as managed and skipped, never refreshed: several entries also exist
as distro packages, and re-running their curl installer would shadow the packaged copy
(`/usr/local/bin` over `/usr/bin`).

### `refresh NAME…` — the installer's post-install pass

`dots setup` only ever fills gaps: a `custom_install`/`tools` entry whose `check` passes is
left at whatever build it was first installed with, since `check` asks *whether* a tool
exists and never *which version*. So a long-lived machine kept its original binary across
every re-run (a July vibewatch survived a `dots setup` three releases later). `refresh`
closes that: the installer collects the entries it skipped into `PREINSTALLED_TOOLS` and
hands them here, and one `gum confirm` covers the whole batch — a setup re-run started for
an unrelated reason must not silently spend minutes on a `cargo install --git`.

The name list sets `ONLY_NAMES`, filtered in `collect_section_candidates` *before* the
per-entry yq read, so a two-name refresh doesn't pay for a twenty-entry scan. A filtered
run also drops the Node candidate (a setup re-run offers back the entries setup skipped,
and the toolchain underneath them is not one of those) and the external-apps check
(`dots apps`' inventory, never a yaml entry, and it spends the same GitHub quota the
filtered lookups need).

### Moving Node has to carry the global npm packages

A global npm package lives inside the Node version's own tree, so `fnm default` landing on
a new LTS leaves an empty `node_modules` and every one of them gone — hunk, ccstatusline
and pnpm all vanished this way on the v24.18 → v24.19 bump, taking the review pane and the
statusline with them. Nothing downstream recovered that: `packages sync` can't see it (a
`check: command -v hunk` that passed on the old version passes on nothing afterwards), and
the updater reported the package as a non-actionable row — so the old advice to "run
`dots update` again to reinstall any that moved" was simply false.

**Prevention** is `install_node_lts`'s job in common.sh: `list_global_npm_packages` reads
the names off the version being left, and `reinstall_global_npm_packages` puts back
whatever the version landed on is missing. Both go through `FNM_GLOBALS_DIR`, one constant,
because the path is stable while its target moves. A package npm can't fetch is warned
about and left, never fatal — Node itself did move, and rolling that back over one package
would be worse.

It sits in `install_node_lts` rather than in the updater's `apply_row` because it belongs
welded to the `fnm default` that causes the stranding: a future caller that moves Node
inherits the repair without having to know it needs one. Note that `dots update` is the
only caller that can trigger it today — `ensure_node_toolchain` reaches `install_node_lts`
only inside `if ! fnm ls | grep -q 'lts\|v[0-9]'`, so the installer provisions Node but
never bumps it, and on that path the read finds nothing and costs one stat. Do not "fix"
the placement on the grounds that the installer never uses it; coupling is the reason.

**Recovery**, for a machine already stranded, is the `missing` report status. It exists
apart from `absent` because the two absences are not equally fixable: a global npm
package's entire install command is `npm install -g`, which `apply_row`'s npm case already
runs — and npm treats install-over and install-fresh alike, so one apply path serves an
outdated row and a missing one — whereas an absent *binary* entry needs its yaml
`install:` and stays pointed at `dots packages sync`. Folding them into one status would
have forced `actionable_rows` to either skip the recoverable half or offer the other half
an action it cannot carry out. A `missing` row shows `—` for both versions because neither
`npm outdated -g` nor `npm ls -g` lists a package that isn't installed, and its selection
label reads "install" rather than "refresh (—)".

Ordering in the installer matters and is not incidental: the refresh runs *after*
`setup_dotfiles`, because `group_enabled` reads chezmoi data that `setup_dotfiles` has only
just written — an earlier scan finds no enabled group and reports nothing to do. The waybar
restart then runs *after* the refresh, because the bar's custom modules are long-lived
`exec` children (`vibewatch status --watch` streams until killed), so a bar restarted
before the binary moves keeps running the old one.

GitHub release lookups go through `manage-external-apps.py` (shared concurrent cache) and
use `gh auth token` when available — unauthenticated api.github.com allows only 60
requests/hour, which one scan plus an app check can exhaust, vs 5000 authenticated. An
exhausted quota is reported as such: rows show 'unknown' rather than silently reading as
up to date.
