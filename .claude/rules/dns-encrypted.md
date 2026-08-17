---
description: Why DNS is moved by clearing a link's default-route flag rather than replacing its servers, the two blunter levers that were tried, and the three traps the dispatcher encodes.
paths:
  - install/lib/dns-encrypted.sh
---

# Encrypted DNS, and the flag that makes it reachable

`install/lib/dns-encrypted.sh` writes two files — a `systemd-resolved` drop-in
naming Cloudflare and Quad9 over TLS, and an NM dispatcher script — and both
`dots setup` and `dots update` call it (`reconcile_encrypted_dns`; the shared
shape of those privileged steps is in `sync-machine.md`). This one is worse than
the login wallpaper in one respect, and that is the whole argument for the split:
a black lock screen is at least *visible*, while a machine still sending every
lookup to its ISP looks and behaves exactly like one that is not.

**The lever is the link's default-route flag, and finding it took three wrong
turns.** resolved keeps one server list per *link* and picks the link from the
name being resolved; a global `DNS=` is read only when no link has a server at
all, so a drop-in on its own changes nothing, silently. NetworkManager sets
`default-route` on whichever link holds the default gateway — which is how the
DHCP resolver of whatever network you plugged into wins every lookup. Clearing
that one flag keeps the link's servers, its search domain *and* short-name
completion, so `.home` names still resolve through the box while everything else
goes out over TLS.

The two blunter levers were both tried and both cost something:
`ipv4.ignore-auto-dns` takes the search domain with it (no local names, on every
network), and `ipv4.dns-search "~home"` keeps routing but kills short-name
completion and hardcodes the domain. Because the flag names nothing, the
dispatcher carries no interface, connection, IP or domain and is the same file on
every machine.

**`encrypted_dns_needs_setup` compares content, not existence.** Both file bodies
come from functions the writer also uses, so changing a resolver later reads as
drift on machines carrying the old drop-in and is repaired; an existence check
would leave them behind silently. This already earned itself once — the first
hand-placed dispatcher lacked the `~.` guard, and the content check is what
noticed.

## Three traps

**The `~.` guard is not hypothetical.** A link routing `~.` is claiming every name
deliberately — that is what tailscaled sets for an exit node or a tailnet-wide
resolver — and `tailscale0` is NM-managed, so the dispatcher fires for it. Without
the guard, switching on an exit node would break its DNS months later with nothing
tying the two together. Matched as a whole token: the reverse zones tailscale also
installs read `~0.e.1.a…`, which a naive `grep '~\.'` would hit.

**`opportunistic`, not strict TLS.** A captive-portal decision rather than a weak
one: hotel and airport networks authenticate by hijacking DNS, so strict mode
means the login page never appears and the machine never gets online.

**Two *operators*, not two addresses of one.** 1.1.1.1 and 1.0.0.1 are one anycast
network and fell over together in July 2024, so the second server is Quad9.
Swapping it back for a Cloudflare address reads as tidying and silently reinstates
the single point of failure.

## Verifying it, and the two ways verification lies

- **Never report TLS as working off `resolvectl status`** — it shows the
  configuration whether or not it negotiated. `ss -tn | grep :853` shows the real
  connection.
- **`reload`, not `restart`, and that is measured.** The unit is
  `Type=notify-reload` with `CanReload=yes`, and SIGHUP makes resolved re-read its
  configuration files, drop-ins included (systemd 256+). Verified by adding a third
  server to the drop-in and watching it appear, then disappear, on a bare `reload`.
  A restart tears the resolver down and has NM re-push every link's DNS on the way
  back up, for nothing. The trap in verifying it: `resolvectl status` **wraps** a
  long server list onto a continuation line, so `grep -m1 'DNS Servers'` reports
  the reload as having done nothing and sends you back to `restart`. Read the whole
  `Global` block.

**`apply_encrypted_dns` re-runs the dispatcher over the active links itself**,
because the script only fires on a link coming *up* — without that pass the machine
it was just installed on keeps its old resolver until the next reconnect. It
invokes the installed script rather than repeating its one line, so the `~.` guard
cannot come to exist in two places and drift.

Not gated on `install_purpose_is desktop` — a headless box resolves names too — but
the lib skips itself where `resolvectl` or `nmcli` is absent.
