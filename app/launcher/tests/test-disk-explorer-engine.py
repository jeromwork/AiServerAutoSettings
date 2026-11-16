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
    # The server drops the registration of a folder it shared (the files stay): the real engine reports remoteState=notSharing,
    # and the Explorer, told by the memory «the server confirmed this folder», shows «removed on the server», not an error.
    def inspect():
        args = [DOTNET, DLL, '--disk-engine-action', disk_home, disk, 'inspect', temp / 'unused',
                ROOT / 'disk/stignore.txt', temp / 'unused-recycle']
        result = subprocess.run([str(x) for x in args], capture_output=True, text=True, timeout=25)
        assert result.returncode == 0, ('inspect', result.stdout, result.stderr)
        return json.loads(result.stdout.strip().splitlines()[-1])

    def kind_of(snapshot):
        return next(f['kind'] for f in snapshot['folders'] if f['Id'] == 'External')

    wait(lambda: kind_of(inspect()) == 'Synced', 'External confirmed by the server before it is removed there')
    stand.api(server, 'config/folders/External', 'DELETE')
    wait(lambda: stand.api(local, 'db/completion?folder=External&device=' + server['deviceId'])['remoteState'] == 'notSharing', 'engine reports the folder as not shared by the server')
    removed = inspect()
    assert kind_of(removed) == 'ServerRemoved', removed
    assert removed['tray'].startswith('Диск: папки удалены на сервере') and 'ошибка' not in removed['tray'], removed['tray']  # External is the only shared folder
    assert any(f['id'] == 'External' for f in stand.api(local, 'config/folders')) and (server_external / 'upload.txt').is_file() and (external / 'upload.txt').is_file()
    print('PASS: C# Explorer actions / two real Syncthing engines: pending ID != label, download, in-place upload, exclusions, detach, preserved server files, cloud placeholder, folder removed by the server', flush=True)

    # The PC offered these folders originally; exercise the actual server accept_pending.
    paths = {}
    for name in ('Vanished', 'Brief', 'MissingParent'):
        path = temp / ('parent' if name == 'MissingParent' else 'sources') / name
        path.mkdir(parents=True, exist_ok=True)
        (path / 'keep.txt').write_text(name + ' preserved on server\n')
        action('add', path)
        wait(lambda name=name: name in stand.api(server, 'cluster/pending/folders'), name + ' offered')
        stand.server(server, 'bootstrap')
        wait(lambda name=name: (server['home'] / 'Disk' / name / 'keep.txt').is_file(), name + ' accepted and uploaded')
        paths[name] = path
    # An empty Disk root and an absent parent are not evidence of an individual deletion.
    # This separate Disk contains only the folder about to vanish.
    empty_disk = temp / 'EmptyDisk'
    empty_disk.mkdir()
    empty_path = empty_disk / 'EmptyGuard'
    empty_path.mkdir()
    stand.api(local, 'config/folders', 'POST', {
        'id': 'EmptyGuard', 'label': 'EmptyGuard', 'path': str(empty_path),
        'devices': [{'deviceID': server['deviceId']}],
    })
    import shutil
    shutil.rmtree(empty_path)
    # The primary watchdog gets empty_disk as its Disk root; external folders still qualify.
    shutil.rmtree(paths['Vanished'])
    brief_saved = paths['Brief'].with_name('brief-saved')
    paths['Brief'].rename(brief_saved)
    missing_parent = temp / 'parent'
    missing_parent.rename(temp / 'parent-unmounted')
    watch_args = [DOTNET, DLL, '--disk-engine-action', disk_home, empty_disk, 'watch-missing',
                  temp / 'unused', ROOT / 'disk/stignore.txt', temp / 'unused-recycle']
    started = time.monotonic()
    process = subprocess.Popen([str(x) for x in watch_args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        time.sleep(3)
        brief_saved.rename(paths['Brief'])
        wait(lambda: not any(f['id'] == 'Vanished' for f in stand.api(local, 'config/folders')), 'PC detaches missing folder after thirty seconds', 38)
        elapsed = time.monotonic() - started
        assert elapsed >= 30, elapsed
        stdout, stderr = process.communicate(timeout=10)
        assert process.returncode == 0, (stdout, stderr)
        assert stdout.count('disk.folder.missing.detached: Vanished') == 1, stdout
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
    ids = {f['id'] for f in stand.api(local, 'config/folders')}
    assert {'Brief', 'MissingParent', 'EmptyGuard'} <= ids and 'Vanished' not in ids, ids
    assert not paths['Vanished'].exists(), 'no file or directory resurrection by watchdog'
    server_copy = server['home'] / 'Disk/Vanished/keep.txt'
    assert server_copy.read_text() == 'Vanished preserved on server\n'
    # Reconcile repeatedly: the server retains its accepted folder, never a second copy.
    for _ in range(3):
        stand.server(server, 'bootstrap')
    server_config = [f for f in stand.api(server, 'config/folders') if f['id'] == 'Vanished']
    assert len(server_config) == 1 and Path(server_config[0]['path']) == server_copy.parent
    wait(lambda: 'Vanished' in stand.api(local, 'cluster/pending/folders'), 'server copy is an ordinary pending offer')
    wait(lambda: stand.api(server, 'db/status?folder=Vanished')['state'] == 'idle', 'server folder stays idle')
    status = stand.api(server, 'db/status?folder=Vanished')
    assert not status.get('error') and not status.get('pullErrors'), status
    # A detached local folder has no db/status and therefore no folder error; the offer is neutral.
    assert next(f for f in inspect()['folders'] if f['Id'] == 'Vanished')['kind'] == 'ServerOnly'
    assert not paths['Vanished'].exists() and server_copy.is_file()
    print('PASS: PC missing >=30s detached; server accept_pending copy/files intact; pending offer, no resurrection; brief disappearance, unavailable parent, empty Disk protected', flush=True)
