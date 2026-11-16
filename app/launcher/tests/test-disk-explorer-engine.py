#!/usr/bin/env python3
"""Disk contract with two real disposable Syncthing engines and a reversible recycle fixture."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('disk_stand', ROOT / 'disk/test-disk.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
DOTNET = os.environ.get('DOTNET', str(Path.home() / '.dotnet/dotnet'))
DLL = ROOT / 'app/launcher/tests/bin/Release/net10.0/PortableTests.dll'


def wait(predicate, description, seconds=5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            if predicate():
                return
        except (OSError, KeyError, ValueError):
            pass
        time.sleep(.02)
    raise AssertionError('timeout: ' + description)


with module.Stand() as stand, tempfile.TemporaryDirectory(prefix='disk-contract-engine-') as temp:
    temp = Path(temp)
    server, local = stand.sides
    for side, other in ((server, local), (local, server)):
        stand.register(side, other)
    home = temp / 'RemoteDisk'
    (home / 'state').mkdir(parents=True)
    (home / 'state/config.xml').symlink_to(local['state'] / 'config.xml')
    (home / 'server.txt').write_text(server['deviceId'] + '\r\n')
    disk = temp / 'Disk'
    disk.mkdir()
    seed = server['home'] / 'Disk/Seed'
    seed.mkdir(parents=True)
    module.run(['git', 'init', '-q', seed])

    def api(side, route, method='GET', body=None):
        return stand.api(side, route, method, body)

    def args(action, path=None, recycle=None, root=None):
        return list(map(str, (DOTNET, DLL, '--disk-engine-action', home, root or disk, action,
                              path or disk / 'unused', ROOT / 'disk/stignore.txt', recycle or temp / 'unused-recycle')))

    def action(verb, path=None, recycle=None):
        result = subprocess.run(args(verb, path, recycle), capture_output=True, text=True, timeout=5)
        assert result.returncode == 0, (verb, result.stdout, result.stderr)
        return result.stdout

    def inspect():
        return json.loads(action('inspect').strip().splitlines()[-1])

    def upload(name):
        path = disk / name
        path.mkdir()
        (path / 'data.txt').write_text(name + ' preserved')
        action('add', path)
        config = next(f for f in api(local, 'config/folders') if f['path'] == str(path))
        project_id = config['id']
        assert project_id.startswith('rd-upload-v1-') and len(project_id) == 45
        wait(lambda: project_id in api(server, 'cluster/pending/folders'), name + ' offer')
        stand.server(server, 'bootstrap')
        remote = server['home'] / 'Disk' / name
        wait(lambda: (remote / 'data.txt').is_file(), name + ' server admission and delivery')
        assert (remote / '.git').is_dir(), 'Upload admission creates actual git'
        wait(lambda: next(f for f in inspect()['folders'] if f['Id'] == project_id)['kind'] == 'Synced', name + ' confirmation')
        return path, project_id, remote

    source, project_id, remote = upload('Project')
    # Keep: server bytes intact; registration gone, empty owned placeholder on PC.
    recycle = temp / 'Recycled'
    action('keep-server', source, recycle)
    assert (remote / 'data.txt').read_text() == 'Project preserved'
    assert (recycle / 'data.txt').read_text() == 'Project preserved'
    assert {p.name for p in source.iterdir()} == {'desktop.ini'}
    # The peer need not resend its unchanged ClusterConfig after our DELETE.
    # Keep's durable catalog must offer the same ID even before pending reappears.
    assert next(f for f in inspect()['folders'] if f['Id'] == project_id)['kind'] == 'ServerOnly'
    action('download', source)
    wait(lambda: (source / 'data.txt').is_file(), 'explicit re-download')
    wait(lambda: next(f for f in inspect()['folders'] if f['Id'] == project_id)['kind'] == 'Synced', 're-download confirmed')
    # H17: confirmed remote withdrawal becomes durable retirement; PC bytes untouched.
    api(server, 'config/folders/' + project_id, 'DELETE')
    wait(lambda: api(local, 'db/completion?folder=' + project_id + '&device=' + server['deviceId'])['remoteState'] == 'notSharing', 'remote withdrawal')
    assert next(f for f in inspect()['folders'] if f['Id'] == project_id)['kind'] == 'ServerRemoved'
    assert not any(f['id'] == project_id for f in api(local, 'config/folders'))
    assert (source / 'data.txt').read_text() == 'Project preserved'
    # An obsolete peer offer cannot revive the local retired ID.
    api(server, 'config/folders', 'POST', dict(id=project_id, label='Project', path=str(remote), devices=[dict(deviceID=local['deviceId'])]))
    wait(lambda: project_id in api(local, 'cluster/pending/folders'), 'obsolete offer')
    assert next(f for f in inspect()['folders'] if f['Id'] == project_id)['kind'] == 'ServerRemoved'
    assert not any(f['id'] == project_id for f in api(local, 'config/folders'))
    print('PASS: Upload UUID admission/git, Keep/download, durable server removal without touching local bytes', flush=True)

    # H03: delete, rename and move of the root are detachments, never file deletion events.
    fixtures = {name: upload(name) for name in ('Deleted', 'Renamed', 'Moved', 'Copied', 'Brief')}
    shutil.rmtree(fixtures['Deleted'][0])
    renamed = disk / 'Local renamed'
    fixtures['Renamed'][0].rename(renamed)
    moved = temp / 'Outside Disk'
    fixtures['Moved'][0].rename(moved)
    copied = temp / 'Copy delete destination'
    shutil.copytree(fixtures['Copied'][0], copied)
    shutil.rmtree(fixtures['Copied'][0])
    brief = disk / 'brief-save'
    fixtures['Brief'][0].rename(brief)
    action('watch-missing', 100)
    brief.rename(fixtures['Brief'][0])
    action('watch-missing', 131)
    ids = {f['id'] for f in api(local, 'config/folders')}
    assert fixtures['Brief'][1] in ids
    for name in ('Deleted', 'Renamed', 'Moved', 'Copied'):
        path, retired_id, server_copy = fixtures[name]
        assert retired_id not in ids and (server_copy / 'data.txt').read_text() == name + ' preserved'
        # A detached confirmed ID is already offered by the durable local catalog;
        # no new ClusterConfig/pending event is required from the unchanged server.
        assert next(f for f in inspect()['folders'] if f['Id'] == retired_id)['kind'] == 'ServerOnly'
    assert (renamed / 'data.txt').is_file() and (moved / 'data.txt').is_file()
    assert not any(f['path'] in (str(renamed), str(moved)) for f in api(local, 'config/folders'))
    # Unavailable whole base is not evidence of deletion of any child.
    unavailable = temp / 'Disk unavailable'
    disk.rename(unavailable)
    process = subprocess.run(args('watch-missing', 200), capture_output=True, text=True, timeout=5)
    assert process.returncode == 0, process.stderr
    assert fixtures['Brief'][1] in {f['id'] for f in api(local, 'config/folders')}
    unavailable.rename(disk)
    # Keeping the project root/marker means ordinary two-way file deletion.
    brief_path, brief_id, brief_remote = fixtures['Brief']
    (brief_path / 'data.txt').unlink()
    api(local, 'db/scan?folder=' + brief_id, 'POST')
    wait(lambda: not (brief_remote / 'data.txt').exists(), 'ordinary content deletion propagates')
    print('PASS: root delete/rename/external move detach after grace; brief absence and unavailable base preserve registration; server bytes intact', flush=True)

    # Q7: reinstall copy remains local until explicit merge, including both conflict versions.
    server_copy = server['home'] / 'Disk/Reinstall'
    server_copy.mkdir()
    local_copy = disk / 'Reinstall'
    local_copy.mkdir()
    for path, content, age in ((server_copy, 'server original', 90), (local_copy, 'local original', 60)):
        f = path / 'same-name.txt'
        f.write_text(content)
        stamp = time.time() - age
        os.utime(f, (stamp, stamp))
        (path / ('only-server.txt' if path == server_copy else 'only-local.txt')).write_text(content)
    api(server, 'config/folders', 'POST', dict(id='reinstall-stable-id', label='Reinstall', path=str(server_copy), maxConflicts=-1, devices=[dict(deviceID=local['deviceId'])]))
    wait(lambda: 'reinstall-stable-id' in api(local, 'cluster/pending/folders'), 'reinstall offer')
    assert next(f for f in inspect()['folders'] if f['Id'] == 'reinstall-stable-id')['kind'] == 'LocalCopy'
    assert not any(f['id'] == 'reinstall-stable-id' for f in api(local, 'config/folders'))
    action('sync', local_copy)

    def merged():
        for path in (server_copy, local_copy):
            files = [path / 'same-name.txt', *path.glob('same-name.sync-conflict-*')]
            if {p.read_text() for p in files if p.is_file()} != {'server original', 'local original'}:
                return False
            if not all((path / name).is_file() for name in ('only-server.txt', 'only-local.txt')):
                return False
        return True
    wait(merged, 'explicit native merge keeps both conflict versions')
    assert api(local, 'config/folders/reinstall-stable-id')['maxConflicts'] == -1
    print('PASS: explicit reinstall merge uses server identity and preserves both conflict versions', flush=True)
