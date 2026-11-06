#!/usr/bin/env python3
"""Offline Linux acceptance: real SHA256-pinned Syncthing, private temp states.

Usage: python3 test-two-way-sync.py --archive /path/to/syncthing-linux-amd64-v2.1.7.tar.gz
No downloads, existing states, or external connections are used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
import uuid
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
PROJECT = 'p-twoway-test'
ARCHIVE_SHA256 = '2edc416e7ed136b7c858ed5f3f02a3b8316589605e54c380228ceea7acbf0142'
LABELS = {
    1: 'K1 new files A->B and B->A',
    2: 'K2 edits, deletions and exact archived contents both directions',
    3: 'K3 concurrent edits preserve both versions on both peers',
    4: 'K4 .env, .pem, secret names and .git excluded both directions',
    5: 'K5 first connection merges existing contents without deletion',
    6: 'K6 pause blocks transfer, resume catches up',
    7: 'K7 disconnected status and automatic recovery',
}


def require(condition, message):
    if not condition:
        raise AssertionError(message)


class Fixture:
    def __init__(self, root, binary):
        self.root, self.binary, self.sides = root, binary, []
        self.http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        sockets = []
        try:
            for _ in range(6):
                sock = socket.socket()
                sock.bind(('127.0.0.1', 0))
                sockets.append(sock)
            ports = [sock.getsockname()[1] for sock in sockets]
            for i in range(2):
                directory = root / ('side-' + str(i))
                workspace = directory / 'workspace'
                workspace.mkdir(parents=True)
                (workspace / f'initial-{i}.txt').write_text(f'initial-{i}')
                manifest = directory / 'manifest.json'
                manifest.write_text(json.dumps(dict(schema=1, projectId=PROJECT,
                    hostId=f'side-{i}', scopeMode='folder', allowedRoots=['.'], files=[])))
                self.sides.append(dict(directory=directory, workspace=workspace,
                    state=directory/'state', manifest=manifest, host=f'side-{i}',
                    listen=ports[i*3], gui=ports[i*3+1], tunnel=ports[(1-i)*3]))
        finally:
            for sock in sockets:
                sock.close()
        ids = [self.call(s, 'identity')['deviceId'] for s in self.sides]
        for i, s in enumerate(self.sides):
            s['peer'] = ids[1-i]
            self.call(s, 'configure', manifest=s['manifest'], peer=s['peer'])
            tree = ET.parse(s['state']/'config.xml')
            s['key'] = tree.find('gui/apikey').text
            options = tree.find('options')
            for name in ('globalAnnounceEnabled', 'localAnnounceEnabled', 'relaysEnabled', 'natEnabled', 'crashReportingEnabled'):
                require(options.findtext(name) == 'false', 'external networking enabled')
            require([n.text for n in options.findall('listenAddress')] == [f"tcp://127.0.0.1:{s['listen']}"], 'non-loopback listener')
            require(tree.findtext('gui/address') == f"127.0.0.1:{s['gui']}", 'non-loopback API')
            require(tree.find('folder').get('type') == 'sendreceive', 'wrong folder mode')
            require(tree.find('folder/versioning').get('type') == 'simple', 'versioning disabled')
            params = {n.get('key'): n.get('val') for n in tree.findall('folder/versioning/param')}
            require(params == {'keep': '2147483647', 'cleanoutDays': '30'}, 'wrong retention policy')

    def args(self, s, action, **options):
        args = [sys.executable, str(HERE/'server-sync-runtime.py'), action,
                '--binary', str(self.binary), '--project', PROJECT, '--mode', 'bidirectional']
        values = {k: s[k] for k in ('state', 'host', 'workspace', 'listen', 'gui', 'tunnel')}
        values.update(options)
        for k, v in values.items():
            args.extend(['--'+k, str(v)])
        return args

    def call(self, s, action, **options):
        result = subprocess.run(self.args(s, action, **options), capture_output=True, text=True, timeout=15)
        require(result.returncode == 0, f'runtime {action} failed: {result.stdout} {result.stderr}')
        return json.loads(result.stdout)

    def api(self, s, route, method='GET', body=None):
        request = urllib.request.Request(f"http://127.0.0.1:{s['gui']}/rest/{route}",
            data=None if body is None else json.dumps(body).encode(), method=method,
            headers={'X-API-Key': s['key'], 'Content-Type': 'application/json'})
        with self.http.open(request, timeout=2) as response:
            return json.loads(response.read() or b'{}')

    def wait(self, predicate, message, limit=60):
        deadline = time.monotonic() + limit
        while time.monotonic() < deadline:
            for s in self.sides:
                if s.get('process') and s['process'].poll() is not None and not s.get('stopped'):
                    raise AssertionError('own Syncthing exited; log: '+self.log(s))
            try:
                if predicate():
                    return
            except (urllib.error.URLError, TimeoutError, ConnectionError):
                pass
            time.sleep(.15)
        raise AssertionError('timeout: '+message)

    def log(self, s):
        # Only our process log; never dump generated API keys or config.xml.
        return (s['directory']/'process.log').read_text(errors='replace')[-4000:].replace(s['key'], '[redacted]')

    def start(self, s):
        s['stopped'] = False
        with (s['directory']/'process.log').open('ab') as log:
            environment = {k: v for k, v in os.environ.items()
                           if not k.startswith('ST') and k not in ('ALL_PROXY', 'HTTP_PROXY', 'HTTPS_PROXY')}
            s['process'] = subprocess.Popen(self.args(s, 'start'), stdout=log,
                                            stderr=subprocess.STDOUT, env=environment)
        self.wait(lambda: self.api(s, 'system/ping').get('ping') == 'pong', 'API readiness')

    def close(self):
        for s in self.sides:
            p = s.get('process')
            if p and p.poll() is None:
                p.terminate()
        for s in self.sides:
            p = s.get('process')
            if p:
                try:
                    p.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    p.kill()
                    p.wait(timeout=5)

    def scan(self, *sides):
        for s in sides or self.sides:
            self.api(s, 'db/scan?folder=ra-'+PROJECT, 'POST')

    def settled(self):
        return all((lambda r: r['state'] == 'idle' and r['needTotalItems'] == 0)(
            self.api(s, 'db/status?folder=ra-'+PROJECT)) for s in self.sides)

    def text(self, s, name, content):
        p = s['workspace']/name
        return p.is_file() and p.read_text() == content

    def both(self, name, content):
        return all(self.text(s, name, content) for s in self.sides)

    def pause_link(self, paused):
        for s in self.sides:
            self.api(s, 'config/devices/'+s['peer'], 'PATCH', {'paused': paused})
        if paused:
            self.wait(lambda: all(not self.call(s, 'health')['connected'] for s in self.sides), 'device pause disconnect')

    def k5(self):
        for s in self.sides:
            self.start(s)
        for s in self.sides:
            self.call(s, 'resume')
        self.wait(lambda: all(self.both(f'initial-{i}.txt', f'initial-{i}') for i in range(2)), 'initial union')
        require(all(not list((s['workspace']/'.stversions').rglob('*')) for s in self.sides), 'initial files archived/deleted')

    def k1(self):
        for i, s in enumerate(self.sides):
            name = 'unlisted-'+uuid.uuid4().hex+'.txt'
            (s['workspace']/name).write_text(f'new-{i}')
            # Watcher in product configuration must discover unknown names itself.
            self.wait(lambda: self.both(name, f'new-{i}'), 'automatic new file')

    def k2(self):
        for i, s in enumerate(self.sides):
            peer = self.sides[1-i]
            name = f'versioned-{i}.txt'
            (s['workspace']/name).write_text(f'original-{i}')
            self.scan()
            self.wait(lambda: self.both(name, f'original-{i}'), 'version fixture')
            (s['workspace']/name).write_text(f'edited-longer-{i}')
            self.scan()
            self.wait(lambda: self.both(name, f'edited-longer-{i}'), 'edit')
            def archived(content):
                return any(p.is_file() and p.name.startswith(f'versioned-{i}~') and p.read_text() == content
                           for p in (peer['workspace']/'.stversions').rglob('*'))
            self.wait(lambda: archived(f'original-{i}'), 'overwritten content archived')
            # Version names have second precision; use distinct timestamps for this history check.
            time.sleep(1.1)
            (s['workspace']/name).unlink()
            self.scan()
            self.wait(lambda: all(not (x['workspace']/name).exists() for x in self.sides)
                      and archived(f'edited-longer-{i}'), 'deleted content archived')

    def k3(self):
        name = 'concurrent.txt'
        (self.sides[0]['workspace']/name).write_text('base')
        self.scan()
        self.wait(lambda: self.both(name, 'base') and self.settled(), 'conflict base')
        self.pause_link(True)
        for s, content in zip(self.sides, ('ALPHA-content', 'BETA-content')):
            (s['workspace']/name).write_text(content)
            self.scan(s)
        self.wait(self.settled, 'offline edits scanned')
        self.pause_link(False)
        def preserved():
            for s in self.sides:
                copies = list(s['workspace'].glob('concurrent.sync-conflict-*.txt'))
                if not copies or {p.read_text() for p in [s['workspace']/name, *copies]} != {'ALPHA-content', 'BETA-content'}:
                    return False
            return True
        self.wait(preserved, 'conflict copies and both exact contents')

    def k4(self):
        for i, source in enumerate(self.sides):
            target = self.sides[1-i]
            names = [f'excluded-{i}/.env', f'excluded-{i}/key.pem',
                     f'excluded-{i}/my-secret.txt', f'excluded-{i}/.git/HEAD',
                     f'excluded-{i}/nested/.git/objects/sample']
            for name in names:
                p = source['workspace']/name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text('synthetic excluded fixture')
            sentinel = f'excluded-{i}/public.txt'
            (source['workspace']/sentinel).write_text('public')
            self.scan()
            self.wait(lambda: self.text(target, sentinel, 'public') and self.settled(), 'exclusion scan completion')
            # Hold a negative assertion across several scans, after a positive transfer barrier.
            end = time.monotonic()+3
            while time.monotonic() < end:
                require(all(not (target['workspace']/name).exists() for name in names), 'excluded content transferred')
                require(not (target['workspace']/f'excluded-{i}/.git').exists(), '.git transferred')
                self.scan()
                time.sleep(.2)

    def k6(self):
        a, b = self.sides
        self.api(a, 'config/folders/ra-'+PROJECT, 'PATCH', {'paused': True})
        self.wait(lambda: self.api(a, 'config/folders/ra-'+PROJECT)['paused'], 'pause acknowledgement')
        name = 'paused-'+uuid.uuid4().hex+'.txt'
        for s, content in ((a, 'during-pause-A'), (b, 'during-pause-B')):
            (s['workspace']/(name+content)).write_text(content)
        self.scan(b)
        end = time.monotonic()+12
        while time.monotonic() < end:
            require(not (b['workspace']/(name+'during-pause-A')).exists(), 'A transferred while paused')
            require(not (a['workspace']/(name+'during-pause-B')).exists(), 'B transferred while paused')
            time.sleep(.15)
        self.call(a, 'resume')
        self.wait(lambda: all(self.both(name+c, c) for c in ('during-pause-A', 'during-pause-B')), 'resume backlog')

    def k7(self):
        a, b = self.sides
        self.wait(lambda: self.call(a, 'health')['connected'], 'connected before stop')
        b['stopped'] = True
        self.call(b, 'stop')
        b['process'].wait(timeout=10)
        self.wait(lambda: self.call(a, 'health')['connected'] is False, 'connected=false')
        name = 'recovered-'+uuid.uuid4().hex+'.txt'
        for i, s in enumerate(self.sides):
            (s['workspace']/(name+str(i))).write_text(f'recovered-{i}')
        self.start(b)
        # No manual scan, reconnect, or reconfiguration after restart.
        self.wait(lambda: all(self.call(s, 'health')['connected'] for s in self.sides)
                  and all(self.both(name+str(i), f'recovered-{i}') for i in range(2)), 'automatic connection and backlog recovery')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', required=True, type=Path)
    args = parser.parse_args()
    require(sys.platform.startswith('linux') and os.getuid() != 0, 'Linux nonroot required')
    fixture = None
    failures = []
    with tempfile.TemporaryDirectory(prefix='ra-two-way-') as temporary:
        root = Path(temporary)
        try:
            require(hashlib.sha256(args.archive.read_bytes()).hexdigest() == ARCHIVE_SHA256, 'archive SHA256 mismatch')
            binary = root/'syncthing'
            with tarfile.open(args.archive, 'r:gz') as archive:
                with archive.extractfile('syncthing-linux-amd64-v2.1.7/syncthing') as source:
                    binary.write_bytes(source.read())
            binary.chmod(0o700)
            version = subprocess.check_output([str(binary), '--version'], text=True, timeout=10)
            require(version.startswith('syncthing v2.1.7 '), 'wrong binary version')
            print('SHA256 OK Syncthing v2.1.7 archive '+ARCHIVE_SHA256, flush=True)
            fixture = Fixture(root, binary)
            for number in (5, 1, 2, 3, 4, 6, 7):
                try:
                    getattr(fixture, f'k{number}')()
                    print('PASS '+LABELS[number], flush=True)
                except Exception as error:
                    failures.append(number)
                    print('FAIL '+LABELS[number]+': '+str(error), flush=True)
        except Exception as error:
            failures.append('setup')
            print('FAIL setup: '+str(error), flush=True)
        finally:
            if fixture:
                fixture.close()
    return bool(failures)


if __name__ == '__main__':
    sys.exit(main())
