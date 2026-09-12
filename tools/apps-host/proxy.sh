#!/usr/bin/env bash
# Run as root on apps-host. Prepare on unused ports before activating domains.
set -euo pipefail
[[ $EUID == 0 && $(hostname) == apps-host ]] || { echo 'Expected root on apps-host' >&2; exit 1; }
ADMIN=/opt/personal-apps/admin
CONFIG=/etc/personal-apps

prepare() {
    [[ -s $CONFIG/cloudflare.env ]]
    id caddy >/dev/null 2>&1 || useradd --system --home-dir /var/lib/apps-proxy --shell /usr/sbin/nologin caddy
    install -d -m 750 -o root -g caddy /etc/apps-proxy
    install -m 644 "$ADMIN/Caddyfile" /etc/apps-proxy/Caddyfile
    install -m 755 "$ADMIN/caddy" /usr/local/bin/apps-caddy
    install -m 755 "$ADMIN/nginx-auth" /usr/local/bin/apps-tailscale-auth
    install -m 644 "$ADMIN/apps-proxy.service" "$ADMIN/apps-proxy-auth.service" /etc/systemd/system/
    python3 - <<'PY'
import json, subprocess
from pathlib import Path
state = json.loads(subprocess.check_output(['tailscale', 'status', '--json']))['Self']
path = Path('/etc/personal-apps/proxy.env')
ports = {'APPS_HTTPS_PORT': '10443', 'APPS_LEGACY_PORT': '18443', 'APPS_HTTP_PORT': '10080'}
if path.exists():
    previous = dict(line.split('=', 1) for line in path.read_text().splitlines() if '=' in line)
    ports.update({k: previous[k] for k in ports if k in previous})
    if ports['APPS_HTTPS_PORT'] == '443':
        ports['APPS_HTTP_PORT'] = '80'
values = {'APPS_IPV4': next(ip for ip in state['TailscaleIPs'] if ':' not in ip),
          'APPS_IPV6': next(ip for ip in state['TailscaleIPs'] if ':' in ip),
          'APPS_TAILSCALE_DNS': state['DNSName'].rstrip('.'), **ports}
path.touch(mode=0o600)
path.write_text(''.join(f'{k}={v}\n' for k,v in values.items()))
PY
    # Grant certificate retrieval only, without granting Tailscale operator rights.
    install -d /etc/systemd/system/tailscaled.service.d
    local dropin=/etc/systemd/system/tailscaled.service.d/apps-proxy.conf
    if [[ ! -f $dropin ]] || ! grep -qx 'Environment=TS_PERMIT_CERT_UID=caddy' "$dropin"; then
        printf '[Service]\nEnvironment=TS_PERMIT_CERT_UID=caddy\n' > "$dropin"
        systemctl daemon-reload
        systemctl restart tailscaled
    fi
    systemctl daemon-reload
    systemctl enable --now apps-proxy-auth
    systemctl enable apps-proxy
    systemctl restart apps-proxy
}

restore_previous() {
    systemctl stop apps-proxy
    cp "$CONFIG/domain-rollback/finance.env" "$CONFIG/finance.env"
    cp "$CONFIG/domain-rollback/daylight.env" "$CONFIG/daylight.env"
    cp "$CONFIG/domain-rollback/proxy.env" "$CONFIG/proxy.env"
    tailscale serve --bg --yes --https=443 http://127.0.0.1:3001
    tailscale serve --bg --yes --https=8443 http://127.0.0.1:4280
    systemctl restart finance daylight
    systemctl start apps-proxy
}

activate() {
    if grep -qx 'APPS_HTTPS_PORT=443' "$CONFIG/proxy.env"; then
        echo 'Custom domains already active. Use configure to reconcile them.'
        return
    fi
    systemctl is-active --quiet apps-proxy
    # A domain change cannot carry browser-bound OAuth cookies across hosts.
    local pending
    pending=$(sqlite3 /var/lib/finance/finance.sqlite "SELECT COUNT(*) FROM pending_auth WHERE datetime(created_at) > datetime('now', '-1 hour');")
    [[ $pending == 0 ]] || { echo 'Finish or let the pending bank authorization expire before activating domains.' >&2; exit 1; }
    install -d -m 700 "$CONFIG/domain-rollback"
    cp "$CONFIG/finance.env" "$CONFIG/daylight.env" "$CONFIG/proxy.env" "$CONFIG/domain-rollback/"
    local proxy_exit_status
    trap 'proxy_exit_status=$?; trap - ERR; restore_previous; exit "$proxy_exit_status"' ERR
    set -E
    python3 - <<'PY'
from pathlib import Path
updates = {
    'finance.env': {'SELF_URL': 'https://finance.moinax.com', 'EB_REDIRECT_URL': 'https://finance.moinax.com/api/callback'},
    'daylight.env': {'DAYLIGHT_ORIGIN': 'https://daylight.moinax.com'},
    'proxy.env': {'APPS_HTTPS_PORT': '443', 'APPS_LEGACY_PORT': '8443', 'APPS_HTTP_PORT': '80'},
}
for name, values in updates.items():
    path = Path('/etc/personal-apps') / name
    kept = [line for line in path.read_text().splitlines() if line.split('=', 1)[0] not in values]
    path.write_text('\n'.join(kept + [f'{k}={v}' for k,v in values.items()]) + '\n')
PY
    tailscale serve --https=443 off
    tailscale serve --https=8443 off
    systemctl restart finance daylight apps-proxy
    local app port domain owner healthy
    for app in finance daylight; do
        port=3001; [[ $app == finance ]] || port=4280
        domain="$app.moinax.com"
        owner=$(sed -n 's/^TAILSCALE_USER=//p' "$CONFIG/$app.env")
        healthy=false
        for _ in {1..20}; do
            if curl --fail --silent --output /dev/null -H "Host: $domain" -H "Tailscale-User-Login: $owner" "http://127.0.0.1:$port/"; then
                healthy=true; break
            fi
            sleep 1
        done
        "$healthy"
    done
    systemctl is-active --quiet apps-proxy
    trap - ERR
    echo 'Custom domains active; original Tailscale URLs redirect to them.'
}

case "${1:-}" in
    prepare) prepare ;;
    activate) activate ;;
    rollback) restore_previous ;;
    *) echo 'Expected prepare, activate or rollback' >&2; exit 1 ;;
esac
