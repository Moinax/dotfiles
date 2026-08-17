---
description: What has to run after any `chezmoi apply` for the running desktop to show it — theme copies, user services, and reload/restart ordering.
paths:
  - install/lib/post-apply.sh
---

## `install/lib/post-apply.sh`

What has to happen after any `chezmoi apply` for the running desktop to show it:
Hyprland reload (its mid-apply autoreload fails on `conf/general.lua` requiring a
`conf/theme.lua` not yet written), herdr `reload-config`/`migrate-layout`, the
themed surface copies plus the swaync/swayosd/kitty reloads they need, the
declared user services that are enabled but not running, waybar
restart. Shared because these used to live in the installer only — the one script
you stop running once the machine is set up.

### The themed surfaces read a copy, so refreshing it *is* the reconciliation

Five surfaces — kitty, eza, swaync, swayosd, wlogout — read one fixed path
(`style.css`, `theme.yml`, `current-theme.conf`) and express the mode by copying
`style-dark.css` or `style-light.css` over it. None of those copies is managed:
the only thing that ever writes them is a dark/light toggle.

So an apply that rewrites the managed sources reaches *none* of them. Each copy
keeps whatever the last Mod+N put there and the change waits, silently, for the
next one. A font swap surfaced it as tofu across the whole notification panel
while `swaync-client -rs` cheerfully reported `success: true` — the reload
re-read a stylesheet that still named the by-then-uninstalled font. The other
five had the identical staleness and merely nothing visible to show for it,
which is the point: only swaync had a symptom, so only swaync would ever have
been fixed.

**`home/dot_local/lib/theme-copies.sh` owns the list**, deployed to
`~/.local/lib/` and sourced by both callers — `apply-dark-mode.sh` to switch
modes, `reconcile_theme_copies_after_apply` to reconcile after an apply. Two
copies of the list would go stale the first time a surface was added to one and
not the other, which is this bug again, one surface at a time.

**Reload policy deliberately stays with each caller**, because they need
different things. A toggle only changes colours, so swaync takes the cheap
`swaync-client -rs` — restarting on every Mod+N would drop every queued
notification. An apply can change *structure* (a font family), and a running
daemon keeps its old font map, so there the process must be replaced. Same
reason the post-apply restarts are gated on the file list while waybar's is
unconditional: a restart costs queued notifications, a copy costs nothing, so
the copies run unconditionally and only the reloads are gated.

kitty's SIGUSR1 is in that set for a second reason beyond the theme copy: kitty
reads `kitty.conf` once at startup, so a font or keybind change needs the same
signal.

Do **not** reach for `apply-dark-mode.sh` from post-apply. It would fix every
surface in one call, but it also runs `plasma-apply-colorscheme` and repaints
the whole desktop — and it ends by calling `chezmoi apply` itself, so invoking
it from a post-apply hook re-enters the thing that just ran.

Known limit of hanging this off post-apply: it only fires through
`apply_dotfiles`/`run_post_apply`, so a bare hand-run `chezmoi apply` still leaves
all six copies stale. That is the general rule about hand applies, not a special
case — but it is the one path this reconciliation does not cover.

### A user service installed mid-session is enabled but dead

A user unit is almost always `WantedBy=graphical-session.target`, and systemd
pulls in `Wants` only when the target **activates**. So a package installed while
you are logged in gets its unit enabled and never started: it reads `enabled`,
the journal is empty, and it stays that way until the next login.

vicinae shipped exactly like that. `dots update` installed `vicinae-bin` at
10:42, one minute after graphical-session.target had been reached, its own
systemd preset enabled it, and the server never ran — with every Hyprland keybind
firing a `vicinae://` deeplink at nothing. It looked like a broken config; the
config was fine and `hyprctl binds` had all 131 binds loaded.

Nothing in the repo closed that before: `services:` is the **system** half and
goes through sudo, and `enable_selected_services` lives in the installer — the
script you stop running once the machine is set up. That left `dots update`, the
one path that installs packages onto a live desktop, as the one path that could
leave a daemon dead.

`user_services:` in a group yaml is the per-user list, read by
`parse_user_services` — one of four one-line wrappers over `parse_yaml_list`,
along with `parse_dotfiles`, `parse_services` and `parse_desktop_only`. Adding
this key is what forced that generalisation: the yq-less fallback loop existed in
three hand-copied versions, and **only the `desktop_only` copy ever learned to
strip an inline comment**, so `- vicinae.service  # the launcher` parsed cleanly
as one list and yielded a unit name with the comment glued on as another. The yq
path never had the bug, so it lived only on the fallback nobody tests. Add a list
to the schema by adding a wrapper, never another copy of the loop.

**Which systemd instance a unit belongs to is data, not something to infer.**
Nothing in `vicinae.service` says it is a user unit, so the two lists stay
separate rather than being sniffed from the name — guessing wrong means either a
sudo prompt for a unit root cannot see, or a system unit silently enabled in the
user instance. `_systemctl_query` / `_systemctl_admin` in services.sh are the
only two places that difference is spelled out, and they encode the reason for
the split: queries (`is-enabled`, `is-active`) never need root, and the user
instance must never see sudo at all, because `sudo systemctl --user` does not
fail — it acts on *root's* session, which is the worst failure available here.

