#!/usr/bin/env python3
"""Build the pinned Whois helper and fetch Caddy with its Cloudflare module."""
import hashlib
import json
import os
import subprocess
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / '.scratch/custom-domains'
BIN = WORK / 'bin'
GO = 'go1.27.1'
CADDY = 'v2.11.4'
CLOUDFLARE = 'v0.2.4'
TAILSCALE = 'v1.102.4'


def download(url, path):
    urllib.request.urlretrieve(url, path)


def main():
    BIN.mkdir(parents=True, exist_ok=True)
    caddy = BIN / 'caddy'
    if not caddy.exists():
        download(f'https://caddyserver.com/api/download?os=linux&arch=amd64&version={CADDY}'
                 f'&p=github.com/caddy-dns/cloudflare@{CLOUDFLARE}', caddy)
        caddy.chmod(0o755)
    version = subprocess.check_output([caddy, 'version'], text=True)
    modules = subprocess.check_output([caddy, 'list-modules', '--versions'], text=True)
    if not version.startswith(CADDY + ' ') or f'dns.providers.cloudflare {CLOUDFLARE}' not in modules:
        raise RuntimeError('Unexpected Caddy build; remove the scratch binary and retry.')
    go = WORK / 'go/bin/go'
    if not go.exists():
        with urllib.request.urlopen('https://go.dev/dl/?mode=json&include=all', timeout=30) as response:
            versions = json.load(response)
        release = next(v for v in versions if v['version'] == GO)
        archive = next(f for f in release['files'] if f['filename'] == f'{GO}.linux-amd64.tar.gz')
        path = WORK / archive['filename']
        download('https://go.dev/dl/' + archive['filename'], path)
        if hashlib.sha256(path.read_bytes()).hexdigest() != archive['sha256']:
            raise RuntimeError('Go archive checksum mismatch.')
        with tarfile.open(path) as tar:
            tar.extractall(WORK, filter='data')
    if GO not in subprocess.check_output([go, 'version'], text=True):
        raise RuntimeError('Unexpected Go toolchain in scratch directory.')
    env = {**os.environ, 'GOBIN': str(BIN), 'GOPATH': str(WORK / 'gopath'),
           'GOCACHE': str(WORK / 'gocache'), 'GOMAXPROCS': '2', 'CGO_ENABLED': '0'}
    subprocess.run([go, 'install', f'tailscale.com/cmd/nginx-auth@{TAILSCALE}'], env=env, check=True)
    print(f'Proxy binaries ready: Caddy {CADDY}, Cloudflare {CLOUDFLARE}, Tailscale auth {TAILSCALE}')


if __name__ == '__main__':
    main()
