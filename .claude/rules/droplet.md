---
description: The DigitalOcean host has no backups, so the provisioner is its recovery path — the three traps its phase order encodes, and why running a phase standalone is where they bite.
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

## Three traps in the phase order, none of which announce themselves

Phase order is the whole safety property, so **invoking a phase on its own is
where these bite** — `setup` runs them in an order that already avoids all three.

- **`firewall` must run after Tailscale is up.** Deny-all removes SSH and leaves
  only the DO web console.
- **`destroy` waits for the droplet to leave the listing.** `doctl`'s delete
  returns first, and a following `create` then finds it "already exists" and
  silently skips.
- **`just` comes from just.systems, not apt.** Ubuntu 24.04 ships 1.21 while
  socle's justfiles use the `[group]`/`[doc]` attributes added in 1.27 — apt's
  build fails parsing the recipe list before running anything.

## The manual half sends the working tree

`tools/droplet-wizard.sh` sends `tools/backup-projects.sh` from **the working
tree**, never a clone of the published repo: the scoped-restore flags it depends
on may not be pushed yet.
