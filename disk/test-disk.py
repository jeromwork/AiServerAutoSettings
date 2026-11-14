#!/usr/bin/env python3
"""Server contracts against real Syncthing in disposable HOME directories."""
import base64
import contextlib
import hashlib
import http.client
import http.server
import io
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as E
import zlib

HERE = Path(__file__).resolve().parent
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))
ARCHIVE_NAME = 'syncthing-linux-amd64-v2.1.7.tar.gz'

# Прежние шаблоны .stignore, которые наш код сам клал в папки (байт в байт). Три из них — disk/stignore.txt на app/config
# (git show <коммит>:disk/stignore.txt, zlib+base64); четвёртый собирается из списка имён Get-DiskIgnores в
# disk/RemoteDisk.ps1 до коммита 395c2cb. Их SHA-256 лежат в PREVIOUS_TEMPLATES самого server-disk.sh.
OLD_TEMPLATES_ZLIB = {
    '395c2cb': (
        'eNpV0T1OwzAYBuC9p8gIFU3VokrAwsIJuEDl5Pto3Ti28U9pt7YMDAyImyBBpQpRuIJ9I5LY'
        'aWHK8/rndeL0+8ktlsLgDdXFVeL2bpu4H7f1K7d1H+7Nv7qvxK+r8FkP+Y1/Ttwu8Rv3fZb4'
        'p/qZuPdqet/s2fmVf2yWrf1L5+SanqbI590gLkuVB8qlpK05mkhizTSdacGblCsE5IYSpkOB'
        'xmrIxEBhrDQ5GGE4Gg0ujzmHP7MHd9MCl0dpIxTGOCt0lLxoMRi2uls0YiInLJVKSFSGYtiR'
        'TqgJ0HoakAvARSQjFsIhqRGChT28WjAuBVgWS+bIQajYpwgwbG9nEcu5bSWskTY6J/m0bbcq'
        'E4FAlBnXp8VFi/AymaUMGgHVocAQNcFAkc3CxYs5KjKJrRSQBM11/VnhT3FQgkJPQxFviIlJ'
        'lL5n1OC/cB4TZAf0Hgg7Bj0t22BLGZmRovMLvwzliA=='
    ),
    'b8cfc4e': (
        'eNptks1OGzEUhfd5Ci8pKjOCCql0w4ZlV32ByDO+JM54bOOfIewgrdRKqKr6JlEhQFsCr2C/'
        'ER7bkxSpq/nOte+5Y/uUJfoErTBwQnXzAbm1WyH37Fb+0q3crVv6n+4R+asg/vQlv/DXyD0g'
        'v3BPb5H/2n+RuwnL69jz4C/957jtyv8Y7RzTNwXwbjcRl62qE8oLSQfmYDJia6bFTAseVa2A'
        'ADcUM50MNISSyYKSsdJ4w0AODg/3j7a6Jv+sbni3aOBiS9oIBVnOGp1Jvh9g/2Cg03kkJmrM'
        'CqmEBGUopI5iQk0CracJakFgnpFhS9KQwgjBUg8PG8atIJZlkw44ESr7KUwYDLczz+bcDiSs'
        'kTZzjevp4G5VJRISrMy4n5Y3zdPPVJYyEolQnQwMVhNIKKpZunjRgcKT7EoJ4ESd7o+VXooT'
        'JSjZ06TJN8TEJJM+Y9TAK/EuK1JtYO8cs63Q03YQtpUZK9yMyhJ9xAp3wEI4793S3cSE3cXE'
        'rf11iKv/Esq/3d+UzJDT7/4bcr9Q/7jhFCHOIZhPMcELt/x/xOPEMneUWMrXhVOFWzgXqhm9'
        'AFv1MvM='
    ),
    'f79b03f': (
        'eNptk0tu2zAQhvc+BZdt0EhIigB9LLrpsqtewKBFxqZFiSxJOc4ucQq0QPpAL9BewYij1E1s'
        '9wrkjTp8yI6BLgR9/2ie1DDP0XtaCUPfMl2+QnZtW2T/2tZd2Nbe2rn7YVfIXYK49yY3c9fI'
        'LpGb2c0z5D75N7IL+LwOMUt34a6C26X73nvyhj3NaD05iFTLShUR5blkHdfUJMSNGWVjLeqg'
        'CkUJrQ3DXMcEmoLJJMFIX2m8ZUqOT06OXu50QR593fJBVtLzHWkjFE1yXOpE8kUHR8cdnU4D'
        'cVFgnkklJFWG0RiRDZmJoPUoQiEInSbkuCGxSGaE4DGmBod+JUjDU5IJrYlQKZ/ChNPudKYp'
        'ed10JBojm8QFLkZd9kYNRESClen7aslpGpsZNIyTQITpmMBgNaQRxWAcD15MqMLDlJURiiNN'
        'tB8r/qmaKMHIoSZlOiEuhon0B84M3RPPkyKDLRyeYb4TelR1oqlkwgEue3mO3mGFJ5TDcv62'
        'c7sIG3YXNm7trmFd3Ucw/7EPcTNhT7+6z8jeIP9zYQpYZ1jMTdjgmZ3/f8VDxTxF5FjKfcOp'
        'whU9Eyr0Y39CxQ1Er+xDaGPpE/4KRW7guQ2me1/KV16CnIPR+97BBZkhaBCujV25K+jWA/h9'
        'cd/A2PrhXkPz4L3ZG5JQXRohM1azOAFcMV9wAbnbrv9HTr1/z2Odfw=='
    ),
}
LEGACY_IGNORE_NAMES = (
    '.env*', 'env.example', '.npmrc', '.pypirc', '.netrc', 'auth.json', '*credential*', '*token*', '*secret*',
    '*private*', 'id_*', '.git', '.tools', 'ssh', '.ssh', '.codex', '.claude', 'node_modules', 'vendor', 'deps',
    'dependencies', '.gradle', '.next', '.cache', '.stversions', '.stfolder', '.stignore', 'build', 'dist', 'target',
    'obj', 'bin', '.dart_tool', '.nuxt', '.output', '.turbo', '.cxx', 'coverage', 'logs', 'log', 'cache', 'caches',
    'db', 'database', 'databases', 'backup', 'backups', '*backup*', '*dump*', 'uploads', 'upload', 'storage',
    'android-sdk', '.idea', '.vscode', 'local.properties', 'google-services*.json', 'GoogleService-Info.plist',
    'config.php', '*.pem', '*.key', '*.keystore', '*.jks', '*.p8', '*.p12', '*.pfx', '*.sqlite', '*.sqlite3', '*.db',
    '*.db3', '*.bak', '*.backup', '*.dump', '*.log', '*.zip', '*.tar', '*.gz', '*.exe', '*.dll', '*.so', '*.bin',
)


