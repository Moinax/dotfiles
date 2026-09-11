#!/usr/bin/env bash
# Runs as root on the dedicated Ubuntu application host, never on the desktop.
set -euo pipefail
[[ $EUID == 0 && $(hostname) == apps-host ]] || { echo 'Expected root on apps-host' >&2; exit 1; }
ROOT=/opt/personal-apps

setup() {
    cloud-init status --wait >/dev/null
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl xz-utils age sqlite3 rsync jq unattended-upgrades
    install -d -m 700 /etc/personal-apps /var/lib/apps-backup
    install -d "$ROOT"
    if ! command -v node >/dev/null || [[ $(node -p 'process.versions.node.split(".")[0]') != 24 ]]; then
        local stage version
        stage=$(mktemp -d "$ROOT/node.XXXXXX")
        curl -fsSL https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt -o "$stage/SHASUMS256.txt"
        version=$(awk '/linux-x64.tar.xz$/ {print $2; exit}' "$stage/SHASUMS256.txt")
        [[ $version =~ ^node-v24\.[0-9]+\.[0-9]+-linux-x64.tar.xz$ ]]
        curl -fsSL "https://nodejs.org/dist/latest-v24.x/$version" -o "$stage/$version"
        (cd "$stage"; grep " $version$" SHASUMS256.txt | sha256sum --check)
        tar -xJf "$stage/$version" -C /usr/local --strip-components=1
        rm -rf "$stage"
    fi
    command -v pnpm >/dev/null || npm install -g pnpm@10.15.0 --ignore-scripts
    if ! command -v tailscale >/dev/null; then
        curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg
        curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list -o /etc/apt/sources.list.d/tailscale.list
        apt-get update -qq
        apt-get install -y -qq tailscale
    fi
    systemctl enable --now tailscaled
    for app in finance daylight; do
        id "$app" >/dev/null 2>&1 || useradd --system --home-dir "/var/lib/$app" --shell /usr/sbin/nologin "$app"
        install -d -m 700 -o "$app" -g "$app" "/var/lib/$app"
        install -d "$ROOT/$app/releases"
        local entry=server/index.mjs
        [[ $app != finance ]] || entry=server/index.ts
        cat > "/etc/systemd/system/$app.service" <<UNIT
[Unit]
Description=$app private application
After=network-online.target tailscaled.service
Wants=network-online.target
ConditionPathExists=/etc/personal-apps/$app.env
ConditionPathExists=$ROOT/$app/current/$entry

[Service]
Type=simple
User=$app
Group=$app
WorkingDirectory=$ROOT/$app/current
Environment=NODE_ENV=production
EnvironmentFile=/etc/personal-apps/$app.env
ExecStart=/usr/local/bin/node $entry
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
UMask=0077
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=/var/lib/$app

[Install]
WantedBy=multi-user.target
UNIT
    done
    install -m 755 "$ROOT/admin/backup.sh" /usr/local/sbin/personal-apps-backup
    cat > /etc/systemd/system/personal-apps-backup.service <<'UNIT'
[Unit]
Description=Encrypted application data backup
ConditionPathExists=/etc/personal-apps/backup-recipient.pub
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/personal-apps-backup
UMask=0077
UNIT
    cat > /etc/systemd/system/personal-apps-backup.timer <<'UNIT'
[Unit]
Description=Back up private applications daily
[Timer]
OnCalendar=*-*-* 03:15:00 UTC
Persistent=true
RandomizedDelaySec=10m
[Install]
WantedBy=timers.target
UNIT
    systemctl daemon-reload
    systemctl enable --now personal-apps-backup.timer
    echo "Runtime ready: $(node --version)"
}

