# Private applications have a separate persistent host

Finance and Daylight need to remain available when the desktop is off. Their
data cannot be recreated from Git. They run on `apps-host`, a dedicated
DigitalOcean Ubuntu 24.04 droplet in Amsterdam, rather than the disposable T3
development host described in ADR 0002.

The host starts with 1 vCPU and 2 GiB RAM. Builds run on the desktop. Each app
has a systemd service, an unprivileged account, root-owned release directories,
and a private writable data directory. The application host has no agent CLIs
or development stacks. Administration uses a desktop SSH key.

Tailscale Serve terminates HTTPS and proxies to loopback-only Node listeners.
Finance uses HTTPS port 443; Daylight uses 8443 on the same tailnet hostname.
Applications authorize the configured Tailscale login and validate request
origins. The public DigitalOcean firewall has no inbound rules. Named Tailscale
Services can replace the port-based addresses later, with corresponding OAuth
registration updates.

Daily DigitalOcean backups protect the machine. A daily application backup
also captures a consistent SQLite copy, Daylight data and encryption key,
configuration, banking key, and the source archives of both deployed releases.
Archives are encrypted to a dedicated desktop age key and the desktop SSH key
as a recovery recipient. They are retained for 14 days
on the host. An hourly desktop timer retrieves archives when the desktop is
online and retains the most recent 30. That second copy is not continuously
offsite while the desktop is unavailable.

Local services are stopped before migration and disabled afterward to prevent
divergent data and refresh-token rotation by two installations. Local source
and data remain available for recovery. Tests use isolated data and providers.

Deployments package the current working tree using a runtime file allowlist.
Each release records its Git HEAD and dirty state and has a content hash. A
failed startup health check returns to the previous code release. It does not
undo database migrations; those require a deliberate restore from backup.

The provisioner has no destroy command. Persistent data recovery is separate
from provisioning, and a restore check decrypts into isolated scratch storage
without starting either application or contacting its providers.
