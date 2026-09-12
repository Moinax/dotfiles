#!/usr/bin/env python3
"""Provision and deploy the private Finance/Daylight host. No destructive host command."""
import argparse
import hashlib
import io
import json
import os
import shlex
import shutil
import sqlite3
import subprocess
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRATCH = REPO / '.scratch' / 'apps-host'
NAME = 'apps-host'
ROOT = '/opt/personal-apps'
APPS = ('finance', 'daylight')
SSH = ['ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=10']
BACKUPS = Path.home() / 'Backups' / NAME
BACKUP_CONFIG = Path.home() / '.config' / NAME
COMMANDS = {
    'create': 'Create the dedicated droplet with daily DigitalOcean backups',
    'setup': 'Install or repair the remote runtime and service definitions',
    'join': 'Print the Tailscale enrollment link',
    'configure': 'Configure private HTTPS and the authorized owner',
    'prepare-domains': 'Prepare custom HTTPS on staging ports and verify provider callbacks',
    'activate-domains': 'Activate private app domains after public policy links have been updated',
    'firewall': 'Close public ingress after verifying private SSH',
    'deploy': 'Build and deploy finance, daylight, or both',
    'migrate': 'Import local data once and disable local services',
    'configure-backup': 'Install public backup recipients; keep private keys local',
    'backup': 'Create an encrypted archive and fetch it to the desktop',
    'pull': 'Fetch existing encrypted archives',
    'install-pull-timer': 'Fetch archives hourly when the desktop is online',
    'install-launchers': 'Point desktop shortcuts at the private host',
    'restore-check': 'Verify the newest archive in isolated scratch storage',
    'status': 'Check services, routing, resources, and the backup timer',
    'help': 'Show this help message',
}


def run(args, *, capture=False, **kwargs):
    if capture:
        kwargs['stdout'] = subprocess.PIPE
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def output(args):
    return run(args, capture=True).stdout.decode().strip()


def droplets():
    return json.loads(output(['doctl', 'compute', 'droplet', 'list', '--output', 'json']))


def droplet():
    found = [d for d in droplets() if d['name'] == NAME]
    if len(found) != 1:
        raise RuntimeError('Expected exactly one apps-host droplet; run create first.')
    return found[0]


def public_ip(host):
    return next(n['ip_address'] for n in host['networks']['v4'] if n['type'] == 'public')


def tailnet():
    return json.loads(output(['tailscale', 'status', '--json']))


def target():
    # Prefer the private address; the public path exists only during bootstrap.
    for peer in tailnet().get('Peer', {}).values():
        if peer['HostName'] == NAME and peer.get('Online'):
            return 'root@' + peer['TailscaleIPs'][0]
    return 'root@' + public_ip(droplet())


def remote(host, *args, **kwargs):
    return run([*SSH, host, shlex.join(str(a) for a in args)], **kwargs)


def send(host, source, destination):
    run(['scp', '-q', '-o', 'BatchMode=yes', str(source), f'{host}:{destination}'])