def old_templates():
    """Byte-exact previous templates by label: three from git history and the one before the Syncthing rewrite."""
    result = {label: zlib.decompress(base64.b64decode(blob)) for label, blob in OLD_TEMPLATES_ZLIB.items()}
    result['legacy'] = ('\n'.join('(?i)' + name for name in LEGACY_IGNORE_NAMES) + '\n').encode()
    return result


def archive_path():
    configured = os.environ.get('SYNCTHING_ARCHIVE')
    if configured:
        return Path(configured).resolve()
    # Reuse an offline release fixture when available; otherwise bootstrap downloads it.
    return next(iter(sorted(Path('/tmp').glob('remote-disk-release-*/' + ARCHIVE_NAME))), None)


def run(args, env=None, ok=True, stdin=None):
    result = subprocess.run([str(x) for x in args], env=env, input=stdin,
                            capture_output=True, timeout=45)
    if ok and result.returncode:
        raise AssertionError(f'{args[0]}: exit {result.returncode}: {result.stderr.decode(errors="replace")}')
    return result


def wait(predicate, description, seconds=20):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(.1)
    raise AssertionError('timeout: ' + description)


class Stand:
    """Actual isolated engines; fake only host cron/systemd, never Syncthing REST."""
    def __init__(self, count=2):
        self.count = count
        self.sides = []
        self.temp = tempfile.TemporaryDirectory(prefix='disk-server-test-')
        self.root = Path(self.temp.name)

    def __enter__(self):
        try:
            for i in range(self.count):
                home = self.root / f'peer-{i}'
                state = home / '.local/share/remote-disk'
                state.mkdir(parents=True)
                fake_bin = home / 'fake-bin'
                fake_bin.mkdir()
                crontab = fake_bin / 'crontab'
                crontab.write_text(f'''#!{sys.executable}
import os,sys
from pathlib import Path
p=Path.home()/'fake-crontab'
if os.environ.get('FAIL_CRONTAB'):sys.exit(2)
if sys.argv[1]=='-l':
    if not p.exists():sys.exit(1)
    sys.stdout.buffer.write(p.read_bytes())
else:p.write_bytes(sys.stdin.buffer.read())
''')
                crontab.chmod(0o700)
                systemctl = fake_bin / 'systemctl'
                systemctl.write_text(f'''#!{sys.executable}
import json,sys
from pathlib import Path
with (Path.home()/'systemctl-calls').open('a') as f:f.write(json.dumps(sys.argv[1:])+'\\n')
''')
                systemctl.chmod(0o700)
                for name in ('server-disk.sh', 'stignore.txt'):
                    shutil.copyfile(HERE / name, state / name)
                side = dict(home=home, state=state,
                            env={**os.environ, 'HOME': str(home),
                                 'PATH': str(fake_bin) + os.pathsep + os.environ['PATH']})
                self.sides.append(side)
                args = ['bash', state / 'server-disk.sh', 'bootstrap']
                if archive := archive_path():
                    args += ['--archive', archive]
                side.update(json.loads(run(args, side['env']).stdout))
                config = E.parse(state / 'config.xml')
                side.update(gui=config.findtext('gui/address').rsplit(':', 1)[1],
                            key=config.findtext('gui/apikey'))
            return self
        except BaseException:
            self.close()
            raise

    def __exit__(self, *_):
        self.close()

    def close(self):
        states = {os.fsencode(side['state']) for side in self.sides}
        # Match the exact test --home, so no developer/user engine can be stopped.
        for cmdline in Path('/proc').glob('[0-9]*/cmdline'):
            try:
                args = cmdline.read_bytes().split(b'\0')
                if args[0].rsplit(b'/', 1)[-1] == b'syncthing' and any(
                        arg == b'--home' and value in states for arg, value in zip(args, args[1:])):
                    os.kill(int(cmdline.parent.name), signal.SIGKILL)
            except (FileNotFoundError, ProcessLookupError, PermissionError):
                pass
        self.temp.cleanup()

    def server(self, side, action, data=None, ok=True, stdin=False):
        args = ['bash', side['state'] / 'server-disk.sh', action]
        payload = base64.b64encode(json.dumps(data).encode()) if data is not None else None
        if stdin:
            args.append('--stdin')
        elif payload is not None:
            args.append(payload.decode())
        result = run(args, side['env'], ok, payload + b'\r\n' if stdin else None)
        return json.loads(result.stdout) if ok else result

    def api(self, side, route, method='GET', body=None):
        request = urllib.request.Request(
            f"http://127.0.0.1:{side['gui']}/rest/{route}", method=method,
            headers={'X-API-Key': side['key'], 'Content-Type': 'application/json'},
            data=None if body is None else json.dumps(body).encode())
        with HTTP.open(request, timeout=3) as response:
            return json.loads(response.read() or b'{}')

    def folder(self, side, name):
        return self.api(side, 'config/folders/' + urllib.parse.quote(name, safe=''))

    def register(self, side, peer, paused=False):
        self.server(side, 'add-device', dict(deviceId=peer['deviceId'], deviceName=peer['home'].name))
        self.api(side, 'config/devices/' + peer['deviceId'], 'PATCH',
                 dict(addresses=[f"tcp://127.0.0.1:{peer['listen']}"], paused=paused, numConnections=1))

    def scan(self, side, name):
        self.api(side, 'db/scan?folder=' + urllib.parse.quote(name, safe=''), 'POST')

    def settled(self, name):
        for side in self.sides:
            status = self.api(side, 'db/status?folder=' + urllib.parse.quote(name, safe=''))
            if status['state'] != 'idle' or status['needTotalItems'] or status['pullErrors']:
                return False
        return True


