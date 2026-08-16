# The remote host runs T3 Code upstream, not our fork

The desktop runs a patched T3 Code built by `t3fork` from `~/Projects/labs/t3code`, so
the obvious move for a remote host would be to run the same build there. We run
**upstream `npx t3@latest`** on the host instead, managed by `t3 service install`.

`t3fork` only knows how to build a Linux **AppImage** and register it as the desktop's
launcher entry — it has no notion of a remote machine, no headless install path, and no
way to keep one in step with a rebase. Running the fork on the host would mean inventing
that path (clone, build, systemd unit, upgrade story) and re-paying it at every rebase,
on a machine we deliberately treat as disposable. The patches are desktop-shaped; the
pairing protocol the host actually needs is upstream's.

## Consequences

- A patch that turns out to matter **server-side** reopens this decision. That is the
  signal to watch for — not general fork drift, which `dots update` already reports.
- The host and the desktop can run different T3 Code versions. Pairing is the
  compatibility surface, so an upstream protocol change is the thing that would break
  first.
- Nothing on the host is built from source, which is part of why it can be recreated by
  a script in minutes.
