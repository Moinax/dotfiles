# Private Finance and Daylight hosting

Production runs on DigitalOcean `apps-host` in Amsterdam, with Ubuntu 24.04,
1 vCPU and 2 GiB RAM. The droplet costs $12/month before tax; daily DigitalOcean
backups add 30%, for $15.60/month before tax at provisioning time.

- Finance: <https://apps-host.taildade28.ts.net>
- Daylight: <https://apps-host.taildade28.ts.net:8443>

Access requires Tailscale and the configured owner, currently
`jerome@moinax.com`. The applications listen on loopback only. Tailscale Serve
terminates HTTPS and supplies identity, which the applications verify. The
DigitalOcean firewall has no inbound rules. SSH administration also uses the
tailnet after bootstrap. No Funnel or public application ports are configured.

## Operations

Run `dots hosting help` for the command list. Administration runs as root on the
remote host over SSH; nothing here needs local sudo. This host is separate from
`dots droplet`, which manages the disposable T3 development machine.

The initial sequence is `create`, `setup`, `join`, `configure`, `firewall`,
`deploy`, `migrate`, `backup`, `restore-check`, `install-pull-timer`, and
`install-launchers`. `join` prints the Tailscale login link. `configure` derives
the owner's identity from the desktop tailnet session. Creating or setting up
an existing host does not replace its application data.

Use `dots hosting deploy finance` or `dots hosting deploy daylight` after tests
pass. Omitting the application deploys both. Builds run on the desktop;
production dependencies are installed on the host. Releases include current
working-tree changes, record the Git HEAD and dirty state, and use a content
hash as their directory name. Nothing is committed or pushed by deployment.
The server retains the original source archive alongside each release.

A failed startup check returns to the previous code release. Database migrations
are not reversed automatically. Run `dots hosting backup` before a deployment
that changes stored data. `dots hosting status` checks services, HTTPS routing,
backup scheduling, memory and disk usage.

## Data and local development

The systemd services run as distinct `finance` and `daylight` users. Code under
`/opt/personal-apps` is root-owned. Persistent data lives in `/var/lib/finance`
and `/var/lib/daylight`; environment files live in `/etc/personal-apps` and are
readable only by root. systemd passes those variables to each service.

The migration command refuses a second import. It stops local services before
copying data, then disables them after moving to the server. Old local data is
retained for recovery and is no longer current. Never run the old Daylight
store alongside production: refresh tokens rotate and must have one owner.
`pnpm dev` selects mock banks and `.scratch/dev.sqlite` in Finance, and
`.scratch/dev-data` in Daylight. Both projects use pnpm for dependencies,
builds and tests.

Keep localhost callback registrations for local development. Enable Banking
and Google also need the production callback in their existing application:

- `https://apps-host.taildade28.ts.net/api/callback`
- `https://apps-host.taildade28.ts.net:8443/auth/google/callback`

Daylight registers a new dynamic Todoist client on the next Connect action when
its origin changes. It preserves the credentials that issued existing refresh
tokens. The operator completes the normal Todoist consent in the browser.

## Backups and recovery

DigitalOcean daily backups retain seven days. The application backup timer
runs daily around 03:15 UTC, capturing SQLite through its backup API, the atomic
Daylight file and its master key, both environment files, the bank key, and
both deployed source archives. It encrypts the archive before retaining it on
the host, with a 14-day retention window.

The desktop timer fetches encrypted archives hourly when online, retaining the
most recent 30 in `~/Backups/apps-host`. It does not delete the desktop's last
copy merely because the host is offline. The server's DigitalOcean backup does
not depend on the desktop being online. A long desktop outage delays the
independent application archive copy.

The decryption identity is `~/.config/apps-host/backup.agekey` on the desktop,
mode 0600. The desktop SSH key is also an archive recipient, providing recovery
with its passphrase if the dedicated age key is lost. Neither private key is
sent to the server. Keep the desktop SSH key or the dedicated age identity in
your password manager or another recovery location.

`dots hosting restore-check` decrypts the newest local archive under the
repository's `.scratch`, checks SQLite integrity, loads Daylight's encrypted
store without contacting providers, and checks the configuration and source
archives. It removes the plaintext scratch copy even on failure.

For an actual recovery, first stop both application services on the old host.
Provision the replacement and join Tailscale with a new identity; do not clone
a live node identity. Decrypt an archive into private scratch storage using
`age -d -i ~/.config/apps-host/backup.agekey`. Restore the data and configuration
to their paths above, reinstall dependencies from the saved release archives,
and restore ownership before starting services. If the tailnet hostname
changes, configure the new origins and callback registrations. Verify HTTPS,
provider sync and a new backup before retiring the old host. Restoration is
manual because overwriting live data requires a deliberate recovery decision.