@contextlib.contextmanager
def server_helpers(home):
    """Only the helper definitions of server-disk.sh (everything before main), with HOME at a disposable directory."""
    source = (HERE / 'server-disk.sh').read_text().split("<<'PY'\n", 1)[1].split('def main():', 1)[0]
    namespace = {}
    with mock.patch.dict(os.environ, HOME=str(home), REMOTE_DISK_SCRIPT_DIR=str(HERE)):
        exec(compile(source, 'server-disk-helpers', 'exec'), namespace)
        yield namespace


class FakeRest:
    """Just enough of the Syncthing REST for reconcile(): records which folders were written."""
    def __init__(self):
        self.puts = []

    def __call__(self, route, method='GET', body=None):
        if (method, route) == ('GET', 'config/folders'):
            return []
        if (method, route) == ('GET', 'config/devices'):
            return [dict(deviceID='SERVER'), dict(deviceID='PEER')]
        if (method, route) == ('GET', 'config/defaults/folder'):
            return dict(devices=[], versioning={}, maxConflicts=10, type='sendreceive')
        if method == 'PUT' and route.startswith('config/folders/'):
            self.puts.append(urllib.parse.unquote(route.rsplit('/', 1)[1]))
            return {}
        raise AssertionError((method, route))


def raiser(error):
    def raise_it(*args, **kwargs):
        raise error
    return raise_it


class SlowFolderWrites:
    """Reverse proxy in front of the Syncthing REST that holds back PUT of a folder, like a loaded server does."""
    def __init__(self, target_port, delay):
        outer = self
        self.held = 0

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.0'

            def forward(self):
                length = int(self.headers.get('Content-Length') or 0)
                body = self.rfile.read(length) if length else None
                if self.command == 'PUT' and self.path.startswith('/rest/config/folders/'):
                    outer.held += 1
                    time.sleep(delay)
                upstream = http.client.HTTPConnection('127.0.0.1', target_port, timeout=30)
                try:
                    upstream.request(self.command, self.path, body=body, headers={
                        k: v for k, v in self.headers.items() if k.lower() not in ('host', 'connection')})
                    response = upstream.getresponse()
                    data = response.read()
                finally:
                    upstream.close()
                self.send_response(response.status)
                self.send_header('Content-Type', response.getheader('Content-Type', 'application/json'))
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            do_GET = do_PUT = do_POST = do_PATCH = do_DELETE = forward

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.server.shutdown()
        self.server.server_close()


