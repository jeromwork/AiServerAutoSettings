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
import socket
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
import json,os,sys
from pathlib import Path
if os.environ.get('FAIL_SYSTEMD')=='1' or (os.environ.get('FAIL_SYSTEMD_ENABLE')=='1' and 'enable' in sys.argv):sys.exit(1)
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

    def offer(self, side, server, folder_id, label):
        """A Windows-like explicit upload through local REST inside its disposable Disk."""
        source = side['home'] / 'Disk' / folder_id
        source.mkdir(parents=True)
        (source / 'source.txt').write_text(folder_id)
        with server_helpers(side['home']) as ns:
            ns['ignores'](source)
        folder = self.api(side, 'config/defaults/folder')
        folder.update(id=folder_id, label=label, path=str(source), type='sendreceive',
                      fsWatcherEnabled=True, fsWatcherDelayS=2,
                      devices=[dict(deviceID=s['deviceId']) for s in (side, server)])
        self.api(side, 'config/folders/' + urllib.parse.quote(folder_id, safe=''), 'PUT', folder)
        return source

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
        if (method, route) == ('GET', 'cluster/pending/folders'):
            return {}
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


class TunnelProxy:
    """Туннель между компьютером и сервером (sing-box): серверный Syncthing видит все соединения как 127.0.0.1:<порт>.
    cut() — смена сети у компьютера: его сокеты закрываются, а серверные остаются открытыми и молчат, потому что туннель
    об обрыве не узнал. Новые соединения после cut() проходят как обычно."""
    def __init__(self, upstream_port):
        self.upstream_port = upstream_port
        self.accepted = 0
        self.pairs = []
        self.held = []  # серверные сокеты после cut(): ссылка нужна, иначе сборщик мусора закроет их
        self.lock = threading.Lock()
        self.listener = socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(16)
        self.listener.settimeout(.2)
        self.port = self.listener.getsockname()[1]
        self.closed = False
        self.thread = threading.Thread(target=self.accept_loop, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.closed = True
        self.thread.join(5)
        self.listener.close()
        with self.lock:
            pairs, self.pairs = self.pairs, []
        for pair in pairs:
            pair['cut'] = True
            self.held.append(pair['client'])
            self.held.append(pair['upstream'])
        for sock in self.held:
            with contextlib.suppress(OSError):
                sock.close()

    def accept_loop(self):
        while not self.closed:
            try:
                client, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            client.settimeout(None)
            try:
                upstream = socket.create_connection(('127.0.0.1', self.upstream_port), timeout=5)
            except OSError:
                client.close()
                continue
            upstream.settimeout(None)
            pair = dict(client=client, upstream=upstream, cut=False)
            with self.lock:
                self.pairs.append(pair)
                self.accepted += 1
            for source, target in (('client', 'upstream'), ('upstream', 'client')):
                threading.Thread(target=self.pump, args=(pair, source, target), daemon=True).start()

    @staticmethod
    def pump(pair, source, target):
        while True:
            try:
                data = pair[source].recv(65536)
            except OSError:
                data = b''
            if pair['cut']:
                return  # серверный сокет остаётся открытым и непрочитанным
            try:
                if data:
                    pair[target].sendall(data)
                else:
                    pair[target].shutdown(socket.SHUT_WR)
                    return
            except OSError:
                return

    def cut(self):
        with self.lock:
            pairs, self.pairs = self.pairs, []
        for pair in pairs:
            pair['cut'] = True
            self.held.append(pair['upstream'])
            with contextlib.suppress(OSError):
                pair['client'].shutdown(socket.SHUT_RDWR)
            pair['client'].close()
        return len(pairs)


class FailingRoute:
    """Reverse proxy перед REST Syncthing: GET маршрута с заданным началом отвечает 500, остальное проходит."""
    def __init__(self, target_port, prefix):
        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.0'

            def forward(self):
                length = int(self.headers.get('Content-Length') or 0)
                body = self.rfile.read(length) if length else None
                if self.command == 'GET' and self.path.startswith('/rest/' + prefix):
                    self.send_response(500)
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
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


class FakeClock:
    """Часы, которые двигает только sleep: ожидания в тестах не тратят реального времени и считаются точно."""
    def __init__(self, now=0.0):
        self.now = now

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class FakeConnections:
    """Из REST Syncthing — только то, что трогает watch_connections: счётчики соединений устройств и их пауза."""
    def __init__(self):
        self.devices = {}
        self.calls = []
        self.resume_failures = []  # исключения, которые resume бросит по очереди
        self.pause_closes = True   # False — движок «не закрыл» соединения на паузе
        self.reads = 0             # сколько раз прочитаны соединения; on_read(номер) срабатывает перед ответом
        self.on_read = None

    def add(self, device_id, name, *inbound):
        """Устройство с соединениями, получившими столько байт; без счётчиков — не подключено."""
        self.devices[device_id] = dict(name=name, connected=bool(inbound), paused=False, conns=[
            ['127.0.0.1:%d' % (40000 + i), '2026-11-15T07:00:00+01:00', n] for i, n in enumerate(inbound)])

    def posts(self):
        return [call for call in self.calls if call[0] == 'POST']

    def __call__(self, route, method='GET', body=None):
        self.calls.append((method, route))
        if (method, route) == ('GET', 'system/connections'):
            self.reads += 1
            if self.on_read:
                self.on_read(self.reads)
            connections = {}
            for device_id, d in self.devices.items():
                infos = [dict(address=a, startedAt=at, inBytesTotal=n) for a, at, n in d['conns']] if d['connected'] else [
                    dict(address='', startedAt='0001-01-01T00:00:00Z', inBytesTotal=0)]
                connections[device_id] = dict(connected=d['connected'], paused=d['paused'], primary=infos[0])
                if infos[1:]:
                    connections[device_id]['secondary'] = infos[1:]
            return dict(connections=connections, total={})
        verb, _, query = route.partition('?device=')
        device = self.devices.get(urllib.parse.unquote(query))
        if method == 'POST' and verb == 'system/pause' and device:
            device.update(paused=True, connected=device['connected'] and not self.pause_closes)
            return {}
        if method == 'POST' and verb == 'system/resume' and device:
            if self.resume_failures:
                raise self.resume_failures.pop(0)
            device['paused'] = False
            return {}
        if method == 'GET' and route.startswith('config/devices/'):
            return dict(deviceID=route.rsplit('/', 1)[1], name=self.devices[route.rsplit('/', 1)[1]]['name'])
        raise AssertionError((method, route))


def script_constant(name):
    with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
        return ns[name]


def device_connections(t, server, peer):
    """Соединения peer глазами server: пусто, если не подключён; иначе primary и secondary."""
    info = t.api(server, 'system/connections')['connections'][peer['deviceId']]
    return [info['primary']] + (info.get('secondary') or []) if info['connected'] else []


def settled(connections, count=3):
    # У только что принятого соединения startedAt какое-то время нулевой: ждём настоящих значений.
    return len(connections) == count and not any(c['startedAt'].startswith('0001') for c in connections)


def inbound_bytes(t, server, peer):
    return t.api(server, 'system/connections')['connections'][peer['deviceId']]['inBytesTotal']


def link_through_tunnel(t, server, computer, proxy, interval=3):
    """Как вживую: сервер знает компьютер без адреса и сам не звонит, компьютер ходит к серверу через туннель."""
    t.server(server, 'add-device', dict(deviceId=computer['deviceId'], deviceName='Computer'))
    t.server(computer, 'add-device', dict(deviceId=server['deviceId'], deviceName='Server'))
    t.api(computer, 'config/devices/' + server['deviceId'], 'PATCH', dict(addresses=[f'tcp://127.0.0.1:{proxy.port}']))
    t.api(computer, 'config/options', 'PATCH', dict(reconnectionIntervalS=interval))


def bootstrap_tick(t, side):
    """Один запуск таймера: возвращает stderr (строки лечения и диагностики), код возврата обязан быть 0."""
    result = t.server(side, 'bootstrap', ok=False)
    if result.returncode:
        raise AssertionError(result.stderr.decode())
    return result.stderr.decode()


def age_watch(side, seconds):
    """Сдвигает начало молчания назад: вместо ожидания STALE_AFTER_S проверяем решение сервера при давнем молчании."""
    path = side['state'] / 'connection-watch.json'
    state = json.loads(path.read_text())
    for entry in state['devices'].values():
        entry['since'] -= seconds
    path.write_text(json.dumps(state))


def make_disk(home):
    disk = home / 'Disk'
    disk.mkdir(exist_ok=True)
    (disk / '.mounted').touch()
    return disk


def make_project(path):
    path.mkdir(parents=True, exist_ok=True)
    run(['git', 'init', '-q', path])
    return path


class ContractRest(FakeRest):
    def __init__(self, folders=(), offers=None):
        super().__init__()
        self.folders = {f['id']: dict(f) for f in folders}
        self.offers = offers or {}
        self.deletes = []

    def __call__(self, route, method='GET', body=None):
        if route == 'config/folders':
            return [dict(f) for f in self.folders.values()]
        if route == 'cluster/pending/folders':
            return self.offers
        if route.startswith('config/folders/'):
            identity = urllib.parse.unquote(route.rsplit('/', 1)[1])
            if method == 'GET':
                return dict(self.folders[identity])
            if method == 'DELETE':
                self.deletes.append(identity)
                self.folders.pop(identity, None)
                return {}
            if method == 'PUT':
                self.puts.append(identity)
                self.folders[identity] = dict(body)
                return {}
        return super().__call__(route, method, body)


def upload_id(seed):
    return 'rd-upload-v1-' + hashlib.md5(seed.encode()).hexdigest()


def upload_offer(label, device='PEER'):
    return {'offeredBy': {device: {'label': label}}}


class ContractTests(unittest.TestCase):
    def test_git_top_level_and_valid_gitdir_are_required(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            disk = Path(tmp) / 'Disk'
            make_project(disk / 'Good')
            (disk / 'Plain').mkdir()
            (disk / 'Broken').mkdir()
            (disk / 'Broken/.git').write_text('gitdir: /missing/gitdir')
            # An enclosing repository must never turn a plain child into a project.
            run(['git', 'init', '-q', disk])
            rest = ContractRest()
            with contextlib.redirect_stderr(io.StringIO()):
                ns['reconcile'](rest, 'SERVER')
            self.assertEqual(rest.puts, ['Good'])
            events = [json.loads(x) for x in (ns['s'] / 'project-journal.jsonl').read_text().splitlines()]
            self.assertTrue(any(e['outcome'] == 'refused' and e['projectID'] == 'Plain' for e in events))

    def test_only_upload_ids_are_admitted_and_git_is_initialized_once(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            make_project(Path(tmp) / 'Disk/Existing')
            good = upload_id('new')
            rest = ContractRest(offers={good: upload_offer('New'), 'Infraagent': upload_offer('Bad'),
                                       'PlainTest': upload_offer('Old'), 'rd-upload-v1-short': upload_offer('Short')})
            ns['reconcile'](rest, 'SERVER')
            self.assertEqual(set(rest.folders), {'Existing', good})
            path = Path(tmp) / 'Disk/New'
            self.assertEqual(run(['git', '-C', path, 'rev-list', '--count', 'HEAD']).stdout.strip(), b'1')
            self.assertEqual(run(['git', '-C', path, 'ls-tree', '-r', 'HEAD']).stdout, b'')
            (path / 'source.txt').write_text('ordinary uncommitted source')
            ns['reconcile'](rest, 'SERVER')
            self.assertEqual(run(['git', '-C', path, 'rev-list', '--count', 'HEAD']).stdout.strip(), b'1')
            events = [json.loads(x) for x in (ns['s'] / 'project-journal.jsonl').read_text().splitlines()]
            accepted = next(e for e in events if e['projectID'] == good and e['outcome'] == 'accepted')
            self.assertEqual(accepted['device'], 'PEER')
            self.assertEqual(accepted['source'], 'upload')
            self.assertEqual(accepted['reason'], 'без удалённого репозитория')
            self.assertTrue(all({'projectID', 'source', 'hostID', 'device', 'outcome', 'reason'} <= e.keys() for e in events))
            self.assertEqual({e['projectID'] for e in events if e['outcome'] == 'refused'},
                             {'Infraagent', 'PlainTest', 'rd-upload-v1-short'})

    def test_name_collision_and_invalid_labels_are_refused_without_sanitizing(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            disk = Path(tmp) / 'Disk'
            make_project(disk / 'Project')
            labels = ['project', 'CON', '../escape', 'Name\r\n', 'a..b', '', 'Я' * 121, 'a\u0301', 'COM¹']
            rest = ContractRest(offers={upload_id(str(i)): upload_offer(label) for i, label in enumerate(labels)})
            ns['reconcile'](rest, 'SERVER')
            self.assertEqual(rest.puts, ['Project'])
            self.assertEqual({p.name for p in disk.iterdir()}, {'Project'})
            self.assertIn('имя занято на сервере', (ns['s'] / 'project-journal.jsonl').read_text())

    def test_manual_unshare_tombstones_even_existing_path_and_never_returns(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            disk = Path(tmp) / 'Disk'
            make_project(disk / 'Project')
            rest = ContractRest()
            ns['reconcile'](rest, 'SERVER')
            rest.folders.clear()  # Manual DELETE in Syncthing, not through our script.
            rest.offers = {'Project': upload_offer('Project')}
            ns['reconcile'](rest, 'SERVER')
            ns['reconcile'](rest, 'SERVER')
            state = json.loads(ns['missing_watch'].read_text())
            self.assertIn('Project', state['removed'])
            self.assertEqual(rest.folders, {})
            self.assertTrue((disk / 'Project/.git').is_dir())

    def test_removed_upload_and_renamed_marker_never_reuse_tombstone(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            disk = Path(tmp) / 'Disk'
            make_project(disk / 'Existing')
            identity = upload_id('rename')
            rest = ContractRest(offers={identity: upload_offer('Upload')})
            ns['reconcile'](rest, 'SERVER')
            (disk / 'Upload').rename(disk / 'Renamed')
            ns['forget_missing'](rest, list(rest.folders.values()), disk, now=1000)
            ns['forget_missing'](rest, list(rest.folders.values()), disk, now=1030)
            ns['reconcile'](rest, 'SERVER')
            self.assertNotIn(identity, rest.folders)
            self.assertIn(identity, json.loads(ns['missing_watch'].read_text())['removed'])
            self.assertEqual(len([p for p in disk.iterdir() if p.is_dir()]), 2)

    def test_empty_missing_or_unreadable_root_has_no_mutations_or_mkdir(self):
        for mode in ('missing', 'empty', 'unreadable'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
                disk = Path(tmp) / 'Disk'
                if mode != 'missing':
                    disk.mkdir()
                if mode == 'unreadable':
                    (disk / 'sentinel').touch()
                    disk.chmod(0)
                identity = upload_id('unsafe-root')
                rest = ContractRest(offers={identity: upload_offer('New')})
                try:
                    ns['reconcile'](rest, 'SERVER')
                    self.assertEqual(rest.puts, [])
                    self.assertEqual(rest.deletes, [])
                finally:
                    if disk.exists():
                        disk.chmod(0o700)
                self.assertFalse((disk / 'New').exists())
                self.assertEqual(disk.exists(), mode != 'missing')

    def test_mandatory_ignores_precede_negations_and_cover_q8(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            path = make_project(Path(tmp) / 'Disk/Project')
            user = b'!.git\r\n!.env\r\n!vendor\r\n#include .stignore-remoteagents\r\n'
            (path / '.stignore').write_bytes(user)
            ns['ignores'](path)
            data = (path / '.stignore').read_bytes()
            self.assertTrue(data.startswith(b'#include .stignore-remoteagents\r\n'))
            self.assertEqual(data.count(b'#include .stignore-remoteagents'), 1)
            self.assertIn(b'!.git\r\n!.env\r\n!vendor\r\n', data)
            rules = (path / '.stignore-remoteagents').read_text()
            for rule in ('*.pem', '*.crt', '*.crt?', 'token*.json', '.venv', 'venv', '__pycache__', '*.sqlite*', '*.db*', '*.sql', '*.sql.gz'):
                self.assertIn('(?i)' + rule + '\n', rules)

    def test_versioning_is_migrated_for_existing_folders(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            path = make_project(Path(tmp) / 'Disk/Project')
            rest = ContractRest([dict(id='old-id', path=str(path), devices=[], versioning={}, paused=True)])
            ns['reconcile'](rest, 'SERVER')
            folder = rest.folders['old-id']
            self.assertEqual(folder['versioning']['type'], 'staggered')
            self.assertEqual(folder['versioning']['params']['maxAge'], '2592000')
            self.assertTrue(folder['paused'])
            before = len(rest.puts)
            ns['reconcile'](rest, 'SERVER')
            self.assertEqual(len(rest.puts), before)

    def test_guard_paused_ids_are_imported_before_any_discovery(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            path = make_project(Path(tmp) / 'Disk/Project')
            ns['s'].mkdir(parents=True)
            guard = ns['s'] / 'vanish-guard.json'
            guard.write_text(json.dumps({'paused': ['guard-id'], 'missing': {'other': 1}}))
            rest = ContractRest([dict(id='guard-id', path=str(path), devices=[], paused=True)])
            ns['reconcile'](rest, 'SERVER')
            self.assertEqual(rest.deletes, ['guard-id'])
            self.assertEqual(rest.puts, [])
            self.assertIn('guard-id', json.loads(ns['missing_watch'].read_text())['removed'])
            before = ns['missing_watch'].read_bytes()
            ns['reconcile'](rest, 'SERVER')
            self.assertEqual(ns['missing_watch'].read_bytes(), before)
            self.assertTrue(guard.exists())  # Original is retained for rollback.

    def test_broken_durable_tombstones_fail_closed(self):
        for content in ('not-json', '[]', '{"removed": []}', '{"removed": {"retired": 3}}'):
            with self.subTest(content=content), tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
                make_project(Path(tmp) / 'Disk/Project')
                ns['s'].mkdir(parents=True)
                ns['missing_watch'].write_text(content)
                rest = ContractRest(offers={upload_id('unsafe'): upload_offer('New')})
                with contextlib.redirect_stderr(io.StringIO()):
                    ns['reconcile'](rest, 'SERVER')
                self.assertEqual(rest.puts, [])
                self.assertEqual(rest.deletes, [])
                self.assertEqual(ns['missing_watch'].read_text(), content)

    def test_existing_nongit_registration_is_retired_without_deleting_data(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            path = Path(tmp) / 'Disk/Plain'
            path.mkdir(parents=True)
            (path / 'keep.txt').write_text('must survive')
            rest = ContractRest([dict(id='old', path=str(path), devices=[])])
            ns['reconcile'](rest, 'SERVER')
            self.assertEqual(rest.deletes, ['old'])
            self.assertEqual(rest.puts, [])
            self.assertEqual((path / 'keep.txt').read_text(), 'must survive')
            self.assertIn('old', json.loads(ns['missing_watch'].read_text())['removed'])

    def test_case_colliding_server_names_are_both_refused(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            make_project(Path(tmp) / 'Disk/Project')
            make_project(Path(tmp) / 'Disk/PROJECT')
            rest = ContractRest()
            ns['reconcile'](rest, 'SERVER')
            self.assertEqual(rest.puts, [])

    def test_origin_status_never_logs_url_or_file_contents(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            path = make_project(Path(tmp) / 'Disk/Project')
            run(['git', '-C', path, 'remote', 'add', 'origin', 'https://user:synthetic-password@example.invalid/repo'])
            (path / '.env').write_text('SYNTHETIC_TOKEN=do-not-log')
            rest = ContractRest()
            ns['reconcile'](rest, 'SERVER')
            journal = (ns['s'] / 'project-journal.jsonl').read_text()
            self.assertNotIn('synthetic-password', journal)
            self.assertNotIn('do-not-log', journal)
            self.assertIn('origin настроен', journal)
            before = (ns['s'] / 'project-journal.jsonl').stat().st_size
            ns['reconcile'](rest, 'SERVER')
            self.assertEqual((ns['s'] / 'project-journal.jsonl').stat().st_size, before)

    def test_failed_guard_delete_and_missing_root_preserve_imported_tombstones(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            ns['s'].mkdir(parents=True)
            (ns['s'] / 'vanish-guard.json').write_text(json.dumps({'paused': {'retired': True}}))
            rest = ContractRest(offers={'retired': upload_offer('Old')})
            ns['reconcile'](rest, 'SERVER')
            self.assertIn('retired', json.loads(ns['missing_watch'].read_text())['removed'])
            self.assertFalse((Path(tmp) / 'Disk').exists())

    def test_guard_delete_failure_retries_without_republishing(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            path = make_project(Path(tmp) / 'Disk/Project')
            ns['s'].mkdir(parents=True)
            (ns['s'] / 'vanish-guard.json').write_text(json.dumps({'paused': ['retired']}))
            rest = ContractRest([dict(id='retired', path=str(path), devices=[], paused=True)])
            def failing(route, method='GET', body=None):
                if method == 'DELETE':
                    raise urllib.error.URLError('synthetic lost delete')
                return rest(route, method, body)
            with contextlib.redirect_stderr(io.StringIO()):
                ns['reconcile'](failing, 'SERVER')
            self.assertIn('retired', json.loads(ns['missing_watch'].read_text())['removed'])
            self.assertEqual(rest.puts, [])
            ns['reconcile'](rest, 'SERVER')
            self.assertEqual(rest.folders, {})
            self.assertTrue((path / '.git').exists())

    def test_manual_path_change_retires_old_id_and_keeps_new_path_data(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            disk = Path(tmp) / 'Disk'
            path = make_project(disk / 'Project')
            rest = ContractRest()
            ns['reconcile'](rest, 'SERVER')
            path.rename(disk / 'Renamed')
            rest.folders['Project']['path'] = str(disk / 'Renamed')
            ns['reconcile'](rest, 'SERVER')
            self.assertIn('Project', json.loads(ns['missing_watch'].read_text())['removed'])
            self.assertNotIn('Project', rest.folders)
            self.assertTrue((disk / 'Renamed/.git').exists())

    def test_manual_unshare_is_remembered_even_when_disk_becomes_empty(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            path = make_project(Path(tmp) / 'Disk/Project')
            rest = ContractRest()
            ns['reconcile'](rest, 'SERVER')
            path.rename(Path(tmp) / 'saved-project')
            rest.folders.clear()
            ns['reconcile'](rest, 'SERVER')
            self.assertIn('Project', json.loads(ns['missing_watch'].read_text())['removed'])
            self.assertEqual(rest.deletes, [])

    def test_two_uploads_with_same_free_label_accept_exactly_one(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            make_disk(Path(tmp))
            identities = [upload_id('one'), upload_id('two')]
            rest = ContractRest(offers={i: upload_offer('New') for i in identities})
            ns['reconcile'](rest, 'SERVER')
            self.assertEqual(len(rest.folders), 1)
            self.assertEqual({p.name for p in (Path(tmp) / 'Disk').iterdir()}, {'.mounted', 'New'})
            self.assertTrue((Path(tmp) / 'Disk/New/.git').is_dir())
            self.assertIn('имя занято на сервере', (ns['s'] / 'project-journal.jsonl').read_text())

    def test_gitdir_symlink_is_not_a_valid_project(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            disk = Path(tmp) / 'Disk'
            make_project(disk / 'Good')
            (disk / 'Linked').mkdir()
            (disk / 'Linked/.git').symlink_to(disk / 'Good/.git', target_is_directory=True)
            rest = ContractRest()
            with contextlib.redirect_stderr(io.StringIO()):
                ns['reconcile'](rest, 'SERVER')
            self.assertEqual(rest.puts, ['Good'])


    def test_guard_updates_are_imported_incrementally_and_never_unretire(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            make_disk(Path(tmp))
            ns['s'].mkdir(parents=True)
            guard = ns['s'] / 'vanish-guard.json'
            guard.write_text(json.dumps({'paused': ['first']}))
            rest = ContractRest()
            ns['reconcile'](rest, 'SERVER')
            guard.write_text(json.dumps({'paused': ['second']}))
            ns['reconcile'](rest, 'SERVER')
            self.assertEqual(set(json.loads(ns['missing_watch'].read_text())['removed']), {'first', 'second'})

    def test_journal_failure_blocks_new_publication(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            make_project(Path(tmp) / 'Disk/Project')
            rest = ContractRest()
            ns['record'] = raiser(PermissionError('synthetic journal unavailable'))
            with self.assertRaises(PermissionError):
                ns['reconcile'](rest, 'SERVER')
            self.assertEqual(rest.puts, [])

    def test_legacy_refusal_stderr_is_single_line_and_deduplicated(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            make_disk(Path(tmp))
            rest = ContractRest(offers={'legacy\r\nforged': upload_offer('Old')})
            with contextlib.redirect_stderr(io.StringIO()) as first:
                ns['reconcile'](rest, 'SERVER')
            self.assertEqual(len(first.getvalue().splitlines()), 1)
            with contextlib.redirect_stderr(io.StringIO()) as repeated:
                ns['reconcile'](rest, 'SERVER')
            self.assertEqual(repeated.getvalue(), '')

    def test_existing_linked_gitdir_registration_is_retired(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            disk = Path(tmp) / 'Disk'
            make_project(disk / 'Good')
            path = disk / 'Linked'
            path.mkdir()
            (path / '.git').symlink_to(disk / 'Good/.git', target_is_directory=True)
            rest = ContractRest([dict(id='linked-id', path=str(path), devices=[])])
            with contextlib.redirect_stderr(io.StringIO()):
                ns['reconcile'](rest, 'SERVER')
            self.assertIn('linked-id', rest.deletes)
            self.assertTrue((path / '.git').is_symlink())

    def test_unknown_guard_path_is_learned_without_manufacturing_new_identity(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            make_disk(Path(tmp))
            ns['s'].mkdir(parents=True)
            (ns['s'] / 'vanish-guard.json').write_text(json.dumps({'paused': ['retired']}))
            rest = ContractRest()
            ns['reconcile'](rest, 'SERVER')
            path = make_project(Path(tmp) / 'Disk/Project')
            rest.folders['retired'] = dict(id='retired', path=str(path), devices=[])
            ns['reconcile'](rest, 'SERVER')
            self.assertEqual(rest.folders, {})
            self.assertEqual(json.loads(ns['missing_watch'].read_text())['removed']['retired'], str(path))

    def test_initial_commit_is_empty_even_after_interrupted_init_with_staged_data(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            path = make_project(Path(tmp) / 'Disk/Reserved')
            (path / '.env').write_text('SYNTHETIC_LOCAL_ONLY=preserve-index')
            run(['git', '-C', path, 'add', '.env'])
            before = run(['git', '-C', path, 'ls-files', '--stage']).stdout
            ns['s'].mkdir(parents=True)
            ns['initialize_project'](path)
            self.assertEqual(run(['git', '-C', path, 'ls-tree', '-r', 'HEAD']).stdout, b'')
            self.assertEqual(run(['git', '-C', path, 'ls-files', '--stage']).stdout, before)
            self.assertEqual((path / '.env').read_text(), 'SYNTHETIC_LOCAL_ONLY=preserve-index')

    def test_tombstone_directory_is_synced_before_rest_delete(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            disk = make_disk(Path(tmp))
            path = make_project(disk / 'Project')
            rest = ContractRest()
            ns['reconcile'](rest, 'SERVER')
            shutil.rmtree(path)
            ns['forget_missing'](rest, list(rest.folders.values()), disk, now=1000)
            synced = set()
            real_sync = os.fsync
            def fsync(fd):
                real_sync(fd)
                if stat.S_ISDIR(os.fstat(fd).st_mode) and ns['missing_watch'].exists():
                    synced.update(json.loads(ns['missing_watch'].read_text()).get('removed', {}))
            def deleting(route, method='GET', body=None):
                if method == 'DELETE':
                    self.assertIn('Project', synced, 'durable tombstone must precede REST DELETE')
                return rest(route, method, body)
            with mock.patch.object(ns['os'], 'fsync', side_effect=fsync), contextlib.redirect_stderr(io.StringIO()):
                ns['forget_missing'](deleting, list(rest.folders.values()), disk, now=1030)



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
                make_project(path)
                (path / '.stignore').write_bytes(original)
            t.server(side, 'bootstrap')
            for name, original in cases.items():
                with self.subTest(name=name):
                    path = side['home'] / 'Disk' / name
                    policy = (path / '.stignore').read_bytes()
                    self.assertTrue(policy.startswith(b'\xef\xbb\xbf#include' if original.startswith(b'\xef\xbb\xbf') else b'#include'))
                    self.assertIn(original.removeprefix(b'\xef\xbb\xbf').replace(b'#include .stignore-remoteagents\n', b''), policy)
                    self.assertEqual(policy.count(b'#include .stignore-remoteagents'), 1)
                    t.server(side, 'bootstrap')
                    self.assertEqual((path / '.stignore').read_bytes(), policy)
                    self.assertEqual(t.folder(side, name)['id'], name)

    def test_registration_offers_every_folder_and_is_idempotent(self):
        with Stand(3) as t:
            a, b, c = t.sides
            for name in ('Existing', 'Проект 1'):
                folder = a['home'] / 'Disk' / name
                make_project(folder)
                (folder / 'keep.txt').write_text(name)
            t.server(a, 'add-device', dict(deviceId=b['deviceId'], deviceName='Laptop'), stdin=True)
            device = next(d for d in t.api(a, 'config/devices') if d['deviceID'] == b['deviceId'])
            self.assertEqual(device['name'], 'Laptop')
            self.assertFalse(device['autoAcceptFolders'])
            for name in ('Existing', 'Проект 1'):
                folder = t.folder(a, name)
                self.assertEqual((folder['id'], folder['type']), (name, 'sendreceive'))
                self.assertEqual(folder['fsWatcherDelayS'], 2)
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
            make_project(a['home'] / 'Disk/New')
            t.server(a, 'bootstrap')  # The exact entry point used by cron and systemd.
            for name in ('Existing', 'Проект 1', 'New'):
                self.assertEqual({d['deviceID'] for d in t.folder(a, name)['devices']},
                                 {s['deviceId'] for s in t.sides})
                self.assertEqual(t.folder(a, name)['type'], 'sendreceive')
                self.assertEqual(t.folder(a, name)['fsWatcherDelayS'], 2)
            self.assertTrue(t.folder(a, 'Existing')['paused'])
            self.assertEqual((a['home'] / 'Disk/Existing/keep.txt').read_text(), 'Existing')

    def test_foreign_ignores_survive_updates_and_rules_work_in_real_engine(self):
        with Stand() as t:
            a, b = t.sides
            source = a['home'] / 'Disk/Shared'
            source.mkdir(parents=True)
            run(['git', 'init', '-q', source])
            original = b'// custom user rules\r\ncustom.txt\r\n!.git\r\n!.env\r\n!vendor\r\n!**\r\n'
            (source / '.stignore').write_bytes(original)
            t.register(a, b)
            self.assertTrue((source / '.stignore').read_bytes().endswith(original))
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
            self.assertEqual(t.api(b, 'config/folders'), [])  # Engine autoAcceptFolders stays disabled; reconcile accepts.
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
            allowed = {'log/source.py': 'log source', 'db/schema.migration': 'SQL source', 'source.txt': 'source'}
            denied = ('custom.txt', 'updated-only.txt', '.env', 'identity.key', 'node_modules/a.js', 'build/output',
                      'key.pem', 'cert.crt', 'cert.crtx', 'token-local.json', '.venv/bin/python',
                      'venv/a', '__pycache__/a.pyc', 'local.sqlite-wal', 'local.db3', 'local.sql.gz', 'db/schema.sql')
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

    def test_watcher_delay_is_migrated_idempotently_by_every_server_entry_point(self):
        with Stand(2) as t:
            a, b = t.sides
            make_project(a['home'] / 'Disk/Existing')
            t.register(a, b)
            # A folder outside Disk belongs to the user, not to server discovery.
            external = t.api(a, 'config/defaults/folder')
            external.update(id='external', path=str(a['home'] / 'Elsewhere'),
                            paused=True, fsWatcherDelayS=17)
            t.api(a, 'config/folders/external', 'PUT', external)
            outside = t.folder(a, 'external')
            for action in ('bootstrap', 'reconcile', 'add-device'):
                with self.subTest(action=action):
                    t.api(a, 'config/folders/Existing', 'PATCH', dict(
                        fsWatcherDelayS=10, paused=True, rescanIntervalS=777,
                        fsWatcherEnabled=False))
                    before = t.folder(a, 'Existing')
                    data = dict(deviceId=b['deviceId'], deviceName=b['home'].name) if action == 'add-device' else None
                    t.server(a, action, data)
                    # Managed Disk folders always watch changes: the two-second delay is useless without the watcher.
                    self.assertEqual(t.folder(a, 'Existing'), dict(before, fsWatcherDelayS=2, fsWatcherEnabled=True))
                    self.assertEqual(t.folder(a, 'external'), outside)
                    # Count actual REST folder PUTs through a proxy: a repeat has none.
                    ports_file = a['state'] / 'ports.json'
                    ports = json.loads(ports_file.read_text())
                    with SlowFolderWrites(a['gui'], 0) as proxy:
                        ports_file.write_text(json.dumps(dict(ports, gui=proxy.port)))
                        try:
                            t.server(a, action, data)
                        finally:
                            ports_file.write_text(json.dumps(ports))
                        self.assertEqual(proxy.held, 0)
                    # Managed Disk folders always watch changes: the two-second delay is useless without the watcher.
                    self.assertEqual(t.folder(a, 'Existing'), dict(before, fsWatcherDelayS=2, fsWatcherEnabled=True))

    def test_powershell_watcher_migration_acceptance_and_native_defaults_with_real_syncthing(self):
        pwsh = os.environ.get('PWSH') or str(Path.home() / '.cache/pwsh-test/pwsh')
        with Stand(2) as t:
            a, b = t.sides
            make_project(a['home'] / 'Disk/Offered')
            t.register(a, b)
            t.register(b, a)
            wait(lambda: 'Offered' in t.api(b, 'cluster/pending/folders'), 'folder offered for PowerShell acceptance')
            folder = t.api(b, 'config/defaults/folder')
            folder.update(id='user папка', path=str(b['home'] / 'Custom'), paused=True,
                          type='receiveonly', fsWatcherDelayS=10, maxConflicts=17,
                          rescanIntervalS=777, fsWatcherEnabled=False)
            t.api(b, 'config/folders', 'POST', folder)
            route = 'config/folders/' + urllib.parse.quote(folder['id'], safe='')
            before = t.api(b, route)
            defaults = t.api(b, 'config/defaults/folder')
            script = t.root / 'local-settings.ps1'
            common = str(HERE / 'Disk.Common.ps1').replace("'", "''")
            script.write_text(". '" + common + "'\n" + """
$request=[Console]::In.ReadToEnd()|ConvertFrom-Json
$script:Gui=$request.gui;$script:ApiKey=$request.key;$script:DiskHome=$request.home
Accept-DiskFolders @(@{id='Offered';path=$request.path}) $request.peer $request.local
Set-DiskWatcherDelay
""")
            request = dict(gui='127.0.0.1:' + str(b['gui']), key=b['key'],
                           path=str(b['home'] / 'Disk/Accepted'), home=str(b['home'] / 'RemoteDisk'), peer=a['deviceId'], local=b['deviceId'])
            encoded = (json.dumps(request, ensure_ascii=False) + '\r\n').encode()
            run([pwsh, '-NoProfile', '-NonInteractive', '-File', script],
                env={**os.environ, 'USERPROFILE': str(b['home'])}, stdin=encoded)
            self.assertEqual(t.api(b, route), dict(before, fsWatcherDelayS=2))
            self.assertEqual(t.folder(b, 'Offered')['fsWatcherDelayS'], 2)
            self.assertEqual(t.api(b, 'config/defaults/folder'), dict(defaults, fsWatcherDelayS=2))
            config = t.api(b, 'config')
            run([pwsh, '-NoProfile', '-NonInteractive', '-File', script],
                env={**os.environ, 'USERPROFILE': str(b['home'])}, stdin=encoded)
            self.assertEqual(t.api(b, 'config'), config)
            # Native/manual acceptance starts with the defaults, without our Accept-DiskFolders.
            native = t.api(b, 'config/defaults/folder')
            native.update(id='Native', path=str(b['home'] / 'Native'), paused=True)
            t.api(b, 'config/folders', 'POST', native)
            self.assertEqual(t.folder(b, 'Native')['fsWatcherDelayS'], 2)

    def test_existing_ids_and_settings_survive_discovery(self):
        with Stand() as t:
            a, b = t.sides
            project = a['home'] / 'Disk/Existing'
            make_project(project)
            (project / 'keep.txt').write_text('user content')
            t.server(a, 'bootstrap')
            folder = t.folder(a, 'Existing')
            t.api(a, 'config/folders/Existing', 'DELETE')
            folder.update(id='disk-legacy-id', paused=True, type='receiveonly', rescanIntervalS=777)
            folder.update(fsWatcherDelayS=10, fsWatcherEnabled=False)
            t.api(a, 'config/folders/disk-legacy-id', 'PUT', folder)
            t.register(a, b)
            current = t.folder(a, 'disk-legacy-id')
            self.assertEqual((current['type'], current['paused'], current['rescanIntervalS']), ('sendreceive', True, 777))
            self.assertEqual((current['fsWatcherEnabled'], current['fsWatcherDelayS']), (True, 2))
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
            make_project(disk / 'Valid')
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

    def test_bootstrap_installs_and_updates_two_second_timer_idempotently(self):
        with Stand(1) as t:
            side = t.sides[0]
            units = side['home'] / '.config/systemd/user'
            timer = units / 'remote-disk-folders.timer'
            service = units / 'remote-disk-folders.service'
            self.assertTrue(timer.exists(), 'normal bootstrap must install the timer')
            timer.write_text('[Timer]\nOnUnitInactiveSec=60\n')
            cron = side['home'] / 'fake-crontab'
            foreign = b'# keep user cron\n17 * * * * echo keep\n'
            cron.write_bytes(foreign + b'* * * * * bash "$HOME/.local/share/remote-disk/server-disk.sh" bootstrap >/dev/null 2>&1\n')
            t.server(side, 'bootstrap')
            self.assertIn('OnUnitInactiveSec=2\n', timer.read_text())
            self.assertIn('StandardOutput=null\n', service.read_text())
            self.assertIn('SyslogLevel=warning\n', service.read_text())
            self.assertIn('LogLevelMax=notice\n', service.read_text())
            self.assertEqual(cron.read_bytes(), foreign)
            before = [(p.read_bytes(), p.stat().st_mtime_ns) for p in (timer, service)]
            calls_before = (side['home'] / 'systemctl-calls').read_text().splitlines()
            t.server(side, 'bootstrap')
            self.assertEqual([(p.read_bytes(), p.stat().st_mtime_ns) for p in (timer, service)], before)
            new_calls = (side['home'] / 'systemctl-calls').read_text().splitlines()[len(calls_before):]
            self.assertFalse(any(set(json.loads(call)) & {'daemon-reload', 'enable', 'restart'} for call in new_calls))

    def test_timer_enable_failure_falls_back_to_cron_and_add_device_repairs_it(self):
        with Stand(2) as t:
            side, peer = t.sides
            stamp = side['state'] / 'auto-units.sha256'
            stamp.unlink()
            side['env']['FAIL_SYSTEMD_ENABLE'] = '1'
            t.server(side, 'bootstrap')
            self.assertFalse(stamp.exists(), 'failed enable must be retried, not cached as installed')
            cron = side['home'] / 'fake-crontab'
            self.assertIn(b'server-disk.sh" bootstrap', cron.read_bytes())
            side['env'].pop('FAIL_SYSTEMD_ENABLE')
            t.server(side, 'add-device', dict(deviceId=peer['deviceId']))
            self.assertTrue(stamp.exists())
            self.assertNotIn(b'server-disk.sh" bootstrap', cron.read_bytes())
            calls = [json.loads(line) for line in (side['home'] / 'systemctl-calls').read_text().splitlines()]
            self.assertGreaterEqual(calls.count(['--user', 'daemon-reload']), 3)
            self.assertIn(['--user', 'restart', 'remote-disk-folders.timer'], calls)

    def test_bootstrap_cron_and_install_auto_share_the_same_entry_point(self):
        with Stand(1) as t:
            side = t.sides[0]
            side['env']['FAIL_SYSTEMD'] = '1'
            foreign = b'# user cron\n17 * * * * echo keep\n'
            cron = side['home'] / 'fake-crontab'
            cron.write_bytes(foreign)
            for _ in range(2):
                self.assertEqual(t.server(side, 'bootstrap')['deviceId'], side['deviceId'])
            expected = b'* * * * * bash "$HOME/.local/share/remote-disk/server-disk.sh" bootstrap >/dev/null 2>&1\n'
            self.assertEqual(cron.read_bytes(), foreign + expected)
            side['env']['FAIL_CRONTAB'] = '1'
            self.assertEqual(t.server(side, 'bootstrap')['deviceId'], side['deviceId'])
            side['env'].pop('FAIL_SYSTEMD')
            t.server(side, 'install-auto')
            units = side['home'] / '.config/systemd/user'
            service = (units / 'remote-disk-folders.service').read_text()
            self.assertIn('server-disk.sh" bootstrap', service)
            timer = (units / 'remote-disk-folders.timer').read_text()
            self.assertIn('OnStartupSec=2\n', timer)
            self.assertIn('OnUnitInactiveSec=2\n', timer)
            self.assertIn('AccuracySec=1\n', timer)  # systemd's default minute of coalescing would hide the short interval.
            calls = [json.loads(line) for line in (side['home'] / 'systemctl-calls').read_text().splitlines()]
            self.assertIn(['--user', 'daemon-reload'], calls)
            self.assertIn(['--user', 'enable', '--now', 'remote-disk-folders.timer'], calls)
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


class IncomingFolderTests(unittest.TestCase):
    def test_upload_is_accepted_bidirectionally_and_offered_to_a_third_device(self):
        with Stand(3) as t:
            server, laptop, desktop = t.sides
            make_disk(server['home'])
            for side, peer in ((server, laptop), (laptop, server), (server, desktop), (desktop, server)):
                t.register(side, peer)
            self.assertEqual(list((server['home'] / 'Disk').iterdir()), [server['home'] / 'Disk/.mounted'])
            source = t.offer(laptop, server, 'rd-upload-v1-00000000000000000000000000000001', 'Проект')
            (source / '.env').write_text('test-only-not-a-secret')
            wait(lambda: 'rd-upload-v1-00000000000000000000000000000001' in t.api(server, 'cluster/pending/folders'), 'upload offered to server')
            started = time.monotonic()
            t.server(server, 'reconcile')  # Also the entry point of already installed timers.
            self.assertLess(time.monotonic() - started, 5)
            target = server['home'] / 'Disk/Проект'
            folder = t.folder(server, 'rd-upload-v1-00000000000000000000000000000001')
            self.assertEqual((folder['path'], folder['label'], folder['type']), (str(target), 'Проект', 'sendreceive'))
            self.assertEqual((folder['fsWatcherEnabled'], folder['fsWatcherDelayS'], folder['maxConflicts']), (True, 2, -1))
            self.assertEqual(folder['versioning']['type'], 'staggered')
            self.assertEqual({d['deviceID'] for d in folder['devices']}, {s['deviceId'] for s in t.sides})
            wait(lambda: (target / 'source.txt').exists(), 'uploaded bytes arrive at the server')
            self.assertEqual((target / 'source.txt').read_text(), 'rd-upload-v1-00000000000000000000000000000001')
            self.assertFalse((target / '.env').exists())
            (target / 'reply.txt').write_text('server reply')
            wait(lambda: (source / 'reply.txt').exists(), 'server watcher sends a change back without manual scan')
            self.assertEqual((source / 'reply.txt').read_text(), 'server reply')
            wait(lambda: 'rd-upload-v1-00000000000000000000000000000001' in t.api(desktop, 'cluster/pending/folders'), 'offer reaches third device')
            pending = t.api(desktop, 'cluster/pending/folders')['rd-upload-v1-00000000000000000000000000000001']
            self.assertEqual(pending['offeredBy'][server['deviceId']]['label'], 'Проект')
            self.assertEqual(t.api(desktop, 'config/folders'), [])  # The client can render its cloud placeholder.
            before = t.api(server, 'config')
            files = [target / n for n in ('.stignore', '.stignore-remoteagents', '.stfolder/remote-disk-folder-id')]
            mtimes = [p.stat().st_mtime_ns for p in files]
            for _ in range(2):
                t.server(server, 'bootstrap')
            self.assertEqual(t.api(server, 'config'), before)
            self.assertEqual([p.stat().st_mtime_ns for p in files], mtimes)
            self.assertEqual(sorted(p.name for p in target.parent.iterdir() if p.is_dir()), ['Проект'])

    def test_colliding_labels_never_merge_existing_contents_or_registered_paths(self):
        with Stand() as t:
            server, laptop = t.sides
            make_disk(server['home'])
            t.register(server, laptop)
            t.register(laptop, server)
            disk = server['home'] / 'Disk'
            (disk / 'Проект').mkdir(parents=True)
            (disk / 'Проект/keep.txt').write_text('server original')
            (disk / 'Проект (2)').write_text('ordinary file')
            (disk / 'Проект (3)').symlink_to(server['home'] / 'missing')
            # A registered, currently missing path is occupied too, including Windows case differences.
            folder = t.api(server, 'config/defaults/folder')
            folder.update(id='reserved-path', label='reserved', path=str(disk / 'ПРОЕКТ (4)'), paused=True,
                          devices=[dict(deviceID=server['deviceId'])])
            t.api(server, 'config/folders/reserved-path', 'PUT', folder)
            reserved_config = t.folder(server, 'reserved-path')
            for folder_id in ('rd-upload-v1-00000000000000000000000000000002', 'rd-upload-v1-00000000000000000000000000000003'):
                t.offer(laptop, server, folder_id, 'Проект')
            wait(lambda: {'rd-upload-v1-00000000000000000000000000000002', 'rd-upload-v1-00000000000000000000000000000003'} <= set(t.api(server, 'cluster/pending/folders')), 'same-label uploads')
            t.server(server, 'bootstrap')
            self.assertFalse(any(f['id'] in ('rd-upload-v1-00000000000000000000000000000002', 'rd-upload-v1-00000000000000000000000000000003') for f in t.api(server, 'config/folders')))
            self.assertFalse((disk / 'Проект (5)').exists())
            self.assertFalse((disk / 'Проект (6)').exists())
            self.assertEqual((disk / 'Проект/keep.txt').read_text(), 'server original')
            self.assertFalse((disk / 'Проект/source.txt').exists())
            self.assertEqual((disk / 'Проект (2)').read_text(), 'ordinary file')
            self.assertTrue((disk / 'Проект (3)').is_symlink())
            self.assertFalse((server['home'] / 'missing').exists())
            self.assertEqual(t.folder(server, 'reserved-path'), reserved_config)
            before = t.api(server, 'config/folders')
            t.server(server, 'bootstrap')
            self.assertEqual(t.api(server, 'config/folders'), before)

    def test_remote_labels_are_safe_names_including_crlf_and_reserved_names(self):
        labels = {'rd-upload-v1-00000000000000000000000000000004': '../NUL:bad\\dir\r\n', 'rd-upload-v1-00000000000000000000000000000005': 'CON', 'rd-upload-v1-00000000000000000000000000000006': '',
                  'rd-upload-v1-00000000000000000000000000000007': 'Я' * 400, 'rd-upload-v1-00000000000000000000000000000008': '...'}
        with Stand() as t:
            server, laptop = t.sides
            make_disk(server['home'])
            t.register(server, laptop)
            t.register(laptop, server)
            for folder_id, label in labels.items():
                t.offer(laptop, server, folder_id, label)
            wait(lambda: set(labels) <= set(t.api(server, 'cluster/pending/folders')), 'unsafe-label offers')
            t.server(server, 'bootstrap')
            self.assertEqual(t.api(server, 'config/folders'), [])
            self.assertEqual({p.name for p in (server['home'] / 'Disk').iterdir()}, {'.mounted'})

    def test_upload_id_equal_to_an_unregistered_local_name_does_not_merge(self):
        with Stand() as t:
            server, laptop = t.sides
            make_disk(server['home'])
            t.register(server, laptop)
            t.register(laptop, server)
            original = server['home'] / 'Disk/Project'
            original.mkdir(parents=True)
            (original / 'keep.txt').write_text('unregistered local content')
            source = t.offer(laptop, server, 'Project', 'Project')
            wait(lambda: 'Project' in t.api(server, 'cluster/pending/folders'), 'ID/name collision offered')
            result = t.server(server, 'bootstrap', ok=False)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertFalse((original.with_name('Project (2)')).exists())
            self.assertEqual(t.api(server, 'config/folders'), [])
            self.assertFalse((original / 'source.txt').exists())
            self.assertFalse((source / 'keep.txt').exists())
            self.assertEqual((original / 'keep.txt').read_text(), 'unregistered local content')

    def test_retry_after_a_committed_put_with_a_lost_response_is_idempotent(self):
        with Stand() as t:
            server, laptop = t.sides
            make_disk(server['home'])
            t.register(server, laptop)
            t.register(laptop, server)
            t.offer(laptop, server, 'rd-upload-v1-00000000000000000000000000000009', 'Upload')
            wait(lambda: 'rd-upload-v1-00000000000000000000000000000009' in t.api(server, 'cluster/pending/folders'), 'offer for lost response')

            def lost_response(route, method='GET', body=None):
                result = t.api(server, route, method, body)
                if method == 'PUT' and route == 'config/folders/rd-upload-v1-00000000000000000000000000000009':
                    raise urllib.error.URLError('test response lost after committed write')
                return result

            with server_helpers(server['home']) as ns, contextlib.redirect_stderr(io.StringIO()):
                ns['reconcile'](lost_response, server['deviceId'])
            before = t.folder(server, 'rd-upload-v1-00000000000000000000000000000009')
            t.server(server, 'bootstrap')
            self.assertEqual(t.folder(server, 'rd-upload-v1-00000000000000000000000000000009'), before)
            self.assertEqual({p.name for p in (server['home'] / 'Disk').iterdir() if p.is_dir()}, {'Upload'})

    def test_unknown_device_is_not_accepted_until_registered(self):
        with Stand() as t:
            server, stranger = t.sides
            make_disk(server['home'])
            t.register(stranger, server)  # The server has never seen add-device for this peer.
            t.offer(stranger, server, 'rd-upload-v1-0000000000000000000000000000000a', 'Чужая папка')
            wait(lambda: stranger['deviceId'] in t.api(server, 'cluster/pending/devices'), 'unknown device rejected by engine')
            t.server(server, 'bootstrap')
            self.assertEqual(t.api(server, 'config/folders'), [])
            self.assertEqual(list((server['home'] / 'Disk').iterdir()), [server['home'] / 'Disk/.mounted'])
            t.register(server, stranger)
            wait(lambda: 'rd-upload-v1-0000000000000000000000000000000a' in t.api(server, 'cluster/pending/folders'), 'offer after explicit registration')
            # add-device itself also accepts an offer already waiting at the server.
            t.server(server, 'add-device', dict(deviceId=stranger['deviceId']))
            target = server['home'] / 'Disk/Чужая папка'
            wait(lambda: (target / 'source.txt').exists(), 'registered upload accepted')
            self.assertEqual((target / 'source.txt').read_text(), 'rd-upload-v1-0000000000000000000000000000000a')
            self.assertFalse(t.api(server, 'config/devices/' + stranger['deviceId'])['autoAcceptFolders'])

    def test_failed_acceptance_reuses_its_reserved_directory_and_other_offers_continue(self):
        with Stand() as t:
            server, laptop = t.sides
            make_disk(server['home'])
            t.register(server, laptop)
            t.register(laptop, server)
            for folder_id in ('rd-upload-v1-0000000000000000000000000000000b', 'rd-upload-v1-0000000000000000000000000000000c'):
                t.offer(laptop, server, folder_id, 'Upload' if folder_id.endswith('0b') else 'Other')
            wait(lambda: {'rd-upload-v1-0000000000000000000000000000000b', 'rd-upload-v1-0000000000000000000000000000000c'} <= set(t.api(server, 'cluster/pending/folders')), 'retry offers')

            def failing_api(route, method='GET', body=None):
                if method == 'PUT' and route == 'config/folders/rd-upload-v1-0000000000000000000000000000000b':
                    raise urllib.error.URLError('test failure before write')
                return t.api(server, route, method, body)

            stderr = io.StringIO()
            with server_helpers(server['home']) as ns, contextlib.redirect_stderr(stderr):
                ns['reconcile'](failing_api, server['deviceId'])
            self.assertIn('RemoteDisk: rd-upload-v1-0000000000000000000000000000000b: ', stderr.getvalue())
            self.assertEqual({f['id'] for f in t.api(server, 'config/folders')}, {'rd-upload-v1-0000000000000000000000000000000c'})
            reserved = server['home'] / 'Disk/Upload'
            self.assertEqual((reserved / '.stfolder/remote-disk-folder-id').read_text(), 'rd-upload-v1-0000000000000000000000000000000b')
            # A path registered by another action after the failed PUT must also block reuse of the reservation.
            other = t.api(server, 'config/defaults/folder')
            other.update(id='later-overlap', path=str(reserved / 'nested'), paused=True,
                         devices=[dict(deviceID=server['deviceId'])])
            t.api(server, 'config/folders/later-overlap', 'PUT', other)
            result = t.server(server, 'bootstrap', ok=False)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertIn('Путь входящей папки уже занят', result.stderr.decode())
            self.assertNotIn('rd-upload-v1-0000000000000000000000000000000b', {f['id'] for f in t.api(server, 'config/folders')})
            t.api(server, 'config/folders/later-overlap', 'DELETE')
            t.server(server, 'bootstrap')
            self.assertEqual(t.folder(server, 'rd-upload-v1-0000000000000000000000000000000b')['path'], str(reserved))
            self.assertEqual(Path(t.folder(server, 'rd-upload-v1-0000000000000000000000000000000c')['path']).name, 'Other')
            wait(lambda: (reserved / 'source.txt').exists(), 'retry transfers data')
            self.assertEqual({p.name for p in reserved.parent.iterdir() if p.is_dir()}, {'Upload', 'Other'})
            self.assertEqual({f['id'] for f in t.api(server, 'config/folders')}, {'rd-upload-v1-0000000000000000000000000000000b', 'rd-upload-v1-0000000000000000000000000000000c'})

    def test_stale_unknown_offer_does_not_create_a_directory(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            rest = FakeRest()

            def stale_api(route, method='GET', body=None):
                if route == 'cluster/pending/folders':
                    return {'stale': {'offeredBy': {'REMOVED': {'label': 'Do not accept'}}}}
                return rest(route, method, body)

            ns['reconcile'](stale_api, 'SERVER')
            self.assertEqual(rest.puts, [])
            self.assertFalse((Path(tmp) / 'Disk').exists())
            # A reservation left by an earlier failed acceptance does not bypass the peer check either.
            marker = Path(tmp) / 'Disk/Reserved/.stfolder/remote-disk-folder-id'
            marker.parent.mkdir(parents=True)
            marker.write_text('stale')
            ns['reconcile'](stale_api, 'SERVER')
            self.assertEqual(rest.puts, [])
            self.assertEqual([p.name for p in marker.parents[2].iterdir()], ['Reserved'])

    def test_failure_reading_pending_offers_does_not_stop_local_discovery(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            make_project(Path(tmp) / 'Disk/Local')
            rest = FakeRest()

            def failing_api(route, method='GET', body=None):
                if route == 'cluster/pending/folders':
                    raise urllib.error.URLError('test pending endpoint unavailable')
                return rest(route, method, body)

            with contextlib.redirect_stderr(io.StringIO()) as stderr:
                ns['reconcile'](failing_api, 'SERVER')
            self.assertEqual(rest.puts, ['Local'])
            self.assertIn('входящие папки', stderr.getvalue())


class ServerHardeningTests(unittest.TestCase):
    def test_reconcile_stays_an_alias_of_bootstrap_for_installed_timers(self):
        with Stand(2) as t:
            a, b = t.sides
            t.server(a, 'add-device', dict(deviceId=b['deviceId'], deviceName='Laptop'))
            make_project(a['home'] / 'Disk/Fresh')
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
            make_project(disk / 'A_dir_ignore')
            make_project(disk / 'B_link_ignore')
            make_project(disk / 'C_ok')
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
                make_project(Path(tmp) / 'Disk' / name)
            for label, error in errors.items():
                with self.subTest(error=label), server_helpers(tmp) as ns:
                    def ignores(path, write=True):
                        if path.name == 'B':
                            raise error
                    ns['ignores'] = ignores
                    ns['exclude_git'] = lambda path: None
                    ns['missing_watch'].unlink(missing_ok=True)
                    rest, stderr = FakeRest(), io.StringIO()
                    with contextlib.redirect_stderr(stderr):
                        ns['reconcile'](rest, 'SERVER')
                    self.assertEqual(rest.puts, ['A', 'C'])
                    self.assertRegex(stderr.getvalue(), r'^RemoteDisk: B: .+\n$')

    def test_git_trouble_blocks_sharing_but_exclude_failure_is_cosmetic(self):
        troubles = {'git timeout': ('git', subprocess.TimeoutExpired(['git'], 5)),
                    'git is missing': ('git', FileNotFoundError(2, 'No such file or directory', 'git')),
                    'linked exclude file': ('exclude_git', ValueError('Символические ссылки запрещены'))}
        with tempfile.TemporaryDirectory() as tmp:
            make_project(Path(tmp) / 'Disk/Repo')
            for label, (name, error) in troubles.items():
                with self.subTest(trouble=label), server_helpers(tmp) as ns:
                    ns['ignores'] = lambda path, write=True: None
                    ns[name] = raiser(error)
                    ns['missing_watch'].unlink(missing_ok=True)
                    rest, stderr = FakeRest(), io.StringIO()
                    with contextlib.redirect_stderr(stderr):
                        ns['reconcile'](rest, 'SERVER')
                    self.assertEqual(rest.puts, ['Repo'] if name == 'exclude_git' else [])
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
                make_project(disk / name)
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
            self.assertEqual((disk / 'UserRules/.stignore').read_bytes(), include + b'my-rules\n')
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
            self.assertEqual((disk / 'OldPlusUser/.stignore').read_bytes(), include + latest + b'my-extra.txt\n')
            self.assertEqual((disk / 'OldCRLF/.stignore').read_bytes(),
                             include.replace(b'\n', b'\r\n') + latest.replace(b'\n', b'\r\n'))
            self.assertEqual((disk / 'OldBOM/.stignore').read_bytes(), b'\xef\xbb\xbf' + include + latest)
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
            make_project(a['home'] / 'Disk/Slow')
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


class MissingFolderTests(unittest.TestCase):
    def offer_again(self, t, computer, server, folder_id):
        # DELETE updates the server's ClusterConfig, but the client's unchanged offer is
        # processed again only on a fresh ClusterConfig (e.g. after reconnecting).
        route = '?device=' + server['deviceId']
        t.api(computer, 'system/pause' + route, 'POST')
        t.api(computer, 'system/resume' + route, 'POST')
        wait(lambda: folder_id in t.api(server, 'cluster/pending/folders'), 'retained client copy offered again', 30)

    def forget(self, t, server, ns, now, api=None):
        folders = t.api(server, 'config/folders')
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            ns['forget_missing'](api or (lambda *args: t.api(server, *args)), folders,
                                 server['home'] / 'Disk', now=now)
        return stderr.getvalue()

    def test_deleted_project_is_forgotten_after_real_grace_period_and_never_returns(self):
        with Stand(2) as t:
            server, computer = t.sides
            disk = server['home'] / 'Disk'
            project = disk / 'Ephemeral'
            make_project(project)
            (disk / '.mounted').touch()  # Disk remains nonempty when the only project disappears.
            (project / 'keep.txt').write_text('client copy must survive')
            t.register(server, computer)
            t.register(computer, server)
            wait(lambda: 'Ephemeral' in t.api(computer, 'cluster/pending/folders'), 'server offers project')
            local = computer['home'] / 'Disk/Ephemeral'
            folder = t.folder(server, 'Ephemeral')
            folder['path'] = str(local)
            t.api(computer, 'config/folders/Ephemeral', 'PUT', folder)
            wait(lambda: (local / 'keep.txt').exists() and t.settled('Ephemeral'), 'client copy is synced')
            completion = lambda: t.api(computer, 'db/completion?folder=Ephemeral&device=' + server['deviceId'])
            self.assertEqual(completion()['remoteState'], 'valid')

            shutil.rmtree(project)  # Only the test simulates the agent deleting its project.
            self.assertEqual(bootstrap_tick(t, server), '')
            since = json.loads((server['state'] / 'missing-folders.json').read_text())['folders']['Ephemeral']['since']
            self.assertEqual(t.folder(server, 'Ephemeral')['id'], 'Ephemeral')
            logs = []
            while any(f['id'] == 'Ephemeral' for f in t.api(server, 'config/folders')):
                self.assertLess(time.monotonic() - since, 45, 'registration was not removed after 30 s')
                if time.monotonic() - since < 29:
                    self.assertEqual(t.folder(server, 'Ephemeral')['id'], 'Ephemeral')
                time.sleep(2)
                logs.append(bootstrap_tick(t, server))
            self.assertGreaterEqual(time.monotonic() - since, 30)
            self.assertEqual(''.join(logs), 'RemoteDisk: Ephemeral: регистрация снята, папка отсутствует не менее 30 с\n')
            self.assertEqual(t.api(server, 'config/folders'), [])
            wait(lambda: completion()['remoteState'] == 'notSharing', 'client notices server stopped sharing')
            status = t.api(computer, 'db/status?folder=Ephemeral')
            self.assertEqual((status['state'], status['pullErrors'], status.get('error', '')), ('idle', 0, ''))
            self.assertEqual((local / 'keep.txt').read_text(), 'client copy must survive')
            self.assertIn(server['deviceId'], {d['deviceID'] for d in t.folder(computer, 'Ephemeral')['devices']})
            self.assertTrue(t.api(computer, 'system/connections')['connections'][server['deviceId']]['connected'])
            # The client continues to offer its local registration. Reconcile must not accept it back.
            self.offer_again(t, computer, server, 'Ephemeral')
            for _ in range(2):
                self.assertEqual(bootstrap_tick(t, server), '')
                self.assertFalse(project.exists())
                self.assertEqual(t.api(server, 'config/folders'), [])

            make_project(project)
            (project / 'new.txt').write_text('same name must not restore retired ID')
            self.assertEqual(bootstrap_tick(t, server), '')
            self.assertEqual(t.api(server, 'config/folders'), [])
            self.assertEqual((local / 'keep.txt').read_text(), 'client copy must survive')
            self.assertFalse((local / 'new.txt').exists())
            self.assertIn('Ephemeral', json.loads((server['state'] / 'missing-folders.json').read_text())['removed'])

    def test_unavailable_empty_or_replaced_disk_resets_continuous_absence(self):
        for mode in ('missing', 'empty', 'unreadable', 'replaced'):
            with self.subTest(mode=mode), Stand(1) as t:
                server = t.sides[0]
                disk = server['home'] / 'Disk'
                project = disk / 'Project'
                make_project(project)
                (disk / '.mounted').touch()
                t.server(server, 'bootstrap')
                project.rename(server['home'] / 'saved-project')
                with server_helpers(server['home']) as ns:
                    self.assertEqual(self.forget(t, server, ns, 1000), '')
                    if mode in ('missing', 'replaced'):
                        disk.rename(server['home'] / 'saved-disk')
                        if mode == 'replaced':
                            disk.mkdir()
                            (disk / '.other-mount').touch()
                    elif mode == 'empty':
                        (disk / '.mounted').unlink()
                    else:
                        disk.chmod(0)
                    try:
                        self.assertEqual(self.forget(t, server, ns, 1100), '')
                        self.assertEqual(t.folder(server, 'Project')['id'], 'Project')
                    finally:
                        if mode == 'unreadable':
                            disk.chmod(0o700)
                    if mode in ('missing', 'replaced'):
                        if disk.exists():
                            shutil.rmtree(disk)
                        (server['home'] / 'saved-disk').rename(disk)
                    elif mode == 'empty':
                        (disk / '.mounted').touch()
                    self.assertEqual(self.forget(t, server, ns, 1101), '')
                    self.assertEqual(self.forget(t, server, ns, 1130), '')
                    self.assertEqual(t.folder(server, 'Project')['id'], 'Project')
                    self.assertIn('регистрация снята', self.forget(t, server, ns, 1131))
                self.assertTrue((server['home'] / 'saved-project/.stignore').exists())

    def test_short_rename_and_another_restored_project_do_not_reset_other_timers(self):
        with Stand(1) as t:
            server = t.sides[0]
            disk = server['home'] / 'Disk'
            for name in ('Brief', 'Restored', 'LongGone'):
                make_project(disk / name)
            t.server(server, 'bootstrap')
            for name in ('Brief', 'Restored', 'LongGone'):
                (disk / name).rename(server['home'] / name)
            (disk / '.mounted').touch()
            with server_helpers(server['home']) as ns:
                self.forget(t, server, ns, 1000)
                self.assertEqual(self.forget(t, server, ns, 1029), '')
                (server['home'] / 'Brief').rename(disk / 'Brief')
                self.assertEqual(self.forget(t, server, ns, 1029.5), '')
                # Model an already removed registration returning while another timer is active.
                t.api(server, 'config/folders/Restored', 'DELETE')
                state = json.loads(ns['missing_watch'].read_text())
                state['removed'] = dict(Restored=str(disk / 'Restored'))
                ns['save_missing'](state)
                (server['home'] / 'Restored').rename(disk / 'Restored')
                with mock.patch.object(ns['time'], 'monotonic', return_value=1029.5):
                    ns['reconcile'](lambda *args: t.api(server, *args), server['deviceId'])
                self.assertIn('регистрация снята', self.forget(t, server, ns, 1030))
            self.assertEqual({f['id'] for f in t.api(server, 'config/folders')}, {'Brief'})

    def test_removed_incoming_id_is_never_resurrected_even_when_returned_locally(self):
        with Stand(2) as t:
            server, computer = t.sides
            make_disk(server['home'])
            t.register(server, computer)
            t.register(computer, server)
            source = t.offer(computer, server, 'rd-upload-v1-0000000000000000000000000000000d', 'Upload')
            wait(lambda: 'rd-upload-v1-0000000000000000000000000000000d' in t.api(server, 'cluster/pending/folders'), 'upload offered')
            t.server(server, 'bootstrap')
            project = server['home'] / 'Disk/Upload'
            wait(lambda: (project / 'source.txt').exists(), 'upload received')
            project.rename(server['home'] / 'saved-upload')
            (project.parent / '.mounted').touch()
            with server_helpers(server['home']) as ns:
                self.forget(t, server, ns, 1000)
                self.assertIn('регистрация снята', self.forget(t, server, ns, 1030))
            self.offer_again(t, computer, server, 'rd-upload-v1-0000000000000000000000000000000d')
            t.server(server, 'bootstrap')
            self.assertFalse(project.exists())
            self.assertEqual((source / 'source.txt').read_text(), 'rd-upload-v1-0000000000000000000000000000000d')
            # Remember the removal even across an empty/unavailable root.
            (project.parent / '.mounted').unlink()
            t.server(server, 'bootstrap')
            self.assertFalse(project.exists())
            (server['home'] / 'saved-upload').rename(project)
            t.server(server, 'bootstrap')
            self.assertEqual(t.api(server, 'config/folders'), [])
            self.assertIn('rd-upload-v1-0000000000000000000000000000000d', json.loads((server['state'] / 'missing-folders.json').read_text())['removed'])

    def test_only_exact_top_level_paths_are_removed_and_state_is_defensive(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            disk = Path(tmp) / 'Disk'
            disk.mkdir()
            (disk / '.mounted').touch()
            paths = [str(disk / 'Gone'), str(disk), str(disk / 'Nested/Gone'),
                     str(Path(tmp) / 'Outside'), '~/Disk/Relative', str(disk) + '/./Dot',
                     str(disk) + '/Trailing/', str(disk / '..')]
            folders = [dict(id=str(i), path=p) for i, p in enumerate(paths)]
            deletes = []
            def api(route, method='GET', body=None):
                folder_id = route.rsplit('/', 1)[1]
                if method == 'DELETE':
                    deletes.append(folder_id)
                    return {}
                return next(f for f in folders if f['id'] == folder_id)
            for bad in ('{}', '{"folders": []}', '{"folders": {"0": {"since": "bad"}}}', '{"removed": {}}'):
                with self.subTest(state=bad):
                    ns['missing_watch'].parent.mkdir(parents=True, exist_ok=True)
                    ns['missing_watch'].write_text(bad)
                    ns['forget_missing'](api, folders[:], disk, now=1000)
                    self.assertEqual(deletes, [])
            with contextlib.redirect_stderr(io.StringIO()):
                ns['forget_missing'](api, folders[:], disk, now=1030)
            self.assertEqual(deletes, ['0'])

    def test_delete_failure_or_lost_response_is_retried_without_accepting_the_client_copy(self):
        for committed in (False, True):
            with self.subTest(committed=committed), Stand(1) as t:
                server = t.sides[0]
                project = server['home'] / 'Disk/Gone'
                make_project(project)
                (project.parent / '.mounted').touch()
                t.server(server, 'bootstrap')
                project.rename(server['home'] / 'saved')
                def failing_api(route, method='GET', body=None):
                    if method == 'DELETE':
                        if committed:
                            t.api(server, route, method, body)
                        raise urllib.error.URLError('test DELETE response lost')
                    return t.api(server, route, method, body)
                with server_helpers(server['home']) as ns:
                    self.forget(t, server, ns, 1000)
                    self.assertIn('test DELETE response lost', self.forget(t, server, ns, 1030, failing_api))
                    self.assertIn('Gone', json.loads(ns['missing_watch'].read_text())['removed'])
                    self.forget(t, server, ns, 1031)
                self.assertEqual(t.api(server, 'config/folders'), [])
                self.assertTrue((server['home'] / 'saved/.stignore').exists())


class StaleConnectionTests(unittest.TestCase):
    """Туннель рвётся молча, серверные соединения зависают и не пускают компьютер обратно: bootstrap делает pause/resume."""
    DEVICE = 'AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH'
    OTHER = 'ZZZZZZZ-YYYYYYY-XXXXXXX-WWWWWWW-VVVVVVV-UUUUUUU-TTTTTTT-SSSSSSS'

    def check(self, ns, engine, now=None, clock=None):
        """Один запуск проверки; now — «время» наблюдения (без него берутся монотонные часы clock)."""
        clock = clock or FakeClock()
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), mock.patch('time.sleep', clock.sleep), \
                mock.patch('time.monotonic', clock.monotonic):
            ns['watch_connections'](engine, now)
        return stderr.getvalue()

    def recycled(self, engine, device_id=None):
        device_id = device_id or self.DEVICE
        return engine.posts() == [('POST', 'system/pause?device=' + device_id), ('POST', 'system/resume?device=' + device_id)]

    def test_device_is_stale_only_after_every_connection_was_silent_for_the_threshold(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            limit = ns['STALE_AFTER_S']
            # По протоколу живая сторона шлёт пинг раз в 90 с: порог обязан это перекрывать с запасом.
            self.assertGreaterEqual(limit, 90 + 20)
            engine = FakeConnections()
            engine.add(self.DEVICE, 'Computer', 8, 8, 8)
            self.assertEqual(self.check(ns, engine, 1000), '')  # первая встреча: молчание отсчитывается отсюда
            self.assertEqual(self.check(ns, engine, 1000 + limit - 1), '')
            engine.devices[self.DEVICE]['conns'][1][2] += 8  # пинг по одному из трёх соединений: устройство живо
            self.assertEqual(self.check(ns, engine, 1000 + limit), '')
            self.assertEqual(self.check(ns, engine, 1000 + 2 * limit - 1), '')
            engine.devices[self.DEVICE]['conns'].append(['127.0.0.1:40009', '2026-11-15T07:01:00+01:00', 0])  # новое соединение
            self.assertEqual(self.check(ns, engine, 1000 + 2 * limit), '')
            self.assertEqual(self.check(ns, engine, 1000 + 3 * limit - 1), '')
            self.assertEqual(engine.posts(), [])
            line = self.check(ns, engine, 1000 + 3 * limit)
            self.assertTrue(self.recycled(engine))
            self.assertRegex(line, r'^RemoteDisk: Computer \(AAAAAAA\): соединения молчат %d с, .*pause/resume\n$' % limit)

    def test_only_the_silent_connected_device_is_recycled_with_one_log_line(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            limit = ns['STALE_AFTER_S']
            engine = FakeConnections()
            engine.add(self.DEVICE, 'Computer', 8, 8)
            engine.add(self.OTHER, 'Laptop', 8)
            engine.add('PAUSED1-X', 'Paused by the owner', 8)
            engine.devices['PAUSED1-X'].update(connected=False, paused=True)
            engine.add('OFFLINE-X', 'Offline')
            log = []
            for now in (0, limit - 1, limit, limit + 1, 3 * limit, 10 * limit):
                engine.devices[self.OTHER]['conns'][0][2] += 8  # этот обменивается данными постоянно
                log.append(self.check(ns, engine, 5000 + now))
            # Одна строка, и ровно тогда, когда молчание компьютера достигло порога; дальше он уже не зависший.
            self.assertEqual([bool(line) for line in log], [False, False, True, False, False, False])
            self.assertRegex(log[2], r'^RemoteDisk: Computer \(AAAAAAA\): соединения молчат %d с, .*pause/resume\n$' % limit)
            self.assertTrue(self.recycled(engine))
            # Устройство на паузе у владельца, неподключённое и обменивающееся данными не трогаются.
            self.assertTrue(engine.devices['PAUSED1-X']['paused'])

    def test_device_name_cannot_split_the_log_line(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            engine = FakeConnections()
            engine.add(self.DEVICE, 'Computer\r\nRemoteDisk: forged\x1b[2J', 8)
            self.check(ns, engine, 1000)
            line = self.check(ns, engine, 1000 + ns['STALE_AFTER_S'])
            self.assertEqual(line.count('\n'), 1)
            self.assertNotRegex(line, r'[\r\x1b]')
            self.assertTrue(line.startswith('RemoteDisk: Computer  RemoteDisk: forged'))

    def test_cooldown_blocks_a_second_recycling_of_the_same_device(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            limit, cooldown = ns['STALE_AFTER_S'], ns['HEAL_COOLDOWN_S']
            engine = FakeConnections()
            engine.pause_closes = False  # движок соединений не закрыл: сразу после лечения устройство всё ещё зависшее
            engine.add(self.DEVICE, 'Computer', 8)
            watch = ns['watch']
            self.check(ns, engine, 1000)
            self.assertNotEqual(self.check(ns, engine, 1000 + limit), '')
            self.assertEqual(len(engine.posts()), 2)
            # Лечение запомнено: даже при «давнем» молчании второе не раньше, чем через HEAL_COOLDOWN_S.
            state = json.loads(watch.read_text())
            self.assertEqual(state['healed'], {self.DEVICE: 1000 + limit})
            state['devices'][self.DEVICE]['since'] = 0
            watch.write_text(json.dumps(state))
            self.assertEqual(self.check(ns, engine, 1000 + limit + cooldown - 1), '')
            self.assertEqual(len(engine.posts()), 2)
            self.assertNotEqual(self.check(ns, engine, 1000 + limit + cooldown), '')
            self.assertEqual(len(engine.posts()), 4)
            # После лечения молчание отсчитывается заново: ещё одно только через STALE_AFTER_S.
            self.assertEqual(self.check(ns, engine, 1000 + limit + cooldown + limit - 1), '')
            self.assertEqual(len(engine.posts()), 4)

    def test_failed_resume_is_retried_by_the_next_run(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            limit = ns['STALE_AFTER_S']
            engine = FakeConnections()
            engine.add(self.DEVICE, 'Computer', 8)
            self.check(ns, engine, 1000)
            engine.resume_failures = [urllib.error.URLError('REST недоступен')] * 3  # все три попытки внутри запуска
            line = self.check(ns, engine, 1000 + limit)
            self.assertRegex(line, r'^RemoteDisk: Computer \(AAAAAAA\): URLError: .*REST недоступен.*\n$')
            self.assertTrue(engine.devices[self.DEVICE]['paused'])
            self.assertEqual(json.loads(ns['watch'].read_text())['resume'], {self.DEVICE: 1000 + limit})
            # Следующий запуск таймера возвращает устройство из паузы и забывает пометку.
            self.assertEqual(self.check(ns, engine, 1002 + limit), '')
            self.assertFalse(engine.devices[self.DEVICE]['paused'])
            self.assertNotIn('resume', json.loads(ns['watch'].read_text()) if ns['watch'].exists() else {})

    def test_resume_is_attempted_three_times_inside_one_run(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            engine = FakeConnections()
            engine.add(self.DEVICE, 'Computer', 8)
            self.check(ns, engine, 1000)
            engine.resume_failures = [urllib.error.URLError('временно')] * 2
            line = self.check(ns, engine, 1000 + ns['STALE_AFTER_S'])
            self.assertFalse(engine.devices[self.DEVICE]['paused'])
            self.assertRegex(line, r'pause/resume\n$')
            self.assertEqual(len([c for c in engine.posts() if 'resume' in c[1]]), 3)

    def test_run_that_dies_between_pause_and_resume_does_not_leave_the_device_paused(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            limit = ns['STALE_AFTER_S']
            engine = FakeConnections()
            engine.add(self.DEVICE, 'Computer', 8)
            self.check(ns, engine, 1000)
            engine.resume_failures = [RuntimeError('процесс убит')]  # не из тех сбоев, что обрабатываются: запуск обрывается
            with self.assertRaises(RuntimeError):
                self.check(ns, engine, 1000 + limit)
            self.assertTrue(engine.devices[self.DEVICE]['paused'])
            self.assertIn(self.DEVICE, json.loads(ns['watch'].read_text())['resume'])
            self.assertEqual(self.check(ns, engine, 1002 + limit), '')  # следующий запуск возвращает устройство из паузы
            self.assertFalse(engine.devices[self.DEVICE]['paused'])
            self.assertFalse(ns['watch'].exists())  # и забывает пометку

    def test_leftover_mark_never_resumes_a_device_that_is_not_paused(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            engine = FakeConnections()
            engine.add(self.DEVICE, 'Computer', 8)
            ns['watch'].parent.mkdir(parents=True)
            ns['watch'].write_text(json.dumps(dict(devices={}, healed={}, resume={self.DEVICE: 1000})))
            self.assertEqual(self.check(ns, engine, 1001), '')  # pause не состоялся или resume уже был: трогать нечего
            self.assertEqual(engine.posts(), [])
            self.assertEqual(json.loads(ns['watch'].read_text())['resume'], {})

    def test_broken_state_file_starts_the_watch_over(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            limit = ns['STALE_AFTER_S']
            engine = FakeConnections()
            engine.add(self.DEVICE, 'Computer', 8)
            ns['watch'].parent.mkdir(parents=True)
            for garbage in (b'\xff\x00 not json', b'[]', b'{"devices": [], "healed": 5, "resume": "x"}',
                            json.dumps(dict(devices={self.DEVICE: dict(sig='x', since='yesterday')})).encode()):
                with self.subTest(garbage=garbage):
                    ns['watch'].write_bytes(garbage)
                    self.assertEqual(self.check(ns, engine, 1000), '')
                    self.assertEqual(json.loads(ns['watch'].read_text())['devices'][self.DEVICE]['since'], 1000)
            self.assertEqual(engine.posts(), [])
            self.assertNotEqual(self.check(ns, engine, 1000 + limit), '')

    def test_restarted_time_counter_restarts_the_silence_instead_of_stalling_it(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            limit = ns['STALE_AFTER_S']
            engine = FakeConnections()
            engine.add(self.DEVICE, 'Computer', 8)
            self.check(ns, engine, 10_000)
            # Сервер перезагрузили: монотонный счётчик начался заново, отметка «из будущего» не может давать молчание.
            self.assertEqual(self.check(ns, engine, 500), '')
            self.assertEqual(self.check(ns, engine, 500 + limit - 1), '')
            self.assertEqual(engine.posts(), [])
            self.assertNotEqual(self.check(ns, engine, 500 + limit), '')

    def test_system_clock_jumps_do_not_make_a_live_device_silent(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            limit = ns['STALE_AFTER_S']
            engine = FakeConnections()
            engine.add(self.DEVICE, 'Computer', 8)
            clock = FakeClock(5000)
            self.assertEqual(self.check(ns, engine, clock=clock), '')
            clock.now += 2
            with mock.patch('time.time', return_value=time.time() + 10 * limit):  # NTP или ручной перевод часов вперёд
                self.assertEqual(self.check(ns, engine, clock=clock), '')
            self.assertEqual(engine.posts(), [])
            clock.now += limit  # а настоящее молчание по-прежнему замечается
            self.assertNotEqual(self.check(ns, engine, clock=clock), '')
            self.assertEqual(len(engine.posts()), 2)

    def test_device_that_came_alive_or_was_paused_by_the_owner_before_the_action_is_left_alone(self):
        for what in ('came alive', 'paused by the owner'):
            with self.subTest(what), tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
                limit = ns['STALE_AFTER_S']
                engine = FakeConnections()
                engine.add(self.DEVICE, 'Computer', 8)
                self.check(ns, engine, 1000)

                def interfere(read):
                    if read == 2:  # свежая сверка перед паузой; чтение 1 — снимок, по которому принято решение
                        if what == 'came alive':
                            engine.devices[self.DEVICE]['conns'][0][2] += 8
                        else:
                            engine.devices[self.DEVICE].update(paused=True, connected=False)

                engine.reads, engine.on_read = 0, interfere
                self.assertEqual(self.check(ns, engine, 1000 + limit), '')
                self.assertEqual(engine.posts(), [])
                self.assertEqual(engine.devices[self.DEVICE]['paused'], what == 'paused by the owner')
                engine.on_read = None
                # Ожившее устройство получает свежий отсчёт молчания, а не лечение на следующем же запуске.
                self.assertEqual(self.check(ns, engine, 1000 + limit + 2), '')
                self.assertEqual(engine.posts(), [])

    def test_waiting_for_the_disconnect_is_bounded_by_time_not_by_requests(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            engine = FakeConnections()
            engine.pause_closes = False  # соединения не закрываются, а REST медленный: каждое чтение почти 3 с
            engine.add(self.DEVICE, 'Computer', 8)
            clock = FakeClock()
            self.check(ns, engine, 1000, clock)
            engine.reads, engine.on_read = 0, lambda read: setattr(clock, 'now', clock.now + 2.9)
            self.assertNotEqual(self.check(ns, engine, 1000 + ns['STALE_AFTER_S'], clock), '')
            self.assertEqual(len(engine.posts()), 2)  # pause и resume выполнены
            # Снимок, сверка и два чтения за три секунды ожидания: бюджет времени, а не пятнадцать запросов.
            self.assertLessEqual(engine.reads, 4)

    def test_state_is_written_only_when_something_changes_and_removed_when_empty(self):
        with tempfile.TemporaryDirectory() as tmp, server_helpers(tmp) as ns:
            engine = FakeConnections()
            engine.add(self.DEVICE, 'Computer')  # не подключено
            self.check(ns, engine, 1000)
            self.assertFalse(ns['watch'].exists())  # помнить нечего: файла нет
            engine.add(self.DEVICE, 'Computer', 8)
            self.check(ns, engine, 1001)
            written = ns['watch'].stat().st_mtime_ns
            self.check(ns, engine, 1002)  # ничего нового: файл не переписывается
            self.assertEqual(ns['watch'].stat().st_mtime_ns, written)
            engine.devices[self.DEVICE].update(connected=False)
            self.check(ns, engine, 1003)  # устройство ушло: запись о нём не копится
            self.assertFalse(ns['watch'].exists())

    def test_failing_connection_check_never_stops_folder_discovery_or_bootstrap(self):
        with Stand(1) as t:
            side = t.sides[0]
            make_project(side['home'] / 'Disk/Local')
            ports_file = side['state'] / 'ports.json'
            ports = json.loads(ports_file.read_text())
            with FailingRoute(int(side['gui']), 'system/connections') as proxy:
                ports_file.write_text(json.dumps(dict(ports, gui=proxy.port)))
                try:
                    result = t.server(side, 'bootstrap', ok=False)
                finally:
                    ports_file.write_text(json.dumps(ports))
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(json.loads(result.stdout), dict(deviceId=side['deviceId'], listen=side['listen']))
            self.assertRegex(result.stderr.decode(), r'^RemoteDisk: соединения устройств: HTTPError: .*500.*\n$')
            self.assertEqual(t.folder(side, 'Local')['id'], 'Local')

    def test_only_bootstrap_watches_connections(self):
        with Stand(2) as t:
            server, computer = t.sides
            t.register(server, computer)
            t.register(computer, server)
            wait(lambda: device_connections(t, server, computer), 'engines connected')
            t.server(server, 'add-device', dict(deviceId=computer['deviceId']))
            self.assertFalse((server['state'] / 'connection-watch.json').exists())
            t.server(server, 'bootstrap')
            self.assertTrue((server['state'] / 'connection-watch.json').exists())

    def test_computer_reconnects_after_the_server_recycles_its_stale_connections(self):
        limit = script_constant('STALE_AFTER_S')
        with Stand(2) as t:
            server, computer = t.sides
            with TunnelProxy(server['listen']) as proxy:
                link_through_tunnel(t, server, computer, proxy)
                wait(lambda: settled(device_connections(t, server, computer)), 'three connections through the tunnel', 90)
                zombies = {c['address'] for c in device_connections(t, server, computer)}
                self.assertEqual(bootstrap_tick(t, server), '')  # наблюдение началось
                device_config = t.api(server, 'config/devices/' + computer['deviceId'])
                to_server = lambda: t.api(computer, 'system/connections')['connections'][server['deviceId']]['connected']

                # Смена сети у компьютера: туннель рвётся, серверные соединения остаются «живыми».
                self.assertGreaterEqual(proxy.cut(), 3)
                wait(lambda: not to_server(), 'the computer notices the broken tunnel', 20)
                attempts = proxy.accepted
                wait(lambda: proxy.accepted >= attempts + 2, 'the computer retries through a new tunnel connection', 40)
                # Без лечения: сервер всё ещё считает старые соединения живыми и отказывает новым, компьютер не подключён.
                self.assertEqual({c['address'] for c in device_connections(t, server, computer)}, zombies)
                self.assertFalse(to_server())
                # Молчание только началось: устройство не трогаем.
                self.assertEqual(bootstrap_tick(t, server), '')
                self.assertEqual({c['address'] for c in device_connections(t, server, computer)}, zombies)

                age_watch(server, limit + 10)  # прошло STALE_AFTER_S тишины
                started = time.monotonic()
                logged = [bootstrap_tick(t, server)]
                while not (to_server() and not zombies & {c['address'] for c in device_connections(t, server, computer)}):
                    self.assertLess(time.monotonic() - started, 60, 'the computer did not come back within 60 s')
                    time.sleep(1)
                    logged.append(bootstrap_tick(t, server))
                self.assertLess(time.monotonic() - started, 60, 'the computer did not come back within 60 s')
                lines = [line for text in logged for line in text.splitlines()]
                self.assertEqual(len(lines), 1, lines)
                self.assertRegex(lines[0], r'^RemoteDisk: Computer \(%s\): соединения молчат \d+ с, .*pause/resume$' % computer['deviceId'][:7])
                # Устройство не осталось на паузе, настройки прежние; дальнейшие запуски тихие (нет зависших, нет цикла).
                self.assertEqual(t.api(server, 'config/devices/' + computer['deviceId']), device_config)
                for _ in range(3):
                    self.assertEqual(bootstrap_tick(t, server), '')
                    time.sleep(1)

    def test_connections_with_real_traffic_are_never_recycled(self):
        limit = script_constant('STALE_AFTER_S')
        with Stand(2) as t:
            server, computer = t.sides
            make_disk(server['home'])
            with TunnelProxy(server['listen']) as proxy:
                link_through_tunnel(t, server, computer, proxy)
                wait(lambda: settled(device_connections(t, server, computer)), 'three connections through the tunnel', 90)
                identity = lambda: sorted((c['address'], c['startedAt']) for c in device_connections(t, server, computer))
                before = identity()
                self.assertEqual(bootstrap_tick(t, server), '')
                source = t.offer(computer, server, 'rd-upload-v1-0000000000000000000000000000000e', 'Live')
                wait(lambda: 'rd-upload-v1-0000000000000000000000000000000e' in t.api(server, 'cluster/pending/folders'), 'folder offered to the server')
                self.assertEqual(bootstrap_tick(t, server), '')  # сервер принимает папку: индексы пойдут в обе стороны
                wait(lambda: (server['home'] / 'Disk/Live/source.txt').exists(), 'accepted folder reaches the server')
                for n in range(3):
                    # Часы говорят «молчит давно», но компьютер шлёт данные: это живое соединение, его не трогают.
                    age_watch(server, limit + 10)
                    received = inbound_bytes(t, server, computer)
                    (source / f'note-{n}.txt').write_text(str(n) * 2000)
                    wait(lambda: inbound_bytes(t, server, computer) > received, 'the computer sends data to the server', 30)
                    self.assertEqual(bootstrap_tick(t, server), '')
                    self.assertEqual(identity(), before)
                    since = json.loads((server['state'] / 'connection-watch.json').read_text())['devices'][
                        computer['deviceId']]['since']
                    self.assertLess(time.monotonic() - since, 30)  # часы состояния — монотонные, общие для процессов
                wait(lambda: (server['home'] / 'Disk/Live/note-2.txt').exists(), 'the data reached the server', 40)
                self.assertEqual((server['home'] / 'Disk/Live/note-2.txt').read_text(), '2' * 2000)
                self.assertEqual(identity(), before)
                self.assertFalse(t.api(server, 'config/devices/' + computer['deviceId'])['paused'])


if __name__ == '__main__':
    if len(sys.argv) == 2 and not sys.argv[1].startswith('-'):
        os.environ['SYNCTHING_ARCHIVE'] = sys.argv.pop()
    unittest.main()
