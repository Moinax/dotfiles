# The remote host runs our T3 Code fork, not upstream

Supersedes `docs/adr/0001`, on the signal 0001 named for itself: *"a patch that turns out
to matter server-side reopens this decision."* It did.

Six of the fork's fifteen commits are server-side skill discovery, all of them under
`apps/server/src/provider/`. Upstream 0.0.33 has none of it — grep its published bundle
and `skills` appears three times, every one of them the contract's field, with no code
behind it. Skills are resolved by whichever machine runs the agent, so a session paired
to the host asked the host, and the host answered with an empty list. Correctly, and
invisibly: an empty list and a broken client look identical from the composer.

`234be44d6` also widened `packages/contracts/src/server.ts`, so the fork's client already
expects fields upstream's server never sends. The compatibility break 0001 predicted as
"the thing that would break first" had already happened by the time this was written.

`phase_fork` in `tools/provision-droplet.sh` builds it, and `dots droplet fork` is the
one-phase form for the day-to-day case. The mechanics — why the hook is a systemd
drop-in rather than a link, and why losing the update launcher is the feature — are in
`.claude/rules/droplet.md`.

## Consequences

- **0001's cost estimate was right, and is now paid.** A clone, a build, a systemd unit
  and an upgrade story per rebase, on a machine treated as disposable. What changed is
  not the price but the alternative: upstream does not do the job.
- **The host builds what `origin/moinax` holds**, which is the last commit `t3fork
  update` was told to publish — it offers the push and never takes it. A declined offer
  leaves the desktop ahead of the host with nothing saying so, which is why the phase
  prints the sha it built rather than claiming parity.
- **The desktop and the host can still run different versions**, but now they diverge by
  a push rather than by a release. Pairing is still the compatibility surface; it is our
  own contract on both ends of it.
- **Self-update is deliberately off.** The unit no longer runs `service-launcher.mjs`, so
  the server cannot npm-install upstream over the fork — the failure `.claude/rules/
  t3-code-fork.md` documents for `dots apps`, which had a second road onto this machine.
- **`t3 service install` is still what creates the unit.** Only its `ExecStart` is
  overridden, so the upstream pinned runtime under `~/.t3/runtime/versions` stays on disk,
  unused. It costs disk and is what a removed drop-in falls back to.
- **The recovery path grew by three minutes**, once: `vp i` plus a build, skipped on every
  later run by the sha sentinel in `apps/server/dist/.built-from`.