class ServerTests(unittest.TestCase):
    def test_include_preserves_missing_newline_bom_and_existing_include(self):
        with Stand(1) as t:
            side = t.sides[0]
            cases = {
                'NoNewline': b'private-file',
                'BOM': b'\xef\xbb\xbf// user comment\r\nprivate-file\r\n',
                'ExistingInclude': b'// user comment\n#include .stignore-remoteagents\nprivate-file\n',
            }
            for name, original in cases.items():
                path = side['home'] / 'Disk' / name
                path.mkdir(parents=True)
                (path / '.stignore').write_bytes(original)
            t.server(side, 'bootstrap')
            for name, original in cases.items():
                with self.subTest(name=name):
                    path = side['home'] / 'Disk' / name
                    policy = (path / '.stignore').read_bytes()
                    self.assertTrue(policy.startswith(original))
                    self.assertEqual(policy.count(b'#include .stignore-remoteagents'), 1)
                    if name == 'ExistingInclude':
                        self.assertEqual(policy, original)
                    t.server(side, 'bootstrap')
                    self.assertEqual((path / '.stignore').read_bytes(), policy)
                    self.assertEqual(t.folder(side, name)['id'], name)

    def test_registration_offers_every_folder_and_is_idempotent(self):
        with Stand(3) as t:
            a, b, c = t.sides
            for name in ('Existing', 'Проект 1'):
                folder = a['home'] / 'Disk' / name
                folder.mkdir(parents=True)
                (folder / 'keep.txt').write_text(name)
            t.server(a, 'add-device', dict(deviceId=b['deviceId'], deviceName='Laptop'), stdin=True)
            device = next(d for d in t.api(a, 'config/devices') if d['deviceID'] == b['deviceId'])
            self.assertEqual(device['name'], 'Laptop')
            self.assertFalse(device['autoAcceptFolders'])
            for name in ('Existing', 'Проект 1'):
                folder = t.folder(a, name)
                self.assertEqual((folder['id'], folder['type']), (name, 'sendreceive'))
                self.assertEqual({d['deviceID'] for d in folder['devices']}, {a['deviceId'], b['deviceId']})
            # Repeat registration preserves the user's device settings and folder pauses.
            t.api(a, 'config/devices/' + b['deviceId'], 'PATCH', dict(paused=True, compression='never'))
            t.api(a, 'config/folders/Existing', 'PATCH', dict(paused=True))
            before = t.api(a, 'config')
            files = [(a['home'] / 'Disk/Existing' / n) for n in ('.stignore', '.stignore-remoteagents')]
            mtimes = [p.stat().st_mtime_ns for p in files]
            for _ in range(2):
                t.server(a, 'add-device', dict(deviceId=b['deviceId'], deviceName='Laptop'))
            self.assertEqual(t.api(a, 'config'), before)
            self.assertEqual([p.stat().st_mtime_ns for p in files], mtimes)
            t.server(a, 'add-device', dict(deviceId=c['deviceId'], deviceName='Desktop'))
            (a['home'] / 'Disk/New').mkdir()
            t.server(a, 'bootstrap')  # The exact entry point used by cron and systemd.
            for name in ('Existing', 'Проект 1', 'New'):
                self.assertEqual({d['deviceID'] for d in t.folder(a, name)['devices']},
                                 {s['deviceId'] for s in t.sides})
                self.assertEqual(t.folder(a, name)['type'], 'sendreceive')
            self.assertTrue(t.folder(a, 'Existing')['paused'])
            self.assertEqual((a['home'] / 'Disk/Existing/keep.txt').read_text(), 'Existing')

    def test_foreign_ignores_survive_updates_and_rules_work_in_real_engine(self):
        with Stand() as t:
            a, b = t.sides
            source = a['home'] / 'Disk/Shared'
            source.mkdir(parents=True)
            run(['git', 'init', '-q', source])
            original = b'// custom user rules\r\ncustom.txt\r\n'
            (source / '.stignore').write_bytes(original)
            t.register(a, b)
            self.assertTrue((source / '.stignore').read_bytes().startswith(original))
            self.assertEqual((source / '.stignore').read_bytes().count(b'#include .stignore-remoteagents'), 1)
            self.assertEqual((source / '.stignore-remoteagents').read_bytes(), (HERE / 'stignore.txt').read_bytes())
            # A CRLF template update changes only our include target, without a hash history.
            updated = (HERE / 'stignore.txt').read_text() + '\nupdated-only.txt\n'
            (a['state'] / 'stignore.txt').write_bytes(updated.replace('\n', '\r\n').encode())
            before = (source / '.stignore').read_bytes()
            for _ in range(2):
                t.server(a, 'bootstrap')
            self.assertEqual((source / '.stignore').read_bytes(), before)
            self.assertEqual((source / '.stignore-remoteagents').read_bytes(), updated.encode())
            self.assertFalse((a['state'] / 'stignore-previous.sha256').exists())
            self.assertTrue({'.stignore', '.stignore-remoteagents', '.stfolder', '*.sync-conflict-*'} <=
                            set((source / '.git/info/exclude').read_text().splitlines()))
            self.assertEqual(run(['git', '-C', source, 'status', '--porcelain']).stdout, b'')
            t.register(b, a)
            wait(lambda: 'Shared' in t.api(b, 'cluster/pending/folders'), 'standard Syncthing pending offer')
            self.assertEqual(t.api(b, 'config/folders'), [])  # No custom auto-accept loop.
            # Finish acceptance and the initial local scans before exchanging indexes.
            t.api(b, 'config/devices/' + a['deviceId'], 'PATCH', dict(paused=True))
            wait(lambda: not t.api(b, 'system/connections')['connections'].get(a['deviceId'], {}).get('connected'),
                 'disconnect while preparing the accepted folder')
            target = b['home'] / 'Accepted'
            target.mkdir()
            folder = t.api(b, 'config/defaults/folder')
            folder.update(id='Shared', label='Shared', path=str(target), type='sendreceive',
                          devices=[dict(deviceID=s['deviceId']) for s in t.sides])
            t.api(b, 'config/folders/Shared', 'PUT', folder)  # Native acceptance via local REST.
            (target / '.stignore').write_text('#include .stignore-remoteagents\n')
            shutil.copyfile(a['state'] / 'stignore.txt', target / '.stignore-remoteagents')
            allowed = {'log/source.py': 'log source', 'db/schema.sql': 'SQL source', 'source.txt': 'source'}
            denied = ('custom.txt', 'updated-only.txt', '.env', 'identity.key', 'node_modules/a.js', 'build/output')
            for name, content in {**allowed, **dict.fromkeys(denied, 'private or generated')}.items():
                path = source / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
            (target / 'reverse.txt').write_text('reverse')
            t.scan(a, 'Shared')
            t.scan(b, 'Shared')
            wait(lambda: t.api(a, 'db/status?folder=Shared')['localFiles'] == len(allowed) and
                 t.api(b, 'db/status?folder=Shared')['localFiles'] == 1 and t.settled('Shared'),
                 'initial scans of accepted folder')
            t.api(b, 'config/devices/' + a['deviceId'], 'PATCH', dict(paused=False))
            try:
                wait(lambda: all((target / n).exists() for n in allowed) and
                     (source / 'reverse.txt').exists() and t.settled('Shared'), 'bidirectional native synchronization')
            except AssertionError as error:
                diagnostics = [dict(status=t.api(s, 'db/status?folder=Shared'),
                                    errors=t.api(s, 'system/error'),
                                    log=(s['state'] / 'syncthing.log').read_text()[-5000:]) for s in t.sides]
                raise AssertionError(str(error) + '\n' + json.dumps(diagnostics, indent=2)) from error
            self.assertTrue(all((target / n).read_text() == content for n, content in allowed.items()))
            self.assertTrue(all(not (target / n).exists() for n in denied))
            self.assertEqual((source / '.stignore').read_bytes(), before)
            self.assertEqual(t.folder(a, 'Shared')['type'], 'sendreceive')

    def test_existing_ids_and_settings_survive_discovery(self):
        with Stand() as t:
            a, b = t.sides
            project = a['home'] / 'Disk/Existing'
            project.mkdir(parents=True)
            (project / 'keep.txt').write_text('user content')
            t.server(a, 'bootstrap')
            folder = t.folder(a, 'Existing')
            t.api(a, 'config/folders/Existing', 'DELETE')
            folder.update(id='disk-legacy-id', paused=True, type='receiveonly', rescanIntervalS=777)
            t.api(a, 'config/folders/disk-legacy-id', 'PUT', folder)
            t.register(a, b)
            current = t.folder(a, 'disk-legacy-id')
            self.assertEqual((current['type'], current['paused'], current['rescanIntervalS']), ('sendreceive', True, 777))
            self.assertEqual((project / 'keep.txt').read_text(), 'user content')
            self.assertEqual([f['id'] for f in t.api(a, 'config/folders')], ['disk-legacy-id'])
            project.rename(project.with_name('Removed'))
            t.server(a, 'bootstrap')
            self.assertIn('disk-legacy-id', [f['id'] for f in t.api(a, 'config/folders')])

    def test_only_valid_top_level_directories_are_discovered(self):
        with Stand() as t:
            a, b = t.sides
            disk = a['home'] / 'Disk'
            (disk / 'Valid/nested').mkdir(parents=True)
            (disk / 'CON').mkdir()
            (disk / 'bad..name').mkdir()
            (disk / 'trailing.').mkdir()
            (disk / 'file.txt').touch()
            outside = a['home'] / 'outside'
            outside.mkdir()
            (outside / 'keep.txt').write_text('outside')
            (disk / 'Link').symlink_to(outside, target_is_directory=True)
            # Git worktrees with an external gitdir must never modify that external exclude.
            repository = outside / 'repo'
            run(['git', 'init', '-q', repository])
            run(['git', '-C', repository, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                 'commit', '--allow-empty', '-qm', 'initial'])
            run(['git', '-C', repository, 'worktree', 'add', '--detach', disk / 'Worktree'])
            exclude = repository / '.git/info/exclude'
            old_exclude = exclude.read_bytes()
            t.register(a, b)
            self.assertEqual({f['id'] for f in t.api(a, 'config/folders')}, {'Valid', 'Worktree'})
            self.assertEqual(exclude.read_bytes(), old_exclude)
            self.assertEqual((outside / 'keep.txt').read_text(), 'outside')
            self.assertFalse((outside / '.stignore').exists())
            self.assertFalse((disk / 'Valid/nested/.stignore').exists())

    def test_bootstrap_cron_and_install_auto_share_the_same_entry_point(self):
        with Stand(1) as t:
            side = t.sides[0]
            foreign = b'# user cron\n17 * * * * echo keep\n'
            cron = side['home'] / 'fake-crontab'
            cron.write_bytes(foreign)
            for _ in range(2):
                self.assertEqual(t.server(side, 'bootstrap')['deviceId'], side['deviceId'])
            expected = b'* * * * * bash "$HOME/.local/share/remote-disk/server-disk.sh" bootstrap >/dev/null 2>&1\n'
            self.assertEqual(cron.read_bytes(), foreign + expected)
            side['env']['FAIL_CRONTAB'] = '1'
            self.assertEqual(t.server(side, 'bootstrap')['deviceId'], side['deviceId'])
            t.server(side, 'install-auto')
            units = side['home'] / '.config/systemd/user'
            service = (units / 'remote-disk-folders.service').read_text()
            self.assertIn('server-disk.sh" bootstrap', service)
            calls = [json.loads(line) for line in (side['home'] / 'systemctl-calls').read_text().splitlines()]
            self.assertEqual(calls, [['--user', 'daemon-reload'], ['--user', 'enable', '--now', 'remote-disk-folders.timer']])
            config = E.parse(side['state'] / 'config.xml')
            options = config.find('options')
            self.assertTrue(all(options.findtext(n) == 'false' for n in
                                ('relaysEnabled', 'globalAnnounceEnabled', 'localAnnounceEnabled', 'natEnabled')))
            self.assertEqual(options.findtext('autoUpgradeIntervalH'), '0')

    def test_channel_config_is_preserved(self):
        with Stand(1) as t:
            side = t.sides[0]
            # RFC 7748 section 6.1 scalar/public pair, never a real server secret.
            private = bytes.fromhex('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a')
            expected = bytes.fromhex('8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a')
            source = t.root / 'fake-channel.json'
            reality = dict(private_key=base64.urlsafe_b64encode(private).decode().rstrip('='), short_id=['ab'])
            inbound = dict(type='vless', listen_port=443,
                           users=[dict(name='client', uuid='test-only', flow='xtls-rprx-vision')],
                           tls=dict(enabled=True, server_name='test.invalid', reality=reality))
            source.write_text(json.dumps(dict(inbounds=[inbound])))
            side['env']['REMOTE_DISK_CHANNEL_SOURCE'] = str(source)
            before = source.read_bytes()
            for hop in (None, dict(server='hop.invalid', server_port=22, user='tester', private_key_path='unused')):
                result = t.server(side, 'channel-config', dict(server='server.invalid', hop=hop))
                outbound = result['outbounds'][0]
                self.assertEqual(base64.urlsafe_b64decode(outbound['tls']['reality']['public_key'] + '==='), expected)
                self.assertEqual(outbound['server'], 'server.invalid')
                self.assertEqual(outbound['uuid'], 'test-only')
                self.assertEqual([x['override_port'] for x in result['inbounds']], [22, side['listen']])
                self.assertEqual(result['route'], dict(final='server', auto_detect_interface=True))
                self.assertNotIn('"private_key":', json.dumps(result))
                self.assertNotIn(base64.urlsafe_b64encode(private).decode().rstrip('='), json.dumps(result))
                if hop:
                    self.assertEqual(result['outbounds'][1]['detour'], 'hop-ssh')
            self.assertEqual(source.read_bytes(), before)


