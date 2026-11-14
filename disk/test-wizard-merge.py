#!/usr/bin/env python3
"""Native first merge of populated folders, with real disposable Syncthing peers."""
import importlib.util
import os
from pathlib import Path
import time
import unittest

spec = importlib.util.spec_from_file_location('disk_stand', Path(__file__).with_name('test-disk.py'))
t = importlib.util.module_from_spec(spec)
spec.loader.exec_module(t)


class InitialMergeTests(unittest.TestCase):
    def test_populated_folders_merge_and_keep_both_conflicting_versions(self):
        with t.Stand() as stand:
            a, b = stand.sides
            for i, side in enumerate(stand.sides):
                folder = side['home'] / 'Disk/project'
                folder.mkdir(parents=True)
                side['folder'] = folder
                (folder / 'same-name.txt').write_text('initial-server' if i == 0 else 'initial-local')
                stamp = time.time() - 60 + i * 5
                os.utime(folder / 'same-name.txt', (stamp, stamp))
                (folder / ('only-server.txt' if i == 0 else 'only-local.txt')).write_text('server' if i == 0 else 'local')
                (folder / 'identical.txt').write_text('same bytes')
                stamp = time.time() - 3600 * (i + 1)
                os.utime(folder / 'identical.txt', (stamp, stamp))
                (folder / 'identical.txt').chmod(0o644 if i == 0 else 0o600)
                nested = folder / 'same-dir/inner'
                nested.mkdir(parents=True)
                for n in range(3):
                    f = nested / f'file-{n}.bin'
                    f.write_bytes(bytes([n]) * 200000)
                    stamp = time.time() - 7200 - i * 500 - n
                    os.utime(f, (stamp, stamp))
                (folder / '.env').write_text('private-' + str(i))
            # Register devices while paused; bootstrap discovers existing directories.
            for side, peer in ((a, b), (b, a)):
                stand.register(side, peer, paused=True)
                stand.scan(side, 'project')
            t.wait(lambda: all(stand.api(side, 'db/status?folder=project')['localFiles'] == 6
                               for side in stand.sides), 'initial populated scans')
            for side, peer in ((a, b), (b, a)):
                stand.api(side, 'config/devices/' + peer['deviceId'], 'PATCH', dict(paused=False))

            def merged():
                for side in stand.sides:
                    folder = side['folder']
                    versions = [folder / 'same-name.txt', *folder.glob('same-name.sync-conflict-*')]
                    if {p.read_text() for p in versions if p.exists()} != {'initial-server', 'initial-local'}:
                        return False
                    if not all((folder / name).exists() for name in ('only-server.txt', 'only-local.txt')):
                        return False
                return stand.settled('project')

            t.wait(merged, 'first merge keeps both original versions')
            t.wait(lambda: len({int((side['folder'] / 'identical.txt').stat().st_mtime)
                               for side in stand.sides}) == 1 and stand.settled('project'),
                   'identical file metadata aligned')
            for i, side in enumerate(stand.sides):
                folder = side['folder']
                self.assertEqual((folder / 'identical.txt').read_text(), 'same bytes')
                copies = [p.relative_to(folder).as_posix() for p in folder.rglob('*sync-conflict*')]
                self.assertEqual(len(copies), 1)
                self.assertTrue(copies[0].startswith('same-name.sync-conflict-'))
                for n in range(3):
                    self.assertEqual((folder / 'same-dir/inner' / f'file-{n}.bin').read_bytes(), bytes([n]) * 200000)
                self.assertEqual((folder / 'only-server.txt').read_text(), 'server')
                self.assertEqual((folder / 'only-local.txt').read_text(), 'local')
                self.assertEqual((folder / '.env').read_text(), 'private-' + str(i))
                config = stand.folder(side, 'project')
                self.assertEqual(config['maxConflicts'], -1)
                self.assertEqual(config['versioning']['type'], 'staggered')
                self.assertEqual(stand.api(side, 'db/status?folder=project')['localFiles'], 8)


if __name__ == '__main__':
    unittest.main()
