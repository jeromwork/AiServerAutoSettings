#!/usr/bin/env python3
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('bundle', ROOT / 'build/bundle.py')
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)

class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='remoteagents-build-')
        self.root = Path(self.temp.name)
        self.out = self.root / 'out'
        subprocess.run([str(ROOT/'build/make-bundle.sh'), '20261109.123456-test', str(self.out)], check=True, stdout=subprocess.DEVNULL)
        self.zip = self.out / '20261109.123456-test.zip'

    def tearDown(self):
        self.temp.cleanup()

    def test_allowlist_no_downloaded_binaries(self):
        with zipfile.ZipFile(self.zip) as z:
            names = z.namelist()
            self.assertIn('Start-WindowsControl.ps1', names)
            self.assertIn('disk/Install-RemoteDisk.ps1', names)
            self.assertIn('selftest.ps1', names)
            self.assertFalse(any(n.endswith(('.exe', '.dll', '.key', '.pem')) for n in names))
            self.assertFalse(any(n.startswith(('app/', 'profiles/')) for n in names))
            definition = json.loads(z.read('components.json').decode('utf-8-sig'))
            self.assertTrue(definition['components'][0]['critical'])
            self.assertEqual(definition['binaries'], [])
            for c in definition['components']:
                args = c['args']
                if '-File' in args:
                    path = args[args.index('-File')+1].replace('{bundle}\\', '').replace('\\', '/')
                    self.assertIn(path, names)

    def test_lf_and_ps51_encoding(self):
        with zipfile.ZipFile(self.zip) as z:
            for name in z.namelist():
                data = z.read(name)
                self.assertNotIn(b'\r', data, name)
                if name.endswith('.ps1'):
                    self.assertTrue(data.startswith(b'\xef\xbb\xbf'), name)

    def test_reproducible(self):
        before = self.zip.read_bytes()
        subprocess.run([str(ROOT/'build/make-bundle.sh'), '20261109.123456-test', str(self.out)], check=True, stdout=subprocess.DEVNULL)
        self.assertEqual(before, self.zip.read_bytes())

    def test_publish_cli_hash_size_permissions(self):
        dist = self.root / 'dist with spaces'
        subprocess.run([str(ROOT/'build/publish.sh'), str(self.zip), str(dist)], check=True, stdout=subprocess.DEVNULL)
        m = json.loads((dist/'manifest.json').read_text())
        self.assertEqual(m['version'], '20261109.123456-test')
        self.assertEqual(m['sha256'], hashlib.sha256((dist/m['file']).read_bytes()).hexdigest())
        self.assertEqual(m['size'], (dist/m['file']).stat().st_size)
        self.assertEqual(m['minLauncher'], '1.0.0')
        self.assertEqual(stat.S_IMODE(dist.stat().st_mode), 0o755)
        for f in dist.iterdir():
            self.assertEqual(stat.S_IMODE(f.stat().st_mode), 0o644)
        self.assertFalse(any(p.name.startswith('.') for p in dist.iterdir()))

    def test_immutable_version_and_unchanged_manifest(self):
        dist = self.root / 'dist'
        bundle.publish(self.zip, dist)
        original = (dist/'manifest.json').read_bytes()
        with zipfile.ZipFile(self.zip, 'a') as z:
            z.writestr('changed.txt', 'changed')
        with self.assertRaises(ValueError):
            bundle.publish(self.zip, dist)
        self.assertEqual(original, (dist/'manifest.json').read_bytes())

    def test_crlf_input_at_packaging_boundary(self):
        fixture = self.root / 'fixture'
        (fixture/'build').mkdir(parents=True)
        (fixture/'build/bundle-files.txt').write_bytes(b'build/components.json => components.json\r\nhello.ps1\r\n')
        (fixture/'build/components.json').write_bytes(b'{"components": []}\r\n')
        (fixture/'hello.ps1').write_bytes('Write-Output "Проверка"\r\n'.encode())
        real = bundle.ROOT
        try:
            bundle.ROOT = fixture
            path = bundle.make('1.0.0', self.root/'fixture-out')
            with zipfile.ZipFile(path) as z:
                self.assertEqual(z.read('hello.ps1'), b'\xef\xbb\xbf'+ 'Write-Output "Проверка"\n'.encode())
                self.assertEqual(z.read('components.json'), b'{"components": []}\n')
        finally:
            bundle.ROOT = real

    def test_attach_preserves_embedded_snapshot(self):
        exe = self.root / 'RemoteAgents.exe'
        exe.write_bytes(b'MZ-test-payload')
        output = self.root / 'ota.zip'
        bundle.attach_launcher(self.zip, exe, output)
        with zipfile.ZipFile(self.zip) as original, zipfile.ZipFile(output) as ota:
            for name in original.namelist():
                if name != 'bundle-files.txt':
                    self.assertEqual(original.read(name), ota.read(name))
            self.assertEqual(ota.read('RemoteAgents.exe'), exe.read_bytes())
            self.assertIn('RemoteAgents.exe', ota.read('bundle-files.txt').decode().splitlines())

    def test_two_products_and_release_not_ignored(self):
        vpn = bundle.make('20261109.123456-test', self.root/'vpn', product='RemoteVPN')
        with zipfile.ZipFile(self.zip) as agents, zipfile.ZipFile(vpn) as other:
            a = json.loads(agents.read('components.json').decode('utf-8-sig'))
            v = json.loads(other.read('components.json').decode('utf-8-sig'))
            self.assertEqual([c['name'] for c in a['components']], ['transport','disk','control'])
            self.assertEqual([c['name'] for c in v['components']], ['vpn'])
            self.assertIn('build/Wizard.ps1', other.namelist())
            self.assertIn('disk/Select-Disk.ps1', other.namelist())
            self.assertIn('build/FirstInstall.ps1', agents.namelist())
            self.assertIn('setup-vps-ssh.ps1', agents.namelist())
            self.assertIn('ssh-password-ui.cs', agents.namelist())
        for name in ('RemoteAgents.exe','RemoteVPN.exe','Start.cmd'):
            result = subprocess.run(['git','check-ignore','-q','release/'+name],cwd=ROOT)
            self.assertEqual(result.returncode, 1, name)
        rules = (ROOT/'disk/stignore.txt').read_text()
        self.assertNotIn('release', rules.lower())
        self.assertEqual(len((ROOT/'build/Start.cmd').read_text().splitlines()),3)

    def test_invalid_versions(self):
        for version in ('../escape', '1..2', '1.', 'v1', '1/newline\n'):
            with self.assertRaises(ValueError):
                bundle.safe_version(version)

    def test_declared_files_exist(self):
        with zipfile.ZipFile(self.zip) as z:
            listed = z.read('bundle-files.txt').decode().splitlines()
            self.assertTrue(all(name in z.namelist() for name in listed))

if __name__ == '__main__':
    unittest.main(verbosity=2)
