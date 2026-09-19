---
description: The DigitalOcean host has no backups, so the provisioner is its recovery path — the four traps its phase order encodes, why running a phase standalone is where they bite, and the mechanics of building the T3 Code fork there.
paths:
  - tools/t3-host.sh
  - tools/t3-host-wizard.sh
---

# The provisioner is the recovery path

The DigitalOcean host has no backups, so `tools/t3-host.sh` *is* the
recovery path: every phase is idempotent and re-running `setup` on a live host is
the repair, not a reinstall.

## Why the host is what it is

- **It is a dev box, not a hosting box.** It exists so agent work survives a
  powered-off desktop: T3 Code headless, the agent CLIs, the dev stacks under
  `~/Projects`. It hosts nothing — no public service, no port on its public IP —
  and nothing on it is backed up: no DO backups, no disk snapshots. Everything
  that matters is pushed to a forge; unpushed work does not exist. The persistent
  application host (`apps-host.md`) is the opposite machine, and merging the two
  would cost the right to destroy this one on a whim.
- **Credentials are snapshotted; data never is.** The host's own SSH keypair,
  forge tokens, agent OAuth logins and Tailscale identity are unique to it and on
  no forge — `dots t3-host snapshot` saves exactly those (~20 KB, age-encrypted)
  and buys back the browser wizard, not the disk. `~/.t3/userdata/state.sqlite`
  is deliberately excluded: a snapshot that grew to cover data would reverse the
  decision by accident.
- **Agents effectively have root** (the `docker` group). Acceptable because the
  host holds no unique data and every credential on it is revocable alone —
  which is why `~/.ssh` is never copied there.
- **It builds our T3 Code fork, not upstream.** Upstream was the first choice,
  to avoid paying a clone, a build, a unit and an upgrade story per rebase on a
  disposable machine. It was reversed when six fork commits turned out to be
  server-side skill discovery under `apps/server/src/provider/`, which upstream
  has none of: skills resolve on whichever machine runs the agent, so a session
  paired to an upstream host got an empty list, silently. The fork's client also
  expects contract fields upstream's server never sends. The price is now paid,
  and the alternative does not do the job.

**A remote Ubuntu target, not local multi-distro support.** It provisions the
disposable box that runs T3 Code headless. The persistent application host has
its own provisioner in `tools/apps-host/` and `tools/apps-host.py`.
The T3 provisioner (`dots t3-host`) is unreachable from `dots setup` and does not
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
  `known_hosts`. It used to *hang* on a host that never completed `setup` — a
  host-key prompt with the `-t` tty attached and nobody there — which stopped
  being merely a footgun once `t3fork` began offering `dots t3-host fork`
  automatically after a push. The clone now carries `GIT_SSH_COMMAND` with
  `accept-new`, so that state fails on authentication instead, which is a
  message rather than a wedge. The ordering still stands: without the key there
  is nothing to authenticate with.
- **`just` comes from just.systems, not apt.** Ubuntu 24.04 ships 1.21 while
  socle's justfiles use the `[group]`/`[doc]` attributes added in 1.27 — apt's
  build fails parsing the recipe list before running anything.

## The fork phase, and what is not obvious about it

The section above says why the host builds our fork; these are the mechanics
that bite when you touch `phase_fork`.

- **`t3 service install` does not run the binary you invoked it with.** It
  `npm install t3@<version>`s a pinned runtime under `~/.t3/runtime/versions`
  and points the unit's launcher at *that*, so `npm link`ing the fork changes
  nothing. The hook is a systemd drop-in on `ExecStart` — `20-fork.conf`, read
  after `phase_env`'s `10-path.conf`, and the empty `ExecStart=` before the real
  one is what clears the unit's own line. **Dropping `service-launcher.mjs` is
  the feature**: the launcher is the self-update supervisor, and self-updating a
  fork host means npm-installing upstream over our build.
- **Use `vp i --frozen-lockfile` on the 4 GiB host.** Resolving the workspace
  again can exhaust Node's default heap. The dirty-tree guard still excludes
  `pnpm-lock.yaml` so checkouts changed by older provisioner runs can recover.
- **`vp run --filter t3 build`, never `build:bundle`.** The short one is the two
  `vp pack` calls; the web client only reaches `dist/client` through the `build`
  task's `dependsOn @t3tools/web#build`. Built short, the server comes up, serves
  no UI at all to a browser or a phone, and says so in one line of build log.
- **What lands is what `origin/moinax` holds** — the last commit `t3fork update`
  was *told* to publish, since it offers the push and never takes it. The phase
  prints the sha for that reason.

## The manual half sends the working tree

`tools/t3-host-wizard.sh` sends `tools/backup-projects.sh` from **the working
tree**, never a clone of the published repo: the scoped-restore flags it depends
on may not be pushed yet.
