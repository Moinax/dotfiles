---
description: The DigitalOcean host has no backups, so the provisioner is its recovery path — the four traps its phase order encodes, why running a phase standalone is where they bite, and the mechanics of building the T3 Code fork there.
paths:
  - tools/provision-droplet.sh
  - tools/droplet-wizard.sh
---

# The provisioner is the recovery path

The DigitalOcean host has no backups, so `tools/provision-droplet.sh` *is* the
recovery path: every phase is idempotent and re-running `setup` on a live host is
the repair, not a reinstall (see `docs/adr/0002`).

**The repo's one deliberate non-Arch target, and not the start of multi-distro
support.** It provisions the remote box that runs T3 Code headless
(`dots droplet`), is unreachable from `dots setup`, and deliberately does not
source `install/lib/common.sh` — its remote half is scp'd to a bare box that has
none of this repo.

## Four traps in the phase order, none of which announce themselves

Phase order is the whole safety property, so **invoking a phase on its own is
where these bite** — `setup` runs them in an order that already avoids all four.

- **`firewall` must run after Tailscale is up.** Deny-all removes SSH and leaves
  only the DO web console.
- **`destroy` waits for the droplet to leave the listing.** `doctl`'s delete
  returns first, and a following `create` then finds it "already exists" and
  silently skips.
- **`fork` must run after `sshkey`.** The clone authenticates with the key that
  phase generates, and reaches GitHub through the `ssh-keyscan` entry it adds to
  `known_hosts` — `dots droplet fork` against a host that never completed `setup`
  hangs forever on a host-key prompt, with the `-t` tty attached and nobody there
  to answer it.
- **`just` comes from just.systems, not apt.** Ubuntu 24.04 ships 1.21 while
  socle's justfiles use the `[group]`/`[doc]` attributes added in 1.27 — apt's
  build fails parsing the recipe list before running anything.

## The fork phase, and what is not obvious about it

`docs/adr/0003` says why the host builds our fork; these are the mechanics that
bite when you touch `phase_fork`.

- **`t3 service install` does not run the binary you invoked it with.** It
  `npm install t3@<version>`s a pinned runtime under `~/.t3/runtime/versions`
  and points the unit's launcher at *that*, so `npm link`ing the fork changes
  nothing. The hook is a systemd drop-in on `ExecStart` — `20-fork.conf`, read
  after `phase_env`'s `10-path.conf`, and the empty `ExecStart=` before the real
  one is what clears the unit's own line. **Dropping `service-launcher.mjs` is
  the feature**: the launcher is the self-update supervisor, and self-updating a
  fork host means npm-installing upstream over our build.
- **`vp i` dirties `pnpm-lock.yaml` every run**, so the phase's refuse-on-dirty
  guard excludes that one path. It is the same toll `t3fork` pays on the desktop
  with `rebase --autostash`, and without the exception the phase refuses on its
  second run, forever, over a file it dirtied itself.
- **`vp run --filter t3 build`, never `build:bundle`.** The short one is the two
  `vp pack` calls; the web client only reaches `dist/client` through the `build`
  task's `dependsOn @t3tools/web#build`. Built short, the server comes up, serves
  no UI at all to a browser or a phone, and says so in one line of build log.
- **What lands is what `origin/moinax` holds** — the last commit `t3fork update`
  was *told* to publish, since it offers the push and never takes it. The phase
  prints the sha for that reason.

## The manual half sends the working tree

`tools/droplet-wizard.sh` sends `tools/backup-projects.sh` from **the working
tree**, never a clone of the published repo: the scoped-restore flags it depends
on may not be pushed yet.
