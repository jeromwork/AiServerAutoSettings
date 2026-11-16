#!/usr/bin/env python3
"""Bounded smoke of real BEP/REST/ignore rules; transition branches are in fast."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
spec = importlib.util.spec_from_file_location('disk_stand', HERE / 'test-disk.py')
disk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(disk)
DOTNET = os.environ.get('DOTNET', str(Path.home() / '.dotnet/dotnet'))
DLL = HERE / 'tests/bin/Release/net10.0/DiskTests.dll'


def interrupted(*_):
    raise SystemExit('Live budget exhausted; cleaning disposable engines')


signal.signal(signal.SIGTERM, interrupted)


def wait(predicate, label):
    end = time.monotonic() + float(os.environ.get('REMOTE_DISK_LIVE_WAIT_S', '5'))
    while True:
        if predicate():
            return
        if time.monotonic() >= end:
            raise AssertionError('timeout: ' + label)
        time.sleep(.02)


start = time.monotonic()
with disk.Stand(2) as stand, tempfile.TemporaryDirectory(prefix='disk-live-client-') as temp:
    temp = Path(temp)
    server, local = stand.sides
    for side, peer in ((server, local), (local, server)):
        stand.register(side, peer)
    disk.make_disk(server['home'])
    home, root = temp / 'RemoteDisk', temp / 'Disk'
    root.mkdir()
    (home / 'state').mkdir(parents=True)
    (home / 'state/config.xml').symlink_to(local['state'] / 'config.xml')
    (home / 'server.txt').write_text(server['deviceId'] + '\r\n')

    def api(side, route, method='GET', body=None):
        return stand.api(side, route, method, body)

    def action(verb, path):
        result = subprocess.run(list(map(str, (DOTNET, DLL, '--disk-engine-action', home, root,
            verb, path, HERE / 'stignore.txt', temp / 'Recycled', 3000))),
            capture_output=True, text=True, timeout=5,
            env={**os.environ, 'HOME': str(temp), 'LOCALAPPDATA': str(temp / 'local'), 'USERPROFILE': str(temp)})
        assert result.returncode == 0, (verb, result.stdout, result.stderr)
        return result.stdout

    def kind(identity):
        rows = json.loads(action('inspect', root))['folders']
        return next(f['kind'] for f in rows if f['Id'] == identity)

    source = root / 'Project'
    source.mkdir()
    (source / 'data.txt').write_text('preserved')
    action('add', source)
    identity = next(f['id'] for f in api(local, 'config/folders') if f['path'] == str(source))
    wait(lambda: identity in api(server, 'cluster/pending/folders'), 'Upload offered')
    stand.server(server, 'bootstrap')
    remote = server['home'] / 'Disk/Project'
    wait(lambda: (remote / 'data.txt').is_file(), 'Upload delivered')
    wait(lambda: kind(identity) == 'Synced', 'fresh acceptance')
    assert (remote / '.git').is_dir()
    for side in (local, server):
        config = api(side, 'config/folders/' + identity)
        assert config['versioning']['params']['maxAge'] == '2592000'
    print('PASS live: explicit Upload, server git admission, real transfer, both completions, 30-day versions', flush=True)

    for name in ('.env', 'key.pem', 'cert.crt2', 'token-live.json', '.venv/private', 'vendor/private', 'local.sqlite', 'backup.sql.gz'):
        p = source / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text('synthetic local-only')
    (source / 'sentinel.txt').write_text('scan completed')
    api(local, 'db/scan?folder=' + identity, 'POST')
    wait(lambda: (remote / 'sentinel.txt').is_file(), 'positive scan sentinel')
    assert not any((remote / name).exists() for name in ('.env', 'key.pem', 'cert.crt2', 'token-live.json', '.venv', 'vendor', 'local.sqlite', 'backup.sql.gz'))
    # The Keep refusal and full path list are tested on fake REST. Remove only fixture secrets here.
    for p in (source / '.env', source / 'key.pem', source / 'cert.crt2', source / 'token-live.json', source / '.venv/private', source / 'vendor/private', source / 'local.sqlite', source / 'backup.sql.gz'):
        p.unlink()
    (source / '.venv').rmdir()
    (source / 'vendor').rmdir()
    wait(lambda: kind(identity) == 'Synced', 'sentinel completion')
    action('keep-server', source)
    assert (temp / 'Recycled/data.txt').read_text() == (remote / 'data.txt').read_text() == 'preserved'
    assert {p.name for p in source.iterdir()} == {'desktop.ini'}
    action('download', source)
    wait(lambda: (source / 'data.txt').is_file(), 'explicit re-download')
    wait(lambda: kind(identity) == 'Synced', 'download completion')
    print('PASS live: effective mandatory ignores, safe Keep, placeholder, explicit download', flush=True)

    api(server, 'config/folders/' + identity, 'DELETE')
    stand.server(server, 'bootstrap')
    wait(lambda: api(local, 'db/completion?folder=' + identity + '&device=' + server['deviceId'])['remoteState'] == 'notSharing', 'server withdrawal')
    assert kind(identity) == 'ServerRemoved'
    assert not api(local, 'config/folders')
    assert (source / 'data.txt').read_text() == 'preserved'
    assert identity in json.loads((server['state'] / 'missing-folders.json').read_text())['removed']
    print('PASS live: server withdrawal, durable tombstone, local detach without deleting bytes', flush=True)
print(f'Disk live: {time.monotonic() - start:.3f} s', flush=True)
