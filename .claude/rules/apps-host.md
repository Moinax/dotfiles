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