def create():
    if any(d['name'] == NAME for d in droplets()):
        print('apps-host already exists; no new droplet created.')
        return
    keys = json.loads(output(['doctl', 'compute', 'ssh-key', 'list', '--output', 'json']))
    key = next(k for k in keys if k['name'] == 'moinax-desktop')
    config = {'ssh_pwauth': False, 'disable_root': False,
              'ssh_authorized_keys': [(Path.home() / '.ssh/id_ed25519.pub').read_text().strip()],
              'write_files': [{'path': '/etc/ssh/sshd_config.d/20-apps-host.conf',
                               'content': 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin prohibit-password\n'}]}
    userdata = SCRATCH / 'cloud-init.yaml'
    userdata.write_text('#cloud-config\n' + json.dumps(config))
    run(['doctl', 'compute', 'droplet', 'create', NAME, '--region', 'ams3', '--size', 's-1vcpu-2gb',
         '--image', 'ubuntu-24-04-x64', '--ssh-keys', key['id'], '--user-data-file', userdata,
         '--enable-backups', '--backup-policy-plan', 'daily', '--enable-monitoring', '--wait',
         '--format', 'ID,Name,PublicIPv4,Status'])


def setup():
    host = target()
    remote(host, 'install', '-d', '-m', '700', ROOT + '/admin')
    for name in ('remote.sh', 'backup.sh', 'proxy.sh', 'Caddyfile', 'apps-proxy.service', 'apps-proxy-auth.service'):
        send(host, REPO / 'tools/apps-host' / name, ROOT + '/admin/' + name)
    remote(host, 'bash', ROOT + '/admin/remote.sh', 'setup')
    remote(host, 'bash', '-c', 'if test -f /etc/personal-apps/proxy.env; then bash /opt/personal-apps/admin/proxy.sh prepare; fi')
    configure_backup()


def configure_backup():
    BACKUP_CONFIG.mkdir(parents=True, exist_ok=True, mode=0o700)
    identity = BACKUP_CONFIG / 'backup.agekey'
    if not identity.exists():
        run(['age-keygen', '-o', identity])
    identity.chmod(0o600)
    recipient = output(['age-keygen', '-y', identity])
    recipients = BACKUP_CONFIG / 'backup-recipients.txt'
    recipients.write_text(recipient + '\n' + (Path.home() / '.ssh/id_ed25519.pub').read_text())
    send(target(), recipients, '/etc/personal-apps/backup-recipient.pub')


def join():
    remote(target(), 'tailscale', 'up', '--hostname', NAME, '--timeout=30s')


def configure():
    state = tailnet()
    owner = state['User'][str(state['Self']['UserID'])]['LoginName']
    remote(target(), 'bash', ROOT + '/admin/remote.sh', 'configure', owner)


def prepare_domains():
    credential = (BACKUP_CONFIG / 'cloudflare-api-token').read_text().strip()
    if not credential or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-' for c in credential):
        raise RuntimeError('Expected a Cloudflare API token in the local apps-host configuration.')
    run(['python3', REPO / 'tools/apps-host/build-proxy.py'])
    host = target()
    remote(host, 'install', '-d', '-m', '700', ROOT + '/admin')
    for name in ('remote.sh', 'backup.sh', 'proxy.sh', 'Caddyfile', 'apps-proxy.service', 'apps-proxy-auth.service', 'check-domains.mjs'):
        send(host, REPO / 'tools/apps-host' / name, ROOT + '/admin/' + name)
    for name in ('caddy', 'nginx-auth'):
        send(host, REPO / '.scratch/custom-domains/bin' / name, ROOT + '/admin/' + name)
    # The secret travels over SSH stdin, never a command argument or a log line.
    remote(host, 'bash', '-c', 'umask 077; cat > /etc/personal-apps/cloudflare.env',
           input=('CLOUDFLARE_API_TOKEN=' + credential + '\n').encode())
    remote(host, 'node', ROOT + '/admin/check-domains.mjs')
    remote(host, 'bash', ROOT + '/admin/proxy.sh', 'prepare')
    remote(host, 'install', '-m', '755', ROOT + '/admin/backup.sh', '/usr/local/sbin/personal-apps-backup')


def domain_records(ip, *, apply=True):
    """Add only explicit private A records; never change the public wildcard."""
    credential = (BACKUP_CONFIG / 'cloudflare-api-token').read_text().strip()

    def request(path, data=None):
        req = urllib.request.Request('https://api.cloudflare.com/client/v4' + path,
            data=None if data is None else json.dumps(data).encode(),
            headers={'Authorization': 'Bearer ' + credential, 'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=30) as response:
            result = json.load(response)
        if not result.get('success'):
            raise RuntimeError('Cloudflare rejected the DNS operation.')
        return result['result']

    zones = request('/zones?name=moinax.com')
    if len(zones) != 1:
        raise RuntimeError('Expected exactly one moinax.com zone.')
    base = '/zones/' + zones[0]['id'] + '/dns_records'
    missing = []
    # Check BOTH names before any mutation, so a conflict cannot leave one changed.
    for app in APPS:
        name = app + '.moinax.com'
        existing = request(base + '?' + urllib.parse.urlencode({'name': name}))
        if existing:
            if len(existing) != 1 or any(existing[0].get(k) != v for k, v in
                    {'type': 'A', 'content': ip, 'proxied': False}.items()):
                raise RuntimeError(f'{name} has conflicting DNS records; inspect them before changing DNS.')
        else:
            missing.append(name)
    for name in missing if apply else []:
        request(base, {'type': 'A', 'name': name, 'content': ip, 'proxied': False, 'ttl': 120})
        print(f'{name}: private DNS record created.')


def activate_domains():
    host = target()
    remote(host, 'node', ROOT + '/admin/check-domains.mjs')
    peer = next(p for p in tailnet()['Peer'].values() if p['HostName'] == NAME and p.get('Online'))
    ip = next(ip for ip in peer['TailscaleIPs'] if ':' not in ip)
    domain_records(ip, apply=False)
    for path in ('/privacy', '/terms'):
        run(['curl', '--fail', '--silent', '--show-error', '--max-time', '20', '--output', '/dev/null',
             'https://finance-info.moinax.com' + path])
    backup()
    previous = remote(host, 'bash', '-c', "grep -qx 'APPS_HTTPS_PORT=443' /etc/personal-apps/proxy.env && echo active || echo staged", capture=True).stdout.strip()
    remote(host, 'bash', ROOT + '/admin/proxy.sh', 'activate')
    try:
        for app in APPS:
            domain = app + '.moinax.com'
            run(['curl', '--fail', '--silent', '--show-error', '--max-time', '20', '--output', '/dev/null',
                 '--resolve', f'{domain}:443:{ip}', f'https://{domain}/'])
    except BaseException:
        if previous == b'staged':
            remote(host, 'bash', ROOT + '/admin/proxy.sh', 'rollback')
        raise
    domain_records(ip)
    install_launchers()


def firewall():
    host = droplet()
    peer = next(p for p in tailnet().get('Peer', {}).values() if p['HostName'] == NAME and p.get('Online'))
    # Prove a NEW SSH connection over the tailnet before closing public SSH.
    remote('root@' + peer['TailscaleIPs'][0], 'true')
    name = NAME + '-deny-all'
    firewalls = json.loads(output(['doctl', 'compute', 'firewall', 'list', '--output', 'json']))
    existing = next((f for f in firewalls if f['name'] == name), None)
    if existing:
        if existing['inbound_rules']:
            raise RuntimeError('Existing firewall has inbound rules; inspect it before continuing.')
        run(['doctl', 'compute', 'firewall', 'add-droplets', existing['id'], '--droplet-ids', host['id']])
    else:
        run(['doctl', 'compute', 'firewall', 'create', '--name', name, '--droplet-ids', host['id'],
             '--outbound-rules', 'protocol:tcp,ports:all,address:0.0.0.0/0,address:::/0 protocol:udp,ports:all,address:0.0.0.0/0,address:::/0 protocol:icmp,address:0.0.0.0/0,address:::/0',
             '--format', 'Name,Status'])


def source_dir(app):
    return Path.home() / 'Projects/labs' / app


def package(app):
    source = source_dir(app)
    command = ['pnpm', 'run', 'build']
    run(command, cwd=source)
    archive = SCRATCH / f'{app}.tar.gz'
    # An explicit runtime allowlist includes working-tree fixes without credentials or local data.
    names = ['package.json', 'dist', 'server']
    names += ['pnpm-lock.yaml']
    if app == 'finance':
        names += ['shared']
    manifest = {'app': app, 'git_head': output(['git', '-C', source, 'rev-parse', 'HEAD']),
                'dirty': bool(output(['git', '-C', source, 'status', '--porcelain'])),
                'created_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
    with tarfile.open(archive, 'w:gz') as tar:
        for name in names:
            tar.add(source / name, arcname=name,
                    filter=lambda info: None if info.name.endswith('.test.ts') else info)
        data = json.dumps(manifest, indent=2).encode()
        info = tarfile.TarInfo('release-manifest.json')
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))
    release = hashlib.sha256(archive.read_bytes()).hexdigest()[:16]
    return archive, release


def deploy(app):
    archive, release = package(app)
    host = target()
    directory = f'{ROOT}/{app}/releases/{release}'
    remote(host, 'install', '-d', directory)
    send(host, archive, directory + '/source.tar.gz')
    remote(host, 'bash', ROOT + '/admin/remote.sh', 'deploy', app, release)
    print(f'{app}: {release}')


def migrate():
    host = target()
    # Refuse a second import rather than overwrite newer production data.
    remote(host, 'bash', '-c', 'test ! -e /var/lib/finance/.migrated && test ! -e /var/lib/daylight/.migrated')
    remote(host, 'bash', '-c', 'test -e /opt/personal-apps/finance/current/server/index.ts && test -e /opt/personal-apps/daylight/current/server/index.mjs && test -e /etc/personal-apps/finance.env && test -e /etc/personal-apps/daylight.env')
    run(['systemctl', '--user', 'stop', *[a + '.service' for a in APPS]])
    # Keep the source untouched; stop refresh-token rotation before copying.
    try:
        with tempfile.TemporaryDirectory(dir=SCRATCH, prefix='migration-') as work:
            work = Path(work)
            os.chmod(work, 0o700)
            finance = source_dir('finance')
            # Node parses its own env syntax; only emit the fields needed for migration into memory.
            env = json.loads(output(['node', '--env-file=' + str(finance / '.env'), '-e',
                                    'console.log(JSON.stringify({app:process.env.EB_APP_ID,key:process.env.EB_PRIVATE_KEY_PATH,db:process.env.FINANCE_DB}))']))
            if not env.get('app') or not env.get('key'):
                raise RuntimeError('Finance bank credentials are missing.')
            db_path = Path(env.get('db') or finance / 'data/finance.sqlite')
            if not db_path.is_absolute():
                db_path = finance / db_path
            with sqlite3.connect(f'file:{db_path}?mode=ro', uri=True) as db, sqlite3.connect(work / 'finance.sqlite') as dest:
                db.backup(dest)
            key = Path(env['key'])
            if not key.is_absolute():
                key = finance / key
            shutil.copyfile(key, work / 'enablebanking.pem')
            (work / 'finance-secret.env').write_text('EB_APP_ID=' + env['app'] + '\n')
            daylight = Path.home() / '.local/share/daylight'
            for name in ('daylight.enc', 'master.key'):
                shutil.copyfile(daylight / name, work / name)
            for file in work.iterdir():
                file.chmod(0o600)
            remote(host, 'install', '-d', '-m', '700', ROOT + '/migration')
            for file in work.iterdir():
                send(host, file, ROOT + '/migration/' + file.name)
            script = '''set -euo pipefail
systemctl stop finance daylight
install -m 600 -o finance -g finance /opt/personal-apps/migration/finance.sqlite /var/lib/finance/finance.sqlite
install -m 600 -o finance -g finance /opt/personal-apps/migration/enablebanking.pem /var/lib/finance/enablebanking.pem
for file in daylight.enc master.key; do install -m 600 -o daylight -g daylight /opt/personal-apps/migration/$file /var/lib/daylight/$file; done
sed -i '/^EB_APP_ID=/d' /etc/personal-apps/finance.env
cat /opt/personal-apps/migration/finance-secret.env >> /etc/personal-apps/finance.env
rm -rf /opt/personal-apps/migration
touch /var/lib/finance/.migrated /var/lib/daylight/.migrated
systemctl enable --now finance daylight
'''
            remote(host, 'bash', '-s', input=script.encode())
    except BaseException:
        # Do not restart local token refresh if the remote copy may already be running.
        print('Migration interrupted. Local services remain stopped; inspect remote state before restarting them.')
        raise
    run(['systemctl', '--user', 'disable', *[a + '.service' for a in APPS]])
    print('Data migrated. Local services disabled to prevent divergent data and refresh-token races.')


def pull():
    BACKUPS.mkdir(parents=True, exist_ok=True, mode=0o700)
    run(['rsync', '-a', '--chmod=F600,D700', '-e', shlex.join(SSH),
         '--include=*.tar.gz.age', '--exclude=*', target() + ':/var/lib/apps-backup/', str(BACKUPS) + '/'])
    files = sorted(BACKUPS.glob('*.tar.gz.age'))
    for file in files[:-30]:
        file.unlink()
    print(f'{len(list(BACKUPS.glob("*.tar.gz.age")))} encrypted backups in {BACKUPS}')


def backup():
    remote(target(), '/usr/local/sbin/personal-apps-backup')
    pull()


def install_pull_timer():
    directory = Path.home() / '.config/systemd/user'
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'apps-host-backup-pull.service').write_text(f'''[Unit]
Description=Fetch encrypted private application backups
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 {REPO}/tools/apps-host.py pull
UMask=0077
''')
    (directory / 'apps-host-backup-pull.timer').write_text('''[Unit]
Description=Fetch private application backups when the desktop is online
[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
[Install]
WantedBy=timers.target
''')
    run(['systemctl', '--user', 'daemon-reload'])
    run(['systemctl', '--user', 'enable', '--now', 'apps-host-backup-pull.timer'])


def install_launchers():
    script = """import json
from pathlib import Path
origins = {}
for app, key in [('finance', 'SELF_URL'), ('daylight', 'DAYLIGHT_ORIGIN')]:
    values = dict(line.split('=', 1) for line in (Path('/etc/personal-apps') / (app + '.env')).read_text().splitlines() if '=' in line)
    origins[app] = values[key]
print(json.dumps(origins))
"""
    origins = json.loads(remote(target(), 'python3', '-c', script, capture=True).stdout)
    directory = Path.home() / '.local/share/applications'
    directory.mkdir(parents=True, exist_ok=True)
    for app in APPS:
        address = origins[app]
        parsed = urllib.parse.urlsplit(address)
        if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.path or parsed.query or parsed.fragment or any(c.isspace() or c in '%\\"' for c in address):
            raise RuntimeError('Invalid production origin for ' + app)
        icon = source_dir(app) / ('public/logo.svg' if app == 'finance' else 'public/favicon.svg')
        (directory / f'{app}.desktop').write_text(f'''[Desktop Entry]
Type=Application
Name={app.title()}
Comment=Private application on Tailscale
Exec=xdg-open {address}
Icon={icon}
Terminal=false
Categories=Office;
StartupNotify=false
''')
    if shutil.which('update-desktop-database'):
        run(['update-desktop-database', directory])


def restore_check():
    archive = max(BACKUPS.glob('*.tar.gz.age'))
    with tempfile.TemporaryDirectory(dir=SCRATCH, prefix='restore-') as work:
        work = Path(work)
        os.chmod(work, 0o700)
        tarpath = work / 'backup.tar.gz'
        with tarpath.open('wb') as dest:
            run(['age', '-d', '-i', BACKUP_CONFIG / 'backup.agekey', archive], stdout=dest)
        with tarfile.open(tarpath) as tar:
            tar.extractall(work, filter='data')
        with sqlite3.connect(work / 'data/finance/finance.sqlite') as db:
            if db.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
                raise RuntimeError('Finance SQLite integrity check failed.')
        # Import only the store; no server, provider calls or token refresh.
        run(['node', '--input-type=module', '-e',
             'const {Store}=await import(process.argv[1]); const s=new Store(process.argv[2]); if(s.state.version!==1) process.exit(1);',
             str(source_dir('daylight') / 'server/store.mjs'), str(work / 'data/daylight')])
        for app in APPS:
            if not (work / f'config/{app}.env').is_file():
                raise RuntimeError(f'Missing {app} configuration in backup.')
            with tarfile.open(work / f'releases/{app}.tar.gz') as tar:
                tar.getmember('package.json')
                tar.getmember('release-manifest.json')
        if not (work / 'data/finance/enablebanking.pem').is_file():
            raise RuntimeError('Missing banking private key in backup.')
        print('Restore check passed: Finance integrity, Daylight decryption, configuration and application archives.')


def status():
    host = droplet()
    print(json.dumps({k: host.get(k) for k in ('name', 'size_slug', 'status', 'features')}, indent=2))
    remote(target(), 'bash', '-c', 'systemctl is-active finance daylight tailscaled; if test -f /etc/personal-apps/proxy.env; then systemctl is-active apps-proxy apps-proxy-auth; fi; tailscale serve status; systemctl list-timers personal-apps-backup.timer --no-pager; free -h; df -h /')


def main():
    parser = argparse.ArgumentParser(prog='dots hosting', description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='Commands:\n' + '\n'.join(f'  {name:<20} {description}' for name, description in COMMANDS.items()))
    parser.add_argument('command', choices=COMMANDS)
    parser.add_argument('app', nargs='?', choices=APPS)
    args = parser.parse_args()
    if args.app and args.command != 'deploy':
        parser.error('Only deploy accepts an application argument.')
    SCRATCH.mkdir(parents=True, exist_ok=True, mode=0o700)
    if args.command == 'help':
        parser.print_help()
    elif args.command == 'deploy':
        for app in [args.app] if args.app else APPS:
            deploy(app)
    else:
        globals()[args.command.replace('-', '_')]()


if __name__ == '__main__':
    main()
