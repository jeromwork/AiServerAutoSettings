#!/usr/bin/env python3
"""Linux tests: real pinned rclone, rootless inotify-tools, loopback WebDAV; fake systemctl only.

All roots/configs/services are temporary. Never touches ~/Disk or Mail.
"""
import contextlib
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'cloud/server-cloud.sh'
PASSWORD = 'TEST-only-cloud-Pass"\\$secret'


def load():
    module = types.ModuleType('cloud_under_test')
    code = SCRIPT.read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
    with patch.object(sys, 'argv', ['-', str(SCRIPT)]):
        exec(compile(code, str(SCRIPT), 'exec'), module.__dict__)
    return module


cloud = load()


def wait_for(predicate, seconds=20, description='condition'):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(0.1)
    raise AssertionError('Timeout: ' + description)


def content(path):
    try:
        return path.read_text()
    except FileNotFoundError:
        return None


class FakeSystemd:
    """Only service manager is replaced; starts the actual installed shell helper."""
    def __init__(self, home, base):
        self.home, self.base, self.child = home, base, None
        self.calls = []

    def stop(self):
        if self.child and self.child.poll() is None:
            self.child.terminate()
            self.child.wait(timeout=35)

    def __call__(self, *args, check=True):
        self.calls.append(args)
        code = 0
        if args[0] == 'stop':
            self.stop()
        elif args[0] == 'restart':
            self.stop()
            env = dict(os.environ, HOME=str(self.home))
            self.child = subprocess.Popen(['bash', str(self.base / 'server-cloud.sh'), '_run'],
                                          env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        elif args[0] == 'is-active':
            code = int(not self.child or self.child.poll() is not None)
        return subprocess.CompletedProcess(args, code, '', '')


class CloudTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cache = tempfile.TemporaryDirectory(prefix='cloud-tools-test-')
        cls.cachebase = Path(cls.cache.name)
        with patch.object(cloud, 'BASE', cls.cachebase):
            # Verify the actual official download path and SHA256SUMS, no ready-tools dependency.
            cls.rclone = cloud.install_rclone()
            which = shutil.which
            with patch.object(cloud.shutil, 'which', side_effect=lambda name: None if name in ('sudo', 'inotifywait') else which(name)), \
                 patch.object(cloud.os, 'geteuid', return_value=1000):
                cls.inotify = cloud.install_inotify()
            assert str(cls.inotify).startswith(str(cls.cachebase)), 'must exercise rootless package extraction'
        print('\nTOOLS: official rclone ' + cloud.VERSION + ', SHA256SUMS verified; apt-get download + dpkg -x OK', flush=True)

    @classmethod
    def tearDownClass(cls):
        cls.cache.cleanup()

    def setUp(self):
        self.failures_before = len(self._outcome.result.failures) + len(self._outcome.result.errors)
        self.tmp = tempfile.TemporaryDirectory(prefix='cloud-sync-test-')
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / 'home'
        self.base = self.home / '.local/share/remoteagents-cloud'
        self.base.mkdir(parents=True)
        shutil.copytree(self.cachebase / 'tools', self.base / 'tools')
        self.local = self.home / 'Disk'
        self.local.mkdir()
        self.remote = Path(self.tmp.name) / 'webdav'
        self.remote.mkdir()
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        self.url = 'http://127.0.0.1:' + str(port)
        self.webdav = subprocess.Popen([str(self.rclone), '--config', os.devnull, 'serve', 'webdav', str(self.remote),
                                      '--dir-cache-time', '0s', '--poll-interval', '0s',
                                      '--addr', '127.0.0.1:' + str(port), '--user', 'test-user', '--pass', PASSWORD],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # Test fixture server argv intentionally uses --user/--pass as requested;
        # product processes are checked separately below.
        self.addCleanup(self.stop_webdav)
        def listening():
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=0.2):
                    return True
            except OSError:
                return False
        wait_for(listening, description='WebDAV listening')
        self.manager = FakeSystemd(self.home, self.base)
        self.addCleanup(self.manager.stop)
        self.patches = contextlib.ExitStack()
        self.addCleanup(self.patches.close)
        for name, value in [('HOME', self.home), ('BASE', self.base),
                            ('UNIT_PATH', self.home / '.config/systemd/user' / cloud.UNIT),
                            ('PROVIDERS', {'mailru': {'type': 'webdav', 'url': self.url, 'vendor': 'owncloud'}}),
                            ('systemctl', self.manager)]:
            self.patches.enter_context(patch.object(cloud, name, value))
        self.cfg = {'vendor': 'mailru', 'login': 'test-user', 'password': PASSWORD,
                    'remoteRoot': 'Exchange', 'localRoot': '~/Disk', 'pollSeconds': 3600}

    def stop_webdav(self):
        self.webdav.terminate()
        self.webdav.wait(timeout=10)

    def tearDown(self):
        if len(self._outcome.result.failures) + len(self._outcome.result.errors) > self.failures_before:
            self.manager.stop()
            print('DIAGNOSTIC STATUS:', json.dumps(self.status(), ensure_ascii=False), flush=True)
            log = self.base / 'logs/cloud.log'
            if log.exists():
                print('\n'.join(line[:1000] for line in log.read_text().splitlines()[-25:]), flush=True)
            print('REMOTE', list(self.remote.rglob('from-cloud.txt')), flush=True)
            print('LOCAL', list(self.local.rglob('from-cloud.txt')), flush=True)

    def status(self):
        return cloud.read_json(self.base / 'status.json', {})

    def healthy(self, project='Проект один'):
        return self.status().get('projects', {}).get(project, {}).get('result') == 'ok'

    def put(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)
        # owncloud modtime precision is one second; force distinct time for same-size edits.
        stamp = time.time() + 3
        os.utime(path, (stamp, stamp))

    def test_end_to_end_events_poll_delete_filters_idempotency_remove(self):
        project = self.local / 'Проект один'
        project.mkdir()
        self.put(project / 'file.txt', 'aaaa')
        self.put(self.local / 'Второй/second.txt', 'second')
        for name in ('.env', '.ENV.local', 'node_modules/pkg/a.js', '.git/config', 'storage/app/private.txt'):
            self.put(project / name, 'local excluded')
        remote_project = self.remote / 'Exchange/Проект один'
        for name in ('.env', 'node_modules/remote.js', '.git/config'):
            self.put(remote_project / name, 'remote excluded')
        self.put(self.remote / 'Exchange/Только облако/cloud.txt', 'discovered')
        result = cloud.apply(self.cfg)
        self.assertTrue(result['ok'])
        wait_for(lambda: self.healthy() and self.healthy('Второй') and self.healthy('Только облако'),
                 seconds=40, description='initial bisync')
        self.assertEqual(content(remote_project / 'file.txt'), 'aaaa')
        self.assertEqual(self.status()['projects']['Проект один']['transferred'], 1)
        self.assertEqual(self.status()['projects']['Проект один']['bytes'], 4)
        self.assertEqual(content(self.local / 'Только облако/cloud.txt'), 'discovered')
        for name in ('.ENV.local', 'node_modules/pkg/a.js', 'storage/app/private.txt'):
            self.assertFalse((remote_project / name).exists(), name)
        self.assertEqual(content(remote_project / '.env'), 'remote excluded')
        self.assertEqual(content(project / '.env'), 'local excluded')
        self.assertEqual(content(remote_project / '.git/config'), 'remote excluded')
        (project / '.env').unlink()
        (project / '.git/config').unlink()
        (project / 'node_modules/pkg/a.js').unlink()
        # No timer can help: poll interval is one hour. Check that another project is untouched.
        second_before = self.status()['projects']['Второй']['finishedAt']
        before = time.monotonic()
        self.put(project / 'file.txt', 'bbbb')
        wait_for(lambda: content(remote_project / 'file.txt') == 'bbbb' and self.healthy(), seconds=10, description='event same-size upload')
        elapsed = time.monotonic() - before
        self.assertEqual(self.status()['projects']['Второй']['finishedAt'], second_before)
        print('EVENT: same-size upload %.2fs, pollSeconds=3600, other project untouched' % elapsed, flush=True)
        (project / 'file.txt').unlink()
        wait_for(lambda: not (remote_project / 'file.txt').exists() and self.healthy(), seconds=10, description='local deletion')
        self.assertEqual(self.status()['projects']['Проект один']['deleted'], 1)
        self.assertTrue((remote_project / '.env').exists())
        self.assertTrue((remote_project / '.git/config').exists())
        self.assertTrue((remote_project / 'node_modules/remote.js').exists())
        # Rename, move-in directory, then mass deletions (all-files-changed protection must be off).
        for i in range(3):
            self.put(project / ('many/' + str(i) + '.txt'), str(i))
        wait_for(lambda: (remote_project / 'many/2.txt').exists() and self.healthy(), seconds=10, description='new directory')
        shutil.rmtree(project / 'many')
        wait_for(lambda: not (remote_project / 'many/2.txt').exists() and self.healthy(), seconds=10, description='all-files deletion')
        # Reapply must keep bisync listings and initialized markers, then poll cloud changes.
        initialized = {p: p.read_bytes() for p in (self.base / 'state').glob('*/initialized')}
        # The obsolete header was documentation only: migrate its stored hash,
        # preserving actual bisync listings. Changed rules must still be refused.
        template = SCRIPT.with_name('filter.txt').read_text()
        legacy = template.replace('# Исключения облачных проектов:',
                                  '# Исключения Диска (как disk/stignore.txt):', 1)
        stored = cloud.read_json(self.base / 'config.json')
        stored['filterSha256'] = hashlib.sha256(legacy.encode()).hexdigest()
        cloud.write_json(self.base / 'config.json', stored)
        (self.base / 'filter.txt').write_text(legacy)
        self.cfg['pollSeconds'] = 2
        self.assertTrue(cloud.apply(self.cfg)['ok'])
        self.assertEqual(cloud.read_json(self.base / 'config.json')['filterSha256'],
                         hashlib.sha256(template.encode()).hexdigest())
        for path, value in initialized.items():
            self.assertEqual(path.read_bytes(), value)
        wait_for(lambda: self.status().get('state') == 'watching', seconds=20)
        self.put(remote_project / 'from-cloud.txt', '1111')
        wait_for(lambda: content(project / 'from-cloud.txt') == '1111' and self.healthy(), description='cloud poll download')
        self.put(remote_project / 'from-cloud.txt', '2222')
        wait_for(lambda: content(project / 'from-cloud.txt') == '2222' and self.healthy(), description='cloud same-size download')
        (remote_project / 'from-cloud.txt').unlink()
        wait_for(lambda: not (project / 'from-cloud.txt').exists(), description='cloud deletion')
        # Whole-project deletion: retain listings and reconstruct an empty root to propagate it.
        shutil.rmtree(self.remote / 'Exchange/Второй')
        wait_for(lambda: not (self.local / 'Второй/second.txt').exists(), description='whole remote project deletion')
        shutil.rmtree(self.local / 'Только облако')
        wait_for(lambda: not (self.remote / 'Exchange/Только облако/cloud.txt').exists(), description='whole local project deletion')
        # Actual second process competes for the same flock, even across workers.
        contender = subprocess.run(['bash', str(self.base / 'server-cloud.sh'), '_run'],
                                   env=dict(os.environ, HOME=str(self.home)), capture_output=True, text=True, timeout=10)
        self.assertNotEqual(contender.returncode, 0)
        self.assertIn('другим процессом', contender.stderr)
        ps = subprocess.run(['ps', '-eo', 'pid,args'], text=True, capture_output=True, check=True).stdout
        product_rows = '\n'.join(row for row in ps.splitlines() if str(self.base) in row)
        self.assertNotIn(PASSWORD, product_rows)
        logs = '\n'.join(p.read_text() for p in (self.base / 'logs').glob('*'))
        self.assertNotIn(PASSWORD, logs)
        self.assertNotIn(PASSWORD, (self.base / 'rclone.conf').read_text())
        self.assertEqual((self.base / 'rclone.conf').stat().st_mode & 0o777, 0o600)
        self.assertTrue(any(p.get('transferred', 0) or p.get('deleted', 0) for p in self.status()['projects'].values()) or 'передано=' in logs)
        self.assertRegex(logs, r'передано=[1-9]')
        self.assertRegex(logs, r'удалено=[1-9]')
        active = 0
        for line in logs.splitlines():
            if 'начало (' in line:
                active += 1
                self.assertEqual(active, 1, 'overlapping sync passes')
            elif 'передано=' in line:
                active -= 1
        self.assertEqual(active, 0)
        data_before = {str(p.relative_to(self.local)): p.read_bytes() for p in self.local.rglob('*') if p.is_file()}
        remote_before = {str(p.relative_to(self.remote)): p.read_bytes() for p in self.remote.rglob('*') if p.is_file()}
        self.assertTrue(cloud.remove()['ok'])
        self.assertFalse(self.base.exists())
        self.assertFalse(cloud.UNIT_PATH.exists())
        self.assertEqual(data_before, {str(p.relative_to(self.local)): p.read_bytes() for p in self.local.rglob('*') if p.is_file()})
        self.assertEqual(remote_before, {str(p.relative_to(self.remote)): p.read_bytes() for p in self.remote.rglob('*') if p.is_file()})
        self.assertTrue(cloud.remove()['ok'])
        print('BISYNC: initial upload, cloud discovery/poll, same-size both ways, deletions both ways/all/whole project, filters, flock, apply/remove, secrets OK', flush=True)

    def test_validation_and_installer_failures(self):
        self.assertEqual(cloud.validate(dict(self.cfg, pollSeconds=20))['pollSeconds'], 20)
        for field, value in [('vendor', 'unknown'), ('localRoot', '~'), ('localRoot', str(self.base)),
                             ('remoteRoot', '../other'), ('login', 'x\npass = bad'), ('pollSeconds', False)]:
            with self.subTest(field=field, value=value), self.assertRaises(cloud.Error):
                cloud.validate(dict(self.cfg, **{field: value}))
        with patch.object(cloud, 'inotify_binary', return_value=None), patch.object(cloud.shutil, 'which', return_value=None):
            with self.assertRaisesRegex(cloud.Error, 'Не найден inotifywait'):
                cloud.install_inotify()
        with patch.object(cloud, 'BASE', self.home / 'bad-download'):
            cloud.BASE.mkdir()
            def bad_download(url, dest):
                dest.write_text('0' * 64 + '  rclone-v' + cloud.VERSION + '-linux-amd64.zip\n')
            with patch.object(cloud, 'download', side_effect=bad_download), self.assertRaisesRegex(cloud.Error, 'SHA256SUMS'):
                cloud.install_rclone()
        self.base.joinpath('state').mkdir()
        stored = cloud.validate(self.cfg)
        stored['filterSha256'] = '0' * 64
        cloud.write_json(self.base / 'config.json', stored)
        with self.assertRaisesRegex(cloud.Error, 'Изменился фильтр'):
            cloud.apply(self.cfg)

    def test_preexisting_equal_size_different_modtime(self):
        project = self.local / 'Existing'
        remote = self.remote / 'Exchange/Existing'
        self.put(project / 'file.txt', 'same')
        self.put(remote / 'file.txt', 'same')
        os.utime(project / 'file.txt', (1700000000, 1700000000))
        os.utime(remote / 'file.txt', (1800000000, 1800000000))
        cloud.apply(self.cfg)
        wait_for(lambda: self.healthy('Existing'), description='existing files initial pass')
        # A second unchanged pass and restart must keep valid bisync listings.
        cloud.apply(self.cfg)
        wait_for(lambda: self.healthy('Existing') and self.status().get('state') == 'watching',
                 description='existing files after restart')
        self.put(project / 'file.txt', 'edit')
        wait_for(lambda: content(remote / 'file.txt') == 'edit' and self.healthy('Existing'),
                 seconds=10, description='existing file same-size edit')

    def test_crlf_json_stdin_and_cli_status(self):
        # A fake systemctl executable exercises the *real* shell stdin/fd3 contract.
        fakebin = self.home / 'fakebin'
        fakebin.mkdir()
        ctl = fakebin / 'systemctl'
        ctl.write_text('#!/bin/sh\nexit 0\n')
        ctl.chmod(0o755)
        helper = self.home / 'helper'
        helper.mkdir()
        # Invalid vendor ensures no external connection, while passing CRLF JSON via fd3.
        data = json.dumps(dict(self.cfg, vendor='unsupported'), indent=2).replace('\n', '\r\n') + '\r\n'
        env = dict(os.environ, HOME=str(self.home), PATH=str(fakebin) + ':' + os.environ['PATH'])
        bad = subprocess.run(['bash', str(SCRIPT), 'apply'], input=data, env=env, text=True, capture_output=True)
        self.assertNotEqual(bad.returncode, 0)
        self.assertEqual(bad.stderr.splitlines()[0], 'Неизвестный провайдер облака.')
        self.assertNotIn(PASSWORD, bad.stdout + bad.stderr)
        reply = subprocess.run(['bash', str(SCRIPT), 'status'], env=env, text=True, capture_output=True, check=True)
        self.assertEqual(json.loads(reply.stdout)['state'], 'not-configured')
        valid = json.dumps(self.cfg, indent=2).replace('\n', '\r\n') + '\r\n'
        applied = subprocess.run(['bash', str(SCRIPT), 'apply'], input=valid, env=env, text=True, capture_output=True, timeout=30)
        self.assertEqual(applied.returncode, 0, applied.stderr)
        self.assertTrue(json.loads(applied.stdout)['ok'])
        self.assertEqual(cloud.read_json(self.base / 'config.json')['localRoot'], str(self.local))
        verify = subprocess.run(['systemd-analyze', '--user', 'verify', str(cloud.UNIT_PATH)], text=True, capture_output=True)
        self.assertEqual(verify.returncode, 0, verify.stderr)

    def test_wizard_upload_and_apply_contract(self):
        """Real PS dispatcher -> SSH stdin -> deployed shell helper; no cloud connection."""
        repo = SCRIPT.parents[1]
        pwsh = os.environ.get('PWSH') or str(Path.home() / '.cache/pwsh-test/pwsh')
        # Only the service manager and SSH network are stand-ins. The cached real
        # rclone/inotify tools from setUpClass run in our temporary server HOME.
        fakebin = self.home / 'fakebin'
        fakebin.mkdir()
        ctl = fakebin / 'systemctl'
        ctl.write_text('#!/bin/sh\nexit 0\n')
        ctl.chmod(0o755)
        ssh = fakebin / 'ssh'
        ssh.write_text('''#!/usr/bin/env python3
import subprocess, sys
assert 'fake-cloud-password' not in ' '.join(sys.argv)
data = sys.stdin.buffer.read()
assert b'\\r' not in data
result = subprocess.run(['bash', '-c', sys.argv[-1]], input=data)
sys.exit(result.returncode)
''')
        ssh.chmod(0o755)
        # Exercise a Windows checkout's CRLF through Send-WizardHelpers, too.
        bundle = self.home / 'bundle'
        sources = ('build/server-wizard.sh', 'transport/server-transport-catalog.py',
                   'accounts/server-account.mjs', 'accounts/bootstrap.sh',
                   'cloud/server-cloud.sh', 'cloud/filter.txt', 'codex-windows-bridge.py',
                   'codex-bridge-session.py', 'server_node_catalog.py')
        for name in sources:
            target = bundle / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((repo / name).read_bytes().replace(b'\r', b'').replace(b'\n', b'\r\n'))
        script = self.home / 'contract.ps1'
        script.write_text('''$ErrorActionPreference='Stop'
. (Join-Path $env:RA_CONTRACT_REPO 'build/Wizard.Common.ps1')
function Invoke-WizardSsh($Root,$Command,$InputText='') {
    Invoke-DiskProcess $env:RA_CONTRACT_SSH @($Command) (Convert-TransportLF $InputText)
}
Send-WizardHelpers $env:HOME $env:RA_CONTRACT_BUNDLE
$helper=Join-Path $env:HOME '.local/share/remoteagents-cloud/server-cloud.sh'
$filter=Join-Path $env:HOME '.local/share/remoteagents-cloud/filter.txt'
$stamp=[IO.File]::GetLastWriteTimeUtc($helper)
Send-WizardHelpers $env:HOME $env:RA_CONTRACT_BUNDLE
if([IO.File]::GetLastWriteTimeUtc($helper) -ne $stamp){throw 'unchanged helper was uploaded again'}
[IO.File]::WriteAllText($filter,'corrupted filter')
Send-WizardHelpers $env:HOME $env:RA_CONTRACT_BUNDLE
if([IO.File]::GetLastWriteTimeUtc($helper) -ne $stamp){throw 'filter repair rewrote the helper'}
$script:profile=[pscustomobject]@{sshExecutable=$env:RA_CONTRACT_SSH;arguments=@()}
function Find-InstallProfile($Root){return 'fixture'}
function Read-TransportJson($Path){return $script:profile}
function Get-TransportSavedRouteOptions($Root,$Profile){return @()}
function Read-WizardRelay($Name){return $script:payload}
# Same six fields as CloudApply (also asserted independently in CloudTests.cs).
$script:payload=@{vendor='mailru';login='user@mail.ru';password='fake-cloud-password';remoteRoot='Диск';localRoot='~/Disk';pollSeconds=37}|ConvertTo-Json
$script:payload=$script:payload.Replace("`r`n","`n").Replace("`n","`r`n")+"`r`n"
$result=Invoke-WizardStep $env:HOME $env:RA_CONTRACT_BUNDLE 'Cloud' ([pscustomobject]@{secretPipe='fixture'})
if($result.exitCode -ne 0 -or $result.stdout -ne '{"ok":true}'){throw ($result|ConvertTo-Json -Compress)}
$script:payload=$script:payload.Replace('mailru','unsupported')
$bad=Invoke-WizardCloud $env:HOME ([pscustomobject]@{secretPipe='fixture'})
if($bad.exitCode -eq 0 -or $bad.stdout -ne '{"ok":false}'){throw 'invalid provider accepted'}
if($bad.stderr -ne 'Неизвестный провайдер облака.'){throw 'server error contract lost'}
$result|ConvertTo-Json -Compress
''', encoding='utf-8-sig', newline='\r\n')
        env = dict(os.environ, HOME=str(self.home), LOCALAPPDATA=str(self.home / 'appdata'),
                   PATH=str(fakebin) + os.pathsep + os.environ['PATH'],
                   RA_CONTRACT_REPO=str(repo), RA_CONTRACT_SSH=str(ssh), RA_CONTRACT_BUNDLE=str(bundle))
        result = subprocess.run([pwsh, '-NoProfile', '-NonInteractive', '-File', str(script)],
                                env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(json.loads(result.stdout)['stdout'], '{"ok":true}')
        for name in ('server-cloud.sh', 'filter.txt'):
            self.assertEqual((self.base / name).read_bytes(),
                             (SCRIPT.parent / name).read_bytes().replace(b'\r', b''))
        cfg = cloud.read_json(self.base / 'config.json')
        self.assertEqual((cfg['vendor'], cfg['localRoot'], cfg['remoteRoot'], cfg['pollSeconds']),
                         ('mailru', str(self.local), 'Диск', 37))
        self.assertFalse((self.home / '.local/share/remote-disk').exists())
        self.assertFalse(list((self.home / '.local/share').rglob('*.tmp')))
        self.assertNotIn('fake-cloud-password', (self.base / 'rclone.conf').read_text())
        print('CONTRACT: CRLF upload, hash probe/reupload, Wizard.Cloud -> deployed server-cloud.sh apply stdin, ok:true/error OK', flush=True)

    def test_log_rotation_and_safe_diagnostics(self):
        cloud.setup_log()
        for _ in range(12):
            cloud.LOG.info('x' * 400000)
        files = list((self.base / 'logs').glob('cloud.log*'))
        self.assertLessEqual(len(files), 4)
        self.assertTrue(any(p.suffix == '.1' for p in files))
        self.assertNotIn(PASSWORD, cloud.safe_error('401 ' + PASSWORD))
        self.assertNotIn(PASSWORD, cloud.safe_error('untrusted ' + PASSWORD))
        for handler in cloud.LOG.handlers:
            handler.close()
        cloud.LOG.handlers.clear()

    def test_real_user_unit_and_restart_with_temporary_roots(self):
        def ctl(*args, check=True):
            return subprocess.run(['systemctl', '--user', *args], text=True, capture_output=True, check=check, timeout=40)
        if ctl('show-environment', check=False).returncode:
            self.skipTest('user systemd недоступен; основной тест использует fake systemctl')
        self.put(self.local / 'RealUnit/file.txt', 'initial')
        cloud.apply(self.cfg)
        self.manager.stop()
        name = 'remoteagents-cloud-test-' + str(os.getpid()) + '.service'
        unit = self.home / name
        # Exercise the generated unit, with ONLY HOME redirected to our disposable fixture.
        text = cloud.unit_text().replace('[Service]\n', '[Service]\nEnvironment=HOME=' + str(self.home) + '\n')
        unit.write_text(text)
        def cleanup():
            ctl('stop', name, check=False)
            ctl('disable', '--runtime', name, check=False)
            ctl('reset-failed', name, check=False)
            ctl('daemon-reload', check=False)
        self.addCleanup(cleanup)
        ctl('link', '--runtime', str(unit))
        ctl('daemon-reload')
        ctl('start', name)
        target = self.remote / 'Exchange/RealUnit/file.txt'
        wait_for(lambda: content(target) == 'initial' and self.healthy('RealUnit'), description='real user unit first upload')
        pid = ctl('show', '-p', 'MainPID', '--value', name).stdout.strip()
        ctl('kill', '--kill-whom=main', '--signal=KILL', name)
        wait_for(lambda: ctl('show', '-p', 'MainPID', '--value', name).stdout.strip() not in ('0', pid),
                 seconds=20, description='systemd automatic restart')
        wait_for(lambda: self.status().get('state') == 'watching', description='restarted watcher ready')
        self.put(self.local / 'RealUnit/file.txt', 'changed')
        wait_for(lambda: content(target) == 'changed' and self.healthy('RealUnit'), seconds=10,
                 description='real user unit event after restart')
        ctl('stop', name)
        self.assertEqual(ctl('is-active', '--quiet', name, check=False).returncode, 3)
        self.assertEqual(content(target), 'changed')
        print('SYSTEMD: generated user unit, temporary HOME/Disk, SIGKILL -> automatic restart, event sync OK', flush=True)


if __name__ == '__main__':
    unittest.main(verbosity=2)
