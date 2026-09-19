---
description: Persistent Finance and Daylight hosting, separate from the disposable T3 development host.
paths:
  - tools/apps-host.py
  - tools/apps-host/**
---

# Private application host

- `apps-host` is persistent production on DigitalOcean. Never apply the T3
  provisioner, credential restore, or destroy workflow to it.
- Remote administration runs as root through key-authenticated SSH. Application
  services run as separate unprivileged users, with root-owned code.
- Keep both Node listeners on loopback. Caddy listens only on the Tailscale IPs
  for the custom domains. It strips client identity headers and gets the login
  through Tailscale's official `nginx-auth` Whois helper; each app authorizes its
  configured owner. Tailscale Serve is the bootstrap and rollback path.
- Public Finance information stays on `finance-info.moinax.com` through Vercel.
  Update provider policy links before making `finance.moinax.com` private. Never
  change the Cloudflare wildcard or proxy the private A records through Cloudflare.
- Close the DigitalOcean public firewall only after a new tailnet SSH connection
  succeeds. Do not enable Funnel.
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
