"""Exercise destructive-boundary guards without any cloud or SSH operations."""
import importlib.util
import io
import json
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('apps_host', ROOT / 'tools/apps-host.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class AppsHostTests(unittest.TestCase):
    def test_domain_conflict_is_found_before_either_record_changes(self):
        results = [[{'id': 'zone'}], [], [{'type': 'CNAME', 'content': 'public.example', 'proxied': True}]]
        replies = [io.StringIO(json.dumps({'success': True, 'result': r})) for r in results]
        with patch.object(Path, 'read_text', return_value='test-token'), \
             patch.object(host.urllib.request, 'urlopen', side_effect=replies) as api:
            with self.assertRaisesRegex(RuntimeError, 'conflicting DNS'):
                host.domain_records('100.64.0.5')
            self.assertTrue(all(call.args[0].get_method() == 'GET' for call in api.call_args_list))

    def test_domains_are_explicit_dns_only_records(self):
        results = [[{'id': 'zone'}], [], [], {}, {}]
        replies = [io.StringIO(json.dumps({'success': True, 'result': r})) for r in results]
        with patch.object(Path, 'read_text', return_value='test-token'), \
             patch.object(host.urllib.request, 'urlopen', side_effect=replies) as api:
            host.domain_records('100.64.0.5')
        writes = [json.loads(call.args[0].data) for call in api.call_args_list if call.args[0].data]
        self.assertEqual(writes, [{'type': 'A', 'name': app + '.moinax.com', 'content': '100.64.0.5',
                                  'proxied': False, 'ttl': 120} for app in host.APPS])

    def test_domain_preflight_never_writes_dns(self):
        replies = [io.StringIO(json.dumps({'success': True, 'result': r})) for r in [[{'id': 'zone'}], [], []]]
        with patch.object(Path, 'read_text', return_value='test-token'), \
             patch.object(host.urllib.request, 'urlopen', side_effect=replies) as api:
            host.domain_records('100.64.0.5', apply=False)
            self.assertTrue(all(call.args[0].get_method() == 'GET' for call in api.call_args_list))

    def test_target_prefers_tailnet_without_contacting_cloud(self):
        with patch.object(host, 'tailnet', return_value={'Peer': {'p': {
            'HostName': 'apps-host', 'Online': True, 'TailscaleIPs': ['100.64.0.5'],
        }}}), patch.object(host, 'droplet') as cloud:
            self.assertEqual(host.target(), 'root@100.64.0.5')
            cloud.assert_not_called()

    def test_create_does_not_duplicate_existing_host(self):
        with patch.object(host, 'droplets', return_value=[{'name': 'apps-host'}]), patch.object(host, 'run') as run:
            host.create()
            run.assert_not_called()

    def test_firewall_requires_working_private_ssh_before_mutation(self):
        with patch.object(host, 'droplet', return_value={'id': 123}), \
             patch.object(host, 'tailnet', return_value={'Peer': {}}), \
             patch.object(host, 'run') as run:
            with self.assertRaises(StopIteration):
                host.firewall()
            run.assert_not_called()

    def test_existing_public_firewall_is_not_accepted_as_private(self):
        with patch.object(host, 'droplet', return_value={'id': 123}), \
             patch.object(host, 'tailnet', return_value={'Peer': {'p': {
                 'HostName': 'apps-host', 'Online': True, 'TailscaleIPs': ['100.64.0.5']}}}), \
             patch.object(host, 'remote'), patch.object(host, 'output', return_value=json.dumps([
                 {'name': 'apps-host-deny-all', 'id': 'fw', 'inbound_rules': [{'protocol': 'tcp'}]}])), \
             patch.object(host, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'inbound rules'):
                host.firewall()
            run.assert_not_called()

    def test_runtime_archive_excludes_local_data_and_credentials(self):
        scratch = ROOT / '.scratch'
        scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as work:
            source = Path(work) / 'source'
            source.mkdir()
            for name in ['package.json', 'pnpm-lock.yaml', 'server/index.ts', 'server/access.ts',
                         'server/access.test.ts', 'shared/types.ts', 'dist/index.html',
                         '.env', 'enablebanking.pem', 'data/finance.sqlite', 'site/index.html']:
                p = source / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text('fixture')
            with patch.object(host, 'source_dir', return_value=source), \
                 patch.object(host, 'SCRATCH', Path(work)), \
                 patch.object(host, 'run'), patch.object(host, 'output', side_effect=['abcdef', ' M server/access.ts']):
                archive, release = host.package('finance')
            self.assertEqual(len(release), 16)
            with tarfile.open(archive) as tar:
                names = tar.getnames()
                for forbidden in ['.env', 'enablebanking.pem', 'data/finance.sqlite', 'site/index.html', 'server/access.test.ts']:
                    self.assertNotIn(forbidden, names)
                self.assertIn('server/access.ts', names)
                self.assertTrue(json.load(tar.extractfile('release-manifest.json'))['dirty'])


if __name__ == '__main__':
    unittest.main()
