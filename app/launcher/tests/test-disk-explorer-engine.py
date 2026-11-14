#!/usr/bin/env python3
"""C# Explorer actions against two real disposable Syncthing engines; Linux recycle is a move fixture."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

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


with stand_module.Stand() as stand, tempfile.TemporaryDirectory(prefix='explorer-engine-') as temp:
    temp = Path(temp)
    server, local = stand.sides
    for side, other in ((server, local), (local, server)):
        stand.api(side, 'config/devices', 'POST', {
            'deviceID': other['deviceId'], 'name': 'fixture peer',
            'addresses': [f"tcp://127.0.0.1:{other['listen']}"],
            'autoAcceptFolders': False,
        })
    disk_home = temp / 'RemoteDisk'
    (disk_home / 'state').mkdir(parents=True)
    # The client reads its normal config.xml and server.txt locations, with real generated fixture credentials.
    (disk_home / 'state/config.xml').symlink_to(local['state'] / 'config.xml')
    (disk_home / 'server.txt').write_text(server['deviceId'] + '\r\n')
    disk = temp / 'Disk'
    disk.mkdir()
    remote_folder = server['home'] / 'Disk/Проект'
    remote_folder.mkdir(parents=True)
    (remote_folder / 'hello.txt').write_text('real server contents\n')
    stand.api(server, 'config/folders', 'POST', {
        'id': 'opaque-folder-id', 'label': 'Проект', 'path': str(remote_folder),
        'type': 'sendreceive', 'devices': [{'deviceID': local['deviceId']}],
    })
    wait(lambda: 'opaque-folder-id' in stand.api(local, 'cluster/pending/folders'), 'pending server offer')

    def action(verb, path, recycled=None):
        args = [DOTNET, DLL, '--disk-engine-action', disk_home, disk, verb, path,
                ROOT / 'disk/stignore.txt', recycled or temp / 'unused-recycle']
        result = subprocess.run([str(x) for x in args], capture_output=True, text=True, timeout=25)
        assert result.returncode == 0, (verb, result.stdout, result.stderr)
        print(verb + ': ' + result.stdout.strip(), flush=True)

    downloaded = disk / 'Проект'
    action('download', downloaded)
    wait(lambda: (downloaded / 'hello.txt').read_text() == 'real server contents\n', 'actual download to label path')
    config = next(f for f in stand.api(local, 'config/folders') if f['id'] == 'opaque-folder-id')
    assert config['fsWatcherDelayS'] == 2 and config['maxConflicts'] == -1
    assert config['type'] == 'sendreceive' and config['versioning']['type'] == 'staggered'

    external = temp / 'External'
    external.mkdir()
    (external / 'upload.txt').write_text('real external contents\n')
    (external / '.env').write_text('synthetic ignored fixture\n')
    (external / '.git').mkdir()
    (external / '.git/config').write_text('synthetic ignored fixture\n')
    action('add', external)
    wait(lambda: 'External' in stand.api(server, 'cluster/pending/folders'), 'external offer reaches server')
    server_external = server['home'] / 'Disk/External'
    stand.api(server, 'config/folders', 'POST', {
        'id': 'External', 'label': 'External', 'path': str(server_external),
        'type': 'sendreceive', 'devices': [{'deviceID': local['deviceId']}],
    })
    wait(lambda: (server_external / 'upload.txt').read_text() == 'real external contents\n', 'actual external upload')
    assert external.is_dir() and not (server_external / '.env').exists() and not (server_external / '.git').exists()

    def complete():
        local_status = stand.api(local, 'db/status?folder=opaque-folder-id')
        remote_status = stand.api(local, 'db/completion?folder=opaque-folder-id&device=' + server['deviceId'])
        return (local_status['state'] == 'idle' and local_status['needTotalItems'] == 0 and
                remote_status['completion'] == 100 and remote_status['remoteState'] == 'valid')

    wait(complete, 'confirmed completion before keep-server')
    recycled = temp / 'RecycleBin/Проект'
    recycled.parent.mkdir()
    action('keep-server', downloaded, recycled)
    assert (recycled / 'hello.txt').read_text() == 'real server contents\n'
    assert (remote_folder / 'hello.txt').read_text() == 'real server contents\n'
    assert {p.name for p in downloaded.iterdir()} == {'desktop.ini'}
    assert 'Placeholder=1' in (downloaded / 'desktop.ini').read_text(encoding='utf-16')
    assert not any(f['id'] == 'opaque-folder-id' for f in stand.api(local, 'config/folders'))
    assert any(f['id'] == 'opaque-folder-id' for f in stand.api(server, 'config/folders'))
    print('PASS: C# Explorer actions / two real Syncthing engines: pending ID != label, download, in-place upload, exclusions, detach, preserved server files, cloud placeholder', flush=True)
