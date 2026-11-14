#!/usr/bin/env python3
"""Server contracts against real Syncthing in disposable HOME directories."""
import base64
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.parse
import urllib.request
import xml.etree.ElementTree as E

HERE = Path(__file__).resolve().parent
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))
ARCHIVE_NAME = 'syncthing-linux-amd64-v2.1.7.tar.gz'


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


if __name__ == '__main__':
    if len(sys.argv) == 2 and not sys.argv[1].startswith('-'):
        os.environ['SYNCTHING_ARCHIVE'] = sys.argv.pop()
    unittest.main()