`for_each_service <verb> <names…>` is where the dedupe lives, and it takes the
verb because the four system/user × enable/disable combinations differ in nothing
else. There was briefly a `parse_declared_services` reading both lists in one yq
call for the install path — deleted: that loop already spends several yq calls
per group plus four per custom entry, so folding two of them saved ~170ms of a
multi-minute install and cost a second tagged-row format to keep beside
`group_declared_lists` (the one-yq-call-per-group-file reader, `sync-machine.md`). A saving that only the once-per-machine path can collect
is not worth a parallel protocol.

**`reconcile_declared_services` in sync-machine.sh is the one that matters on an
existing machine**, and it covers base *and* every enabled group, both instances.
It was scoped to base first, which was a notch too narrow and made the
`user_services:` declaration above inert everywhere but a fresh install:
`enable_selected_services` is installer-only, `sync_group_after_change` fires
only for groups a *package* change touched (a group that merely gained a service
is never visited), and `start_user_services_after_apply` never enables. So
vicinae kept working only because vicinae-bin ships its own systemd preset —
precisely the coincidence that declaring it was meant to replace.

**`start_user_services_after_apply` starts only what is already enabled, and
never enables anything.** That is what makes it safe to run on every update:
`is-enabled` cannot distinguish a unit nobody has enabled yet from one the user
deliberately disabled, so enabling here would silently undo a
`systemctl --user disable` at the next `dots update` — the same nagging the
anchor design exists to prevent. Enabling belongs to the two places with a reason
to believe it is wanted: `enable_selected_services`, and a group being switched
on in `dots packages`.

It is also the one reconciliation deliberately **not** gated on the changed-file
list, because its trigger is a *package* install, which leaves no trace in the
files an apply touched. Being ungated on a path that runs every time is what
makes the order of its guards the entire cost of the feature, so they escalate:
`systemctl` exists (free) → a graphical session is active (~9ms) → `grep -l
'^user_services:'` across the group files (~9ms) → `group_enabled` → yq. The
first version asked none of that and simply parsed all eight group files, which
is **~1.2s of every apply** to read a line that exists in one of them — the whole
budget the ~5.9s→1.2s catalogue-scan optimisation (`sync-machine.md`) bought
back, re-spent on a more
frequent path. With the guards it is ~0.2s on a desktop and ~5ms headless.

The graphical-session check is deliberately asked twice: once here as a
machine-wide precondition (if it fails, nothing can be started, so the scan is
pure waste) and once per unit inside `start_user_service_if_needed`, which
`enable_user_service` calls directly and which therefore cannot rely on this
caller having asked.

It resolves the groups directory from `BASH_SOURCE`, **not** from `$DOTFILES_DIR`.
That variable is a caller precondition and `dots` does not meet it — it sets only
`SCRIPT_DIR` — so `dots reconfig`, which applies through `apply_dotfiles`, globbed
`/packages/groups/*.yaml`, matched nothing and reconciled nothing, silently.

Note the explicit `return 0` at the end. The `for` loop's exit status is whatever
its last iteration left, and a disabled group exits via `continue` after a failed
`group_enabled` — so without it the function returns 1 on any machine whose last
group file alphabetically is switched off, and installer.sh's `set -e` reads that
as a failure and aborts between there and the waybar restart, silently.

`post-apply.sh` sources `services.sh` itself rather than trusting its callers:
installer.sh sources it only inside `enable_selected_services`, and
sync-machine.sh not at all, so the helper would have been undefined on precisely
the `dots update` path it was written for.

`run_post_apply` takes the list of files an update changed and fires only the
reconciliations that list justifies; called with no arguments (a full install,
where there is no "before") it runs all of them. Waybar goes last, after the
caller's tool refresh: the bar's custom modules are long-lived `exec` children
(`vibewatch status --watch` streams until killed), so a bar restarted before the
binary underneath it moves keeps running the old one.

**`apply_dotfiles` is the sanctioned apply**, and `chezmoi apply` should not
appear anywhere else: it is `chezmoi_apply` + `run_post_apply`, so "an apply is
always reconciled" is an invariant rather than a convention each caller has to
remember. `dots reconfig` and `dots packages` both used to forget it, and they
apply at exactly the moment a group flag has just rewritten the bar and the hypr
tree. The one exception is `dots update`, which calls the two halves itself
because the tool refresh has to land between them — see the waybar rule above.

The herdr layout trigger matches **any** `executable_herdr-*` / `dev-herdr`
script, not the three that happen to build panes today. A missed
`migrate-layout` does not fail; it brings the old layout back at the next server
restart, hours later, with nothing tying it to the update that caused it. A name
list would go stale silently, and over-triggering costs one idempotent call that
the full-install path already makes unconditionally.
