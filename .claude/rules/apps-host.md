---
description: Persistent private Finance/Daylight and public Twitch Grid hosting, separate from T3.
paths:
  - tools/apps-host.py
  - tools/apps-host/**
---

# Application host

- `apps-host` is persistent production on DigitalOcean. Never apply the T3
  provisioner, credential restore, or destroy workflow to it.
- Remote administration runs as root through key-authenticated SSH. Application
  services run as separate unprivileged users, with root-owned code.
- Keep all Node listeners on loopback. The private Caddy service listens only on
  Tailscale IPs for Finance and Daylight. It strips client identity headers and gets the login
  through Tailscale's official `nginx-auth` Whois helper; each app authorizes its
  configured owner. Tailscale Serve is the bootstrap and rollback path.
- Twitch Grid is public on `twitch.moinax.com`. Its separate `apps-public-proxy`
  service binds only the droplet's public IPv4, serves its `dist`, and forwards
  `/api/*` to `twitch-grid` on loopback port 8766. Never import the private app
  routes into this proxy. Both public services have dedicated users and cannot
  read Finance or Daylight data. Public TCP 80/443 are allowed by the separate
  `apps-host-public-web` firewall; public SSH and other ports remain closed.
- Public Finance information stays on `finance-info.moinax.com` through Vercel.
  Update provider policy links before making `finance.moinax.com` private. Never
  change the Cloudflare wildcard or proxy the private A records through Cloudflare.
- Close the DigitalOcean public firewall only after a new tailnet SSH connection
  succeeds. Keep the public web exception when reconciling the baseline firewall.
  Do not enable Funnel.
- Migrate once, with local services stopped, then disable those services. Two
  Daylight instances must not rotate the same refresh tokens concurrently.
- Back up SQLite using its backup API, and Daylight's atomic encrypted file with
  its master key. Encrypt to the dedicated desktop age key and the desktop SSH
  public key as a recovery recipient. Never log
  payloads, credentials, or decrypted backups.
- Backups include the deployed source archive because a deployment can include
  unstaged changes. The encrypted archives are pulled to the desktop when online;
  DigitalOcean daily backups cover the host independently of the desktop.
- Use `dots hosting help` for commands. Restore into isolated scratch storage
  before touching live data. No automatic restore or destructive host command.

## Recovery facts

- Finance is `finance.moinax.com`, Daylight is `daylight.moinax.com`; the old
  `apps-host.taildade28.ts.net` addresses (443 / 8443) redirect and are kept as
  bookmark and rollback addresses, not OAuth origins. Provider callbacks to keep
  registered: `https://finance.moinax.com/api/callback` and
  `https://daylight.moinax.com/auth/google/callback`, plus the localhost ones.
- On the host: code under `/opt/personal-apps` (root-owned), data in
  `/var/lib/finance` and `/var/lib/daylight`, environment files in
  `/etc/personal-apps` (root-only, passed to each service by systemd). Proxy
  rollback before DNS changes: `bash /opt/personal-apps/admin/proxy.sh rollback`
  as root, configuration only.
- Twitch Grid has no server-side user data. Its API credentials are in
  `/etc/personal-apps/twitch-grid.env`; public proxy configuration is in
  `/etc/apps-public-proxy` and `/etc/personal-apps/public-proxy.env`.
  Preparation reads the two Twitch search credentials from its local `.env.local`.
  Deploy it explicitly; a bare deploy still targets only Finance and Daylight.
  The encrypted backup includes its release and public proxy configuration.
  `twitch-dns-rollback.json` is historical only: the Vercel Twitch Grid project was
  deleted after migration. Keep the explicit Twitch A record; inheriting the
  Vercel wildcard would no longer restore the site. Recover from host release
  archives instead.
- On the desktop: decryption identity `~/.config/apps-host/backup.agekey` (0600),
  Cloudflare token `~/.config/apps-host/cloudflare-api-token` (0600, Zone Read +
  DNS Edit on `moinax.com` only), pulled archives in `~/Backups/apps-host` (last
  30, hourly when online). Host keeps 14 days; DO backups keep 7. Neither private
  key ever goes to the server.
- Actual recovery is manual, by design: stop both services on the old host,
  provision a replacement and join Tailscale with a **new** node identity, decrypt
  an archive with `age -d -i ~/.config/apps-host/backup.agekey` into private
  scratch, restore data and configuration to the paths above, reinstall
  dependencies from the saved release archives, fix ownership, then verify HTTPS,
  provider sync and a fresh backup before retiring the old host. A failed deploy
  health check rolls back code only, never migrations — `dots hosting backup`
  before any deploy that changes stored data.
