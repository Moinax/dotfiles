# Private Finance and Daylight hosting

Production runs on DigitalOcean `apps-host` in Amsterdam, with Ubuntu 24.04,
1 vCPU and 2 GiB RAM. The droplet costs $12/month before tax; daily DigitalOcean
backups add 30%, for $15.60/month before tax at provisioning time.

- Finance: <https://finance.moinax.com>
- Daylight: <https://daylight.moinax.com>
- Public information and policies: <https://finance-info.moinax.com>

Access requires Tailscale and the configured owner, currently
`jerome@moinax.com`. The applications listen on loopback only. Caddy listens on
the host's Tailscale addresses, terminates HTTPS, and removes incoming Tailscale
identity headers. Tailscale's official `nginx-auth` helper resolves the TCP peer
through Whois. Caddy passes that login to each app, which checks its owner. The
DigitalOcean firewall has no inbound rules. SSH administration also uses the
tailnet after bootstrap. No Funnel or public application ports are configured.

The original `apps-host.taildade28.ts.net` URLs on ports 443 and 8443 redirect
to the custom domains. They are bookmark compatibility addresses, not OAuth
origins. The applications still validate Host, Origin, sessions, and OAuth state.

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

- `https://finance.moinax.com/api/callback`
- `https://daylight.moinax.com/auth/google/callback`

Keep the old Tailscale callbacks registered for rollback. Both callbacks run in
the browser, which must be connected to Tailscale. Do not replace the existing
provider clients, bank key, or connected accounts when changing URLs.

Daylight registers a new dynamic Todoist client on the next Connect action when
its origin changes. It preserves the credentials that issued existing refresh
tokens. The operator completes the normal Todoist consent in the browser.

## Custom domain setup and maintenance

`dots hosting prepare-domains` builds the pinned Tailscale auth helper on the
desktop and downloads Caddy with the Cloudflare DNS module. Versions live in
`tools/apps-host/build-proxy.py`; builds use two Go workers and repository scratch
storage. The Cloudflare token lives at
`/home/moinax/.config/apps-host/cloudflare-api-token`, mode 0600. It needs Zone Read
and DNS Edit for `moinax.com` only. The command sends it over SSH stdin into the
root-only `/etc/personal-apps/cloudflare.env` environment file.

Preparation verifies the new Enable Banking and Google callbacks, installs
`apps-proxy` and `apps-proxy-auth`, and initially uses ports 10443 and 18443,
with HTTP redirects on port 10080. Production HTTP redirects use port 80,
also bound only to the Tailscale addresses.
Caddy obtains certificates through DNS challenges; no public listener is needed.
`TS_PERMIT_CERT_UID=caddy` permits retrieval of the legacy Tailscale certificate
without granting Caddy Tailscale operator rights. Caddy renews both kinds of
certificates automatically. Keep the Cloudflare token valid for renewals.

Before activation, update the Finance application's public website, privacy,
and terms links in Enable Banking to `https://finance-info.moinax.com`,
`https://finance-info.moinax.com/privacy`, and `https://finance-info.moinax.com/terms`.
The public site is a separate static Vercel project. Do not deploy the app or its
data to Vercel. Finish any Google, Todoist, or bank authorization in progress;
browser-bound state cannot move between origins. Active bank authorizations
block activation until they finish or expire.

`dots hosting activate-domains` checks DNS conflicts and provider callbacks,
backs up the apps, switches their canonical origins, and replaces Serve with
Caddy on ports 443 and 8443. It tests both apps over HTTPS from the desktop before
adding the two explicit DNS-only A records pointing to the Tailscale IPv4 address.
The public Cloudflare wildcard, Twitch, and the public information site remain
unchanged. It then updates the desktop launchers. Existing DNS caches may keep
the public wildcard answer until its TTL expires.

`dots hosting configure` preserves active custom domains. `dots hosting setup`
reinstalls their service definitions when proxy configuration already exists.
`apps-proxy` and `apps-proxy-auth` are persistent system services. The former's
admin socket is accessible only to its local service user. Requests and callback
URLs are not logged. To validate changes, run the apps-host Python tests and
the Caddy integration tests in `tests/test_apps_proxy.py` after building the proxy.

Activation failures restore the previous app environment and Serve routing.
Before DNS creation, an operator can also run
`bash /opt/personal-apps/admin/proxy.sh rollback` over SSH as root. This restores
configuration only, never app data. After DNS creation, also remove only the two
explicit private records to return to the public wildcard and regenerate
launchers. Never reset all Serve or DNS configuration. The private backup
contains the proxy configuration and secret.

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
