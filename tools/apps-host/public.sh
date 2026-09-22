#!/usr/bin/env bash
# Separate public listener; never changes the private proxy or Tailscale services.
set -euo pipefail
[[ $EUID == 0 && $(hostname) == apps-host ]] || { echo 'Expected root on apps-host' >&2; exit 1; }
ADMIN=/opt/personal-apps/admin
[[ -x /usr/local/bin/apps-caddy && -s /etc/personal-apps/cloudflare.env ]]
for account in twitch-grid apps-public; do
    id "$account" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$account"
done
install -d /opt/personal-apps/twitch-grid/releases
install -d -m 750 -o root -g apps-public /etc/apps-public-proxy
install -m 644 "$ADMIN/PublicCaddyfile" /etc/apps-public-proxy/Caddyfile
install -m 644 "$ADMIN/twitch-grid.service" "$ADMIN/apps-public-proxy.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable twitch-grid apps-public-proxy
# DNS validation obtains the certificate before any DNS cutover or public ingress.
systemctl restart apps-public-proxy