class ServerHardeningTests(unittest.TestCase):
    def test_reconcile_stays_an_alias_of_bootstrap_for_installed_timers(self):
        with Stand(2) as t:
            a, b = t.sides
            t.server(a, 'add-device', dict(deviceId=b['deviceId'], deviceName='Laptop'))
            (a['home'] / 'Disk/Fresh').mkdir(parents=True)
            # Word for word the ExecStart of the unit that the earlier install-auto wrote on the real server.
            result = run(['bash', '-c', 'bash "$HOME/.local/share/remote-disk/server-disk.sh" reconcile'], a['env'])
            self.assertEqual(json.loads(result.stdout)['deviceId'], a['deviceId'])
            self.assertEqual({d['deviceID'] for d in t.folder(a, 'Fresh')['devices']}, {a['deviceId'], b['deviceId']})

    def test_one_broken_folder_neither_stops_discovery_nor_registration(self):
        with Stand(2) as t:
            a, b = t.sides
            disk = a['home'] / 'Disk'
            (disk / 'A_dir_ignore/.stignore').mkdir(parents=True)  # OSError: .stignore is a directory
            (disk / 'B_link_ignore').mkdir()
            (disk / 'B_link_ignore/rules.txt').write_text('shared-rules\n')
            (disk / 'B_link_ignore/.stignore').symlink_to('rules.txt')  # ValueError: links are refused
            (disk / 'C_ok').mkdir()
            for action, data in (('bootstrap', None), ('add-device', dict(deviceId=b['deviceId'], deviceName='Laptop'))):
                with self.subTest(action=action):
                    result = t.server(a, action, data, ok=False)
                    self.assertEqual(result.returncode, 0, result.stderr.decode())
                    self.assertEqual(json.loads(result.stdout), {} if data else
                                     dict(deviceId=a['deviceId'], listen=a['listen']))
                    error = result.stderr.decode()
                    self.assertIn('RemoteDisk: A_dir_ignore: ', error)
                    self.assertIn('RemoteDisk: B_link_ignore: ', error)
                    self.assertNotIn('C_ok', error)
            self.assertEqual({f['id'] for f in t.api(a, 'config/folders')}, {'C_ok'})
            self.assertEqual({d['deviceID'] for d in t.folder(a, 'C_ok')['devices']}, {a['deviceId'], b['deviceId']})
            # The broken folders stay exactly as the user left them.
            self.assertTrue((disk / 'A_dir_ignore/.stignore').is_dir())
            self.assertEqual(os.readlink(disk / 'B_link_ignore/.stignore'), 'rules.txt')
            self.assertFalse((disk / 'B_link_ignore/.stignore-remoteagents').exists())

    def test_every_error_class_stays_inside_its_folder(self):
        errors = {'ValueError': ValueError('Недопустимое имя'),
                  'OSError': PermissionError(13, 'Permission denied'),
                  'REST': urllib.error.URLError('connection refused'),
                  'SubprocessError': subprocess.TimeoutExpired(['git'], 5)}
        with tempfile.TemporaryDirectory() as tmp:
            for name in 'ABC':
                (Path(tmp) / 'Disk' / name).mkdir(parents=True)
            for label, error in errors.items():
                with self.subTest(error=label), server_helpers(tmp) as ns:
                    def ignores(path, write=True):
                        if path.name == 'B':
                            raise error
                    ns['ignores'] = ignores
                    ns['exclude_git'] = lambda path: None
                    rest, stderr = FakeRest(), io.StringIO()
                    with contextlib.redirect_stderr(stderr):
                        ns['reconcile'](rest, 'SERVER')
                    self.assertEqual(rest.puts, ['A', 'C'])
                    self.assertRegex(stderr.getvalue(), r'^RemoteDisk: B: .+\n$')

    def test_git_trouble_never_blocks_sharing(self):
        troubles = {'git timeout': ('git', subprocess.TimeoutExpired(['git'], 5)),
                    'git is missing': ('git', FileNotFoundError(2, 'No such file or directory', 'git')),
                    'linked exclude file': ('exclude_git', ValueError('Символические ссылки запрещены'))}
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / 'Disk/Repo').mkdir(parents=True)
            for label, (name, error) in troubles.items():
                with self.subTest(trouble=label), server_helpers(tmp) as ns:
                    ns['ignores'] = lambda path, write=True: None
                    ns[name] = raiser(error)
                    rest, stderr = FakeRest(), io.StringIO()
                    with contextlib.redirect_stderr(stderr):
                        ns['reconcile'](rest, 'SERVER')
                    # Git exclusions are cosmetics: the folder is still offered, the cause is reported.
                    self.assertEqual(rest.puts, ['Repo'])
                    self.assertRegex(stderr.getvalue(), r'^RemoteDisk: Repo: .+\n$')

    def test_registration_survives_a_failing_discovery(self):
        with Stand(2) as t:
            a, b = t.sides
            elsewhere = a['home'] / 'elsewhere'
            elsewhere.mkdir()
            (a['home'] / 'Disk').symlink_to(elsewhere, target_is_directory=True)
            result = t.server(a, 'add-device', dict(deviceId=b['deviceId'], deviceName='Laptop'), ok=False)
            self.assertEqual((result.returncode, json.loads(result.stdout)), (0, {}), result.stderr.decode())
            self.assertIn('Символические ссылки запрещены', result.stderr.decode())
            self.assertIn(b['deviceId'], {d['deviceID'] for d in t.api(a, 'config/devices')})
            # Without a device to keep, bootstrap still reports the cause as a failure.
            broken = t.server(a, 'bootstrap', ok=False)
            self.assertEqual(broken.returncode, 1)
            self.assertIn('Символические ссылки запрещены', broken.stderr.decode())

    def test_script_knows_exactly_our_four_previous_templates(self):
        old = old_templates()
        self.assertEqual(len(old), 4)
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            self.assertEqual(set(ns['PREVIOUS_TEMPLATES']), {hashlib.sha256(b).hexdigest() for b in old.values()})

    def test_user_ignore_keeps_its_mode_and_only_our_old_templates_are_replaced(self):
        old = old_templates()
        include = b'#include .stignore-remoteagents\n'
        template = (HERE / 'stignore.txt').read_bytes()
        latest = old['f79b03f']
        with Stand(1) as t:
            side = t.sides[0]
            disk = side['home'] / 'Disk'

            def seed(name, content, mode, file='.stignore'):
                (disk / name).mkdir(parents=True)
                (disk / name / file).write_bytes(content)
                os.chmod(disk / name / file, mode)

            def mode(name, file='.stignore'):
                return stat.S_IMODE((disk / name / file).stat().st_mode)

            seed('UserRules', b'my-rules\n', 0o664)
            for label, content in old.items():
                seed('Old-' + label, content, 0o640)
            # Anything that is not byte-for-byte one of our templates belongs to the user.
            seed('OldPlusUser', latest + b'my-extra.txt\n', 0o600)
            seed('OldCRLF', latest.replace(b'\n', b'\r\n'), 0o600)
            seed('OldBOM', b'\xef\xbb\xbf' + latest, 0o600)
            seed('Managed', b'stale\n', 0o644, '.stignore-remoteagents')
            result = t.server(side, 'bootstrap', ok=False)
            self.assertEqual((result.returncode, result.stderr), (0, b''))
            self.assertEqual((disk / 'UserRules/.stignore').read_bytes(), b'my-rules\n' + include)
            self.assertEqual(mode('UserRules'), 0o664)
            for label in old:
                with self.subTest(replaced=label):
                    name = 'Old-' + label
                    self.assertEqual((disk / name / '.stignore').read_bytes(), include)
                    self.assertEqual(mode(name), 0o640)
                    self.assertEqual((disk / name / '.stignore-remoteagents').read_bytes(), template)
                    rules = t.api(side, 'db/ignores?folder=' + name)
                    self.assertEqual((rules['ignore'], rules['error']), (['#include .stignore-remoteagents'], None))
                    self.assertIn('(?i)/.stignore-remoteagents', rules['expanded'])
            self.assertEqual((disk / 'OldPlusUser/.stignore').read_bytes(), latest + b'my-extra.txt\n' + include)
            self.assertEqual((disk / 'OldCRLF/.stignore').read_bytes(),
                             latest.replace(b'\n', b'\r\n') + include.replace(b'\n', b'\r\n'))
            self.assertEqual((disk / 'OldBOM/.stignore').read_bytes(), b'\xef\xbb\xbf' + latest + include)
            self.assertEqual({mode(n) for n in ('OldPlusUser', 'OldCRLF', 'OldBOM')}, {0o600})
            self.assertEqual((disk / 'Managed/.stignore-remoteagents').read_bytes(), template)
            self.assertEqual(mode('Managed', '.stignore-remoteagents'), 0o644)
            # A repeated run changes nothing: neither bytes, nor modification times, nor modes.
            files = sorted(disk.glob('*/.stignore*'))
            before = [(p, p.read_bytes(), p.stat().st_mtime_ns, stat.S_IMODE(p.stat().st_mode)) for p in files]
            t.server(side, 'bootstrap')
            self.assertEqual([(p, p.read_bytes(), p.stat().st_mtime_ns, stat.S_IMODE(p.stat().st_mode)) for p in files],
                             before)

    def test_slow_folder_updates_do_not_fail_registration(self):
        with Stand(2) as t:
            a, b = t.sides
            (a['home'] / 'Disk/Slow').mkdir(parents=True)
            t.server(a, 'bootstrap')
            # A loaded server needs seconds to apply one folder: longer than the old 3 s limit, far below the new one.
            with SlowFolderWrites(int(a['gui']), delay=4) as proxy:
                ports = a['state'] / 'ports.json'
                ports.write_text(json.dumps(dict(json.loads(ports.read_text()), gui=proxy.port)))
                started = time.monotonic()
                t.server(a, 'add-device', dict(deviceId=b['deviceId'], deviceName='Laptop'))
                self.assertGreaterEqual(time.monotonic() - started, 4)
                self.assertEqual(proxy.held, 1)
            self.assertEqual({d['deviceID'] for d in t.folder(a, 'Slow')['devices']}, {a['deviceId'], b['deviceId']})


if __name__ == '__main__':
    if len(sys.argv) == 2 and not sys.argv[1].startswith('-'):
        os.environ['SYNCTHING_ARCHIVE'] = sys.argv.pop()
    unittest.main()
