"""Exercise the actual Caddy config with isolated TLS, Whois, and app fixtures."""
import http.server
import json
import os
import socket
import socketserver
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CADDY = ROOT / '.scratch/custom-domains/bin/caddy'


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.requests.append(dict(self.headers))
        if self.server.is_auth:
            self.send_response(204 if self.server.authorized else 401)
            if self.server.authorized:
                self.send_header('Tailscale-User', 'owner@example.com')
            self.end_headers()
        else:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(json.dumps(dict(self.headers)).encode())


@unittest.skipUnless(CADDY.exists(), 'Run tools/apps-host/build-proxy.py first')
class ProxyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = tempfile.TemporaryDirectory(dir=ROOT / '.scratch', prefix='proxy-test-')
        cls.path = Path(cls.work.name)
        cls.port = free_port()
        cls.auth = socketserver.UnixStreamServer(str(cls.path / 'auth.sock'), Handler)
        cls.auth.is_auth = True
        cls.auth.authorized = True
        cls.auth.requests = []
        cls.backend = http.server.HTTPServer(('127.0.0.1', 0), Handler)
        cls.backend.is_auth = False
        cls.backend.requests = []
        for server in (cls.auth, cls.backend):
            threading.Thread(target=server.serve_forever, daemon=True).start()
        config = (ROOT / 'tools/apps-host/Caddyfile').read_text()
        config = config.replace('admin unix//run/apps-proxy/admin.sock', 'admin off\n\tskip_install_trust')
        config = config.replace('bind {$APPS_IPV4} {$APPS_IPV6}', 'bind 127.0.0.1')
        config = config.replace('tls {\n\t\tdns cloudflare {env.CLOUDFLARE_API_TOKEN}\n\t\tresolvers 1.1.1.1 1.0.0.1\n\t}', 'tls internal')
        config = config.replace('/run/apps-proxy-auth/auth.sock', str(cls.path / 'auth.sock'))
        for port in (3001, 4280):
            config = config.replace(f'127.0.0.1:{port}', f'127.0.0.1:{cls.backend.server_port}')
        # Give the legacy hostname a test certificate too, without consulting tailscaled.
        config = config.replace('bind 127.0.0.1\n\t@navigation', 'bind 127.0.0.1\n\ttls internal\n\t@navigation')
        (cls.path / 'Caddyfile').write_text(config)
        env = {**os.environ, 'APPS_HTTPS_PORT': str(cls.port), 'APPS_LEGACY_PORT': str(free_port()),
               'APPS_HTTP_PORT': str(free_port()),
               'APPS_TAILSCALE_DNS': 'legacy.example.test', 'XDG_DATA_HOME': str(cls.path),
               'XDG_CONFIG_HOME': str(cls.path)}
        cls.log = (cls.path / 'caddy.log').open('w')
        cls.process = subprocess.Popen([CADDY, 'run', '--config', cls.path / 'Caddyfile', '--adapter', 'caddyfile'],
                                       env=env, stdout=cls.log, stderr=cls.log)
        for _ in range(100):
            try:
                with socket.create_connection(('127.0.0.1', cls.port), timeout=.1):
                    ready = subprocess.run(['curl', '--silent', '--insecure', '--noproxy', '*', '--max-time', '1',
                        '--resolve', f'finance.moinax.com:{cls.port}:127.0.0.1',
                        f'https://finance.moinax.com:{cls.port}/'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
                    if ready.returncode == 0:
                        return
                time.sleep(.05)
            except OSError:
                if cls.process.poll() is not None:
                    raise RuntimeError((cls.path / 'caddy.log').read_text())
                time.sleep(.05)
        raise RuntimeError('Test proxy did not start')

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate()
        cls.process.wait(timeout=10)
        cls.log.close()
        for server in (cls.auth, cls.backend):
            server.shutdown()
            server.server_close()
        cls.work.cleanup()

    def request(self, *headers):
        command = ['curl', '--silent', '--show-error', '--insecure', '--noproxy', '*', '--max-time', '5',
                   '--resolve', f'finance.moinax.com:{self.port}:127.0.0.1',
                   '--write-out', '\n%{http_code}', f'https://finance.moinax.com:{self.port}/api/callback?code=fixture']
        for header in headers:
            command += ['--header', header]
        result = subprocess.check_output(command, text=True)
        return result.rsplit('\n', 1)

    def test_identity_is_replaced_and_peer_cannot_be_spoofed(self):
        self.auth.authorized = True
        body, status = self.request('Tailscale-User-Login: attacker@example.com',
            'Tailscale-User-Name: forged', 'Remote-Addr: 203.0.113.10', 'Remote-Port: 7',
            'Origin: https://finance.moinax.com', 'Cookie: fixture=session')
        self.assertEqual(status, '200')
        headers = {k.lower(): v for k,v in json.loads(body).items()}
        self.assertEqual(headers['tailscale-user-login'], 'owner@example.com')
        self.assertNotIn('tailscale-user-name', headers)
        self.assertEqual(headers['origin'], 'https://finance.moinax.com')
        self.assertEqual(headers['host'], f'finance.moinax.com:{self.port}')
        self.assertEqual(headers['cookie'], 'fixture=session')
        peer = {k.lower(): v for k,v in self.auth.requests[-1].items()}
        self.assertEqual(peer['remote-addr'], '127.0.0.1')
        self.assertNotEqual(peer['remote-port'], '7')

    def test_auth_failure_never_reaches_application(self):
        self.auth.authorized = False
        before = len(self.backend.requests)
        _, status = self.request('Tailscale-User-Login: owner@example.com')
        self.assertEqual(status, '401')
        self.assertEqual(len(self.backend.requests), before)


if __name__ == '__main__':
    unittest.main()