configure() {
    local owner=$1 dns
    [[ $owner =~ ^[a-zA-Z0-9._+@-]+$ && $owner == *@* ]]
    dns=$(tailscale status --json | jq -er '.Self.DNSName | rtrimstr(".")')
    [[ $dns == apps-host.*.ts.net ]]
    # Keep provider secrets from a previous migration. These entries are not secrets.
    python3 - "$owner" "$dns" <<'PY'
from pathlib import Path
import sys
owner, dns = sys.argv[1:]
settings = {
 'finance': {'PORT':'3001','SELF_URL':f'https://{dns}', 'EB_REDIRECT_URL':f'https://{dns}/api/callback', 'FINANCE_DB':'/var/lib/finance/finance.sqlite', 'EB_PRIVATE_KEY_PATH':'/var/lib/finance/enablebanking.pem', 'TAILSCALE_USER':owner},
 'daylight': {'DAYLIGHT_PORT':'4280','DAYLIGHT_ORIGIN':f'https://{dns}:8443','DAYLIGHT_DATA_DIR':'/var/lib/daylight','TAILSCALE_USER':owner}
}
for app, values in settings.items():
 p = Path(f'/etc/personal-apps/{app}.env')
 kept = [line for line in p.read_text().splitlines() if line.split('=',1)[0] not in values] if p.exists() else []
 p.write_text('\n'.join(kept + [f'{k}={v}' for k,v in values.items()])+'\n')
 p.chmod(0o600)
PY
    tailscale serve --bg --yes --https=443 http://127.0.0.1:3001
    tailscale serve --bg --yes --https=8443 http://127.0.0.1:4280
    systemctl try-restart finance daylight
}

deploy() {
    local app=$1 release=$2 dir old port origin owner code
    [[ $app == finance || $app == daylight ]]
    [[ $release =~ ^[0-9a-f]{16}$ ]]
    dir="$ROOT/$app/releases/$release"
    [[ -f "$dir/source.tar.gz" ]]
    if [[ ! -f $dir/.installed ]]; then
        tar -xzf "$dir/source.tar.gz" -C "$dir"
        chown -R "$app:$app" "$dir"
        if [[ -f $dir/pnpm-lock.yaml ]]; then
            (cd "$dir"; runuser -u "$app" -- /usr/local/bin/pnpm install --prod --frozen-lockfile --ignore-scripts)
        else
            # Recovery compatibility for Daylight archives created before the pnpm migration.
            (cd "$dir"; runuser -u "$app" -- /usr/local/bin/npm ci --omit=dev --ignore-scripts --no-audit --no-fund)
        fi
        touch "$dir/.installed"
        chown -R root:root "$dir"
        chmod -R go-w "$dir"
    fi
    old=$(readlink "$ROOT/$app/current" || true)
    ln -sfn "releases/$release" "$ROOT/$app/current.next"
    mv -Tf "$ROOT/$app/current.next" "$ROOT/$app/current"
    # A first deployment can precede migration. Do not create empty application data.
    [[ -f /etc/personal-apps/$app.env && -f /var/lib/$app/.migrated ]] || return 0
    systemctl enable "$app"
    systemctl restart "$app"
    port=4280
    origin=$(sed -n 's/^DAYLIGHT_ORIGIN=//p' "/etc/personal-apps/$app.env")
    if [[ $app == finance ]]; then
        port=3001
        origin=$(sed -n 's/^SELF_URL=//p' "/etc/personal-apps/$app.env")
    fi
    owner=$(sed -n 's/^TAILSCALE_USER=//p' "/etc/personal-apps/$app.env")
    for _ in {1..20}; do
        code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${origin#https://}" -H "Tailscale-User-Login: $owner" "http://127.0.0.1:$port/" || true)
        if [[ $code == 200 ]]; then echo "$app release $release healthy"; return 0; fi
        sleep 1
    done
    echo "$app failed its health check; restoring previous code" >&2
    if [[ -n $old ]]; then
        ln -sfn "$old" "$ROOT/$app/current.next"
        mv -Tf "$ROOT/$app/current.next" "$ROOT/$app/current"
        systemctl restart "$app"
    else
        systemctl stop "$app"
    fi
    return 1
}

case "${1:-}" in
    setup) setup ;;
    configure) configure "$2" ;;
    deploy) deploy "$2" "$3" ;;
    *) echo 'Expected setup, configure or deploy' >&2; exit 1 ;;
esac
