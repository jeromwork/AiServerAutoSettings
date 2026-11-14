#!/usr/bin/env python3
"""Review regressions with real Syncthing; only recycling is a reversible move fixture."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('disk_stand', ROOT / 'disk/test-disk.py')
stand_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stand_module)
DOTNET = os.environ.get('DOTNET', str(Path.home() / '.dotnet/dotnet'))
DLL = ROOT / 'app/launcher/tests/bin/Release/net10.0/PortableTests.dll'


def wait(predicate, description, seconds=25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            if predicate():
                return
        except (OSError, KeyError, ValueError):
            pass
        time.sleep(.1)
    raise AssertionError('timeout: ' + description)


class SafetyTests(unittest.TestCase):
    def setUp(self):
        self.stand = self.enterContext(stand_module.Stand())
        self.temp = Path(self.enterContext(tempfile.TemporaryDirectory(prefix='disk-safety-')))
        self.server, self.local = self.stand.sides
        for side, other in ((self.server, self.local), (self.local, self.server)):
            self.stand.register(side, other)
        self.home = self.temp / 'RemoteDisk'
        (self.home / 'state').mkdir(parents=True)
        (self.home / 'state/config.xml').symlink_to(self.local['state'] / 'config.xml')
        (self.home / 'server.txt').write_text(self.server['deviceId'] + '\r\n')
        self.disk = self.temp / 'Disk'
        self.disk.mkdir()
        self.source = self.disk / 'Project'
        self.source.mkdir()
        self.remote = self.server['home'] / 'Disk/Project'
        self.recycle = self.temp / 'Recycled'

    def api(self, side, route, method='GET', body=None):
        return self.stand.api(side, route, method, body)

    def folder(self, side, path, kind='sendreceive', share=True, folder_id='Project'):
        peer = self.server if side is self.local else self.local
        config = self.api(side, 'config/defaults/folder')
        config.update(id=folder_id, label=folder_id, path=str(path), type=kind,
                      fsWatcherEnabled=False, rescanIntervalS=3600,
                      devices=[dict(deviceID=peer['deviceId'])] if share else [])
        self.api(side, 'config/folders', 'POST', config)

    def action(self, action, path=None, budget=30000):
        return subprocess.run([str(x) for x in (DOTNET, DLL, '--disk-engine-action', self.home,
            self.disk, action, path or self.source, ROOT / 'disk/stignore.txt', self.recycle, budget)],
            capture_output=True, text=True, timeout=45)

    def inspect(self):
        result = self.action('inspect')
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def paired(self, kind='sendreceive'):
        if kind == 'receiveonly':
            self.remote.mkdir(parents=True)
            (self.remote / 'data.txt').write_text('initial')
        else:
            (self.source / 'data.txt').write_text('initial')
        self.folder(self.local, self.source, kind)
        wait(lambda: 'Project' in self.api(self.server, 'cluster/pending/folders'), 'server offer')
        self.folder(self.server, self.remote)
        wait(lambda: (self.remote / 'data.txt').exists() and (self.source / 'data.txt').read_text() == 'initial', 'initial transfer')
        wait(lambda: self.inspect()['folders'][0]['kind'] == 'Synced', 'initial confirmed sync')

    def test_keep_scans_unindexed_edit_and_waits_for_server(self):
        self.paired()
        (self.source / 'data.txt').write_text('just edited before watcher')
        self.assertEqual(self.api(self.local, 'db/status?folder=Project')['state'], 'idle')
        result = self.action('keep-server')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.remote / 'data.txt').read_text(), 'just edited before watcher')
        self.assertEqual((self.recycle / 'data.txt').read_text(), 'just edited before watcher')

    def test_keep_timeout_retains_data_and_registration(self):
        self.paired()
        self.api(self.local, 'config/options', 'PATCH', dict(maxSendKbps=1, limitBandwidthInLan=True))
        (self.source / 'data.txt').write_bytes(b'fresh edit' * 32768)
        result = self.action('keep-server', budget=500)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('вовремя', result.stderr)
        self.assertTrue((self.source / 'data.txt').exists())
        self.assertFalse(self.recycle.exists())
        self.assertEqual(self.api(self.local, 'config/folders/Project')['path'], str(self.source))

    def test_receiveonly_changes_are_not_synced_and_keep_is_rejected(self):
        self.paired('receiveonly')
        (self.source / 'only-local.txt').write_text('must remain local')
        self.api(self.local, 'db/scan?folder=Project', 'POST')
        wait(lambda: self.api(self.local, 'db/status?folder=Project')['receiveOnlyTotalItems'] > 0, 'receiveonly local change')
        self.assertEqual(self.api(self.local, 'db/status?folder=Project')['needBytes'], 0)
        self.assertEqual(self.api(self.local, 'db/completion?folder=Project&device=' + self.server['deviceId'])['completion'], 100)
        snapshot = self.inspect()
        result = self.action('keep-server')
        self.assertEqual(snapshot['folders'][0]['kind'], 'LocalChanges', snapshot)
        self.assertIn('есть локальные изменения', snapshot['tray'])
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue((self.source / 'only-local.txt').exists())
        self.assertFalse(self.recycle.exists())

    def test_add_promotes_existing_receiveonly_shared_registration(self):
        self.paired('receiveonly')
        (self.source / 'only-local.txt').write_text('upload requested')
        self.api(self.local, 'db/scan?folder=Project', 'POST')
        wait(lambda: self.api(self.local, 'db/status?folder=Project')['receiveOnlyTotalItems'] > 0, 'local edit')
        result = self.action('add')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.api(self.local, 'config/folders/Project')['type'], 'sendreceive')
        self.api(self.local, 'db/scan?folder=Project', 'POST')
        wait(lambda: (self.remote / 'only-local.txt').exists(), 'promoted receiveonly upload')

    def test_tray_waits_for_remote_acceptance(self):
        (self.source / 'data.txt').write_text('pending upload')
        self.folder(self.local, self.source)
        wait(lambda: 'Project' in self.api(self.server, 'cluster/pending/folders'), 'not accepted server offer')
        snapshot = self.inspect()
        self.assertEqual(snapshot['folders'][0]['kind'], 'Pending')
        self.assertNotIn('синхронизирован', snapshot['tray'], snapshot)

    def test_foreign_unresolved_path_does_not_break_snapshot_or_commands(self):
        self.folder(self.local, '~/OtherFolder', share=False, folder_id='foreign')
        self.api(self.local, 'config/folders/foreign', 'PATCH', dict(paused=True))
        (self.source / 'data.txt').write_text('foreign path must not block this project')
        result = self.action('add')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.api(self.local, 'config/folders/Project')['path'], str(self.source))
        snapshot = self.inspect()
        self.assertTrue(any(f['Id'] == 'Project' for f in snapshot['folders']))
        wait(lambda: 'Project' in self.api(self.server, 'cluster/pending/folders'), 'offer beside foreign path')
        self.folder(self.server, self.remote)
        wait(lambda: self.inspect()['folders'][0]['kind'] == 'Synced', 'sync beside foreign path')
        result = self.action('keep-server')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.recycle / 'data.txt').exists())
        self.assertEqual(self.api(self.local, 'config/folders/foreign')['path'], '~/OtherFolder')


class RecycleContractTests(unittest.TestCase):
    def test_native_recycle_cannot_silently_nuke(self):
        source = (ROOT / 'app/launcher/DiskExplorerController.cs').read_text()
        native = (ROOT / 'app/launcher/DiskRecycle.cs').read_text()
        self.assertFalse('FileSystem.DeleteDirectory' in source, 'VB SendToRecycleBin allows permanent deletion')
        self.assertIn('FOF_WANTNUKEWARNING', source + native)
        self.assertIn('FOFX_RECYCLEONDELETE', source + native)
        self.assertNotIn('FOF_NOERRORUI', source + native)


if __name__ == '__main__':
    unittest.main()
