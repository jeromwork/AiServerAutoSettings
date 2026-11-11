#!/usr/bin/env python3
"""Real rootless sshd, loopback only. All writable paths live in TemporaryDirectory.
No sudo, useradd, systemd, or access to real authorized_keys in this suite.
"""
import concurrent.futures
import importlib.util
import io
import json
import os
from pathlib import Path
import pwd
import socket
import socketserver
import select
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
MODULE = ROOT / 'server/invite.py'
spec = importlib.util.spec_from_file_location('invite', MODULE)
invite = importlib.util.module_from_spec(spec)
spec.loader.exec_module(invite)


def command(args, **kw):
    return subprocess.run([str(x) for x in args], capture_output=True, timeout=60, **kw)


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


class Bench:
    def __init__(self, directory):
        self.dir = Path(directory)
        self.port = free_port()
        self.user = pwd.getpwuid(os.getuid()).pw_name
        self.key = self.dir / 'host'
        assert command(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', self.key]).returncode == 0
        self.own = self.dir / 'device'
        assert command(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', self.own]).returncode == 0
        self.pub = self.own.with_suffix('.pub').read_bytes()
        self.exe = self.dir / 'RemoteAgents.exe'
        self.exe.write_bytes(b'MZ-test-unchanged-exe')
        self.cfg = self.dir / 'config.json'
        self.c = dict(schema=1, version=1, sandbox=True, serverAddress='127.0.0.1', serverPort=self.port,
                      hostKeys=[' '.join(self.key.with_suffix('.pub').read_text().split()[:2])],
                      workerUser=self.user, enrollUser=self.user, enrollHelper=str(self.dir / 'enroll'),
                      workerAuthorizedKeys=str(self.dir / 'worker_keys'), enrollAuthorizedKeys=str(self.dir / 'pass_keys'),
                      stateDir=str(self.dir / 'invites'), outputDir=str(self.dir / 'zips'), releaseExe=str(self.exe),
                      routes=[dict(kind='direct')], publishNodes={})
        self.cfg.write_text(json.dumps(self.c))
        self.known = self.dir / 'known_hosts'
        self.known.write_text('[127.0.0.1]:' + str(self.port) + ' ' + self.c['hostKeys'][0] + '\n')
        self.sshd_config = self.dir / 'sshd_config'
        self.sshd_config.write_text(f'''ListenAddress 127.0.0.1
Port {self.port}
HostKey {self.key}
PidFile {self.dir}/sshd.pid
AuthorizedKeysFile {self.c['enrollAuthorizedKeys']} {self.c['workerAuthorizedKeys']}
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers {self.user}
AllowTcpForwarding yes
AllowAgentForwarding yes
X11Forwarding yes
PermitTTY yes
LogLevel DEBUG1
''')
        (self.dir / 'home').mkdir()
        with self.sshd_config.open('a') as config_file:
            config_file.write('SetEnv HOME='+str(self.dir / 'home')+' XDG_CONFIG_HOME='+str(self.dir / 'home/.config')+'\n')
        self.log = (self.dir / 'sshd.log').open('w')
        self.server = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(self.sshd_config)], stdout=self.log, stderr=self.log)
        for _ in range(100):
            try:
                with socket.create_connection(('127.0.0.1', self.port), .1):
                    break
            except OSError:
                if self.server.poll() is not None:
                    raise RuntimeError((self.dir / 'sshd.log').read_text())
                time.sleep(.02)
        else:
            raise RuntimeError('isolated sshd did not start')

    def close(self):
        self.server.terminate()
        self.server.wait(timeout=5)
        self.log.close()

    def cli(self, *args, **kw):
        return command([sys.executable, '-I', MODULE, '--config', self.cfg, *args], **kw)

    def create(self, *extra):
        p = self.cli('create', '--name', 'Ноутбук', *extra)
        assert p.returncode == 0, p.stdout.decode() + p.stderr.decode()
        archive = Path(p.stdout.decode().splitlines()[1])
        with zipfile.ZipFile(archive) as z:
            assert z.read('RemoteAgents.exe') == self.exe.read_bytes()
            obj = json.loads(z.read('invite.rainvite'))
        key = self.dir / ('pass-' + obj['id'])
        key.write_text(obj['passKey'])
        key.chmod(0o600)
        return obj, key, archive

    def ssh(self, key, payload=b'', remote='enroll', extra=(), timeout=30):
        args = ['ssh', '-F', '/dev/null', '-T', '-p', self.port, '-i', key, '-o', 'IdentitiesOnly=yes',
                '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'GlobalKnownHostsFile=none',
                '-o', 'UserKnownHostsFile=' + str(self.known), '-o', 'ConnectTimeout=3', *extra,
                self.user + '@127.0.0.1', remote]
        return subprocess.run([str(x) for x in args], input=payload, capture_output=True, timeout=timeout)


class Proxy(socketserver.BaseRequestHandler):
    def handle(self):
        header = b''
        while not header.endswith(b'\r\n\r\n'):
            part = self.request.recv(1)
            if not part:
                return
            header += part
        with socket.create_connection(('127.0.0.1', self.server.target_port), 3) as upstream:
            self.request.sendall(b'HTTP/1.1 200 Connection established\r\n\r\n')
            while True:
                ready, _, _ = select.select([self.request, upstream], [], [], 15)
                if not ready:
                    return
                for source in ready:
                    data = source.recv(16384)
                    if not data:
                        return
                    (upstream if source is self.request else self.request).sendall(data)


class InviteTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ra-invite-')
        self.b = Bench(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self.b.close)

    def test_once_and_own_key_login(self):
        obj, key, archive = self.b.create()
        first = self.b.ssh(key, self.b.pub.replace(b'\n', b'\r\n'))
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertTrue(json.loads(first.stdout)['ok'])
        self.assertNotEqual(self.b.ssh(key, self.b.pub).returncode, 0)
        own = self.b.ssh(self.b.own, remote='printf own-key-ok')
        self.assertEqual(own.stdout, b'own-key-ok')
        self.assertEqual(own.returncode, 0)
        self.assertIn('ra-device:Ноутбук', Path(self.b.c['workerAuthorizedKeys']).read_text())
        self.assertEqual(archive.stat().st_mode & 0o777, 0o600)
        listing = self.b.cli('list').stdout
        self.assertIn(b'used', listing)
        self.assertNotIn(b'PRIVATE', listing)
        print('PASS invite: one use; CRLF ed25519; own-key login; ZIP EXE unchanged; secret permissions')

    def test_two_concurrent_exactly_one(self):
        _, key, _ = self.b.create()
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            results = list(pool.map(lambda _: self.b.ssh(key, self.b.pub), range(2)))
        self.assertEqual(sum(p.returncode == 0 for p in results), 1)
        self.assertEqual(len(Path(self.b.c['workerAuthorizedKeys']).read_text().splitlines()), 1)
        print('PASS invite: 2 concurrent attempts -> exactly 1 success')

    def test_expired_openssh_and_helper(self):
        obj, key, _ = self.b.create('--hours', '0.0001')
        time.sleep(1.1)
        self.assertNotEqual(self.b.ssh(key, self.b.pub).returncode, 0)
        helper = self.b.cli('enroll', obj['id'], input=self.b.pub)
        self.assertNotEqual(helper.returncode, 0)
        self.assertIn('истёк', helper.stdout.decode())
        self.assertFalse(Path(self.b.c['workerAuthorizedKeys']).exists())

    def test_revoke_and_create_idempotent(self):
        obj, key, _ = self.b.create()
        second, second_key, _ = self.b.create()
        self.assertEqual(len(Path(self.b.c['enrollAuthorizedKeys']).read_text().splitlines()), 2)
        self.assertEqual(self.b.cli('revoke', obj['id']).returncode, 0)
        self.assertNotEqual(self.b.ssh(key, self.b.pub).returncode, 0)
        self.assertEqual(self.b.ssh(second_key, self.b.pub).returncode, 0)
        # Sandbox provisions no actual user; production idempotence is separately exercised by mocked OS calls.

    def test_invalid_keys_no_enrollment(self):
        for payload in (b'garbage\n', self.b.pub + self.b.pub, b'ssh-rsa AAAA\r\n', b'ssh-ed25519 AAAA\n', self.b.pub + b'\n'):
            obj, key, _ = self.b.create()
            with self.subTest(payload=payload[:20]):
                self.assertNotEqual(self.b.ssh(key, payload).returncode, 0)
                self.assertEqual(invite.load(invite.entry(self.b.c, obj['id']))['status'], 'open')
        self.assertFalse(Path(self.b.c['workerAuthorizedKeys']).exists())

    def test_no_shell_forward_agent_x11_or_pty(self):
        obj, key, _ = self.b.create()
        # Arbitrary requested shell command is ignored: only enroll JSON can be returned.
        p = self.b.ssh(key, b'bad\n', remote='printf SHELL-ESCAPE')
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn(b'SHELL-ESCAPE', p.stdout)
        # -W requests direct-tcpip without a session: restrict must deny it.
        p = self.b.ssh(key, extra=('-W', '127.0.0.1:' + str(self.b.port)))
        self.assertNotEqual(p.returncode, 0)
        self.assertIn(b'administratively prohibited', p.stderr)
        p = self.b.ssh(key, b'bad\n', extra=('-vv', '-A', '-X', '-tt'))
        text = p.stderr.decode()
        self.assertIn('PTY allocation request failed', text)
        self.assertNotIn('SHELL-ESCAPE', p.stdout.decode())
        # sshd's effective per-key restrictions, independent of local DISPLAY/agent availability.
        logs = (self.b.dir / 'sshd.log').read_text()
        options = [x for x in logs.splitlines() if 'key options:' in x]
        self.assertTrue(options, logs)
        for row in options:
            self.assertNotIn('agent-forwarding', row)
            self.assertNotIn('x11-forwarding', row)
            self.assertNotIn('port-forwarding', row)
        self.assertEqual(invite.load(invite.entry(self.b.c, obj['id']))['status'], 'open')
        print('PASS invite: forced command; TCP forwarding/PTY/agent/X11 restricted by real sshd')

    def test_reservation_recovery_and_symlink_refusal(self):
        obj, key, _ = self.b.create()
        p = invite.entry(self.b.c, obj['id'])
        data = invite.load(p)
        data.update(status='reserved', reservedKey=invite.public_key(self.b.pub))
        invite.save(p, data)
        self.assertEqual(self.b.ssh(key, self.b.pub).returncode, 0)
        obj, key, _ = self.b.create()
        auth = Path(self.b.c['workerAuthorizedKeys'])
        auth.unlink()
        victim = self.b.dir / 'victim'
        victim.write_text('unchanged')
        auth.symlink_to(victim)
        self.assertNotEqual(self.b.ssh(key, self.b.pub).returncode, 0)
        self.assertEqual(victim.read_text(), 'unchanged')

    def test_publish_one_get_expiry(self):
        self.b.c['publishNodes']['local'] = dict(directory=str(self.b.dir / 'downloads'), baseUrl='https://download.example.invalid/invites')
        c = self.b.c
        payload = json.dumps({'expiresEpoch': time.time()+30}).encode() + b'\nPK-test'
        url = invite.receive(c, 'local', io.BytesIO(payload))
        token = url.rsplit('/', 1)[1]
        server = invite.http.server.ThreadingHTTPServer(('127.0.0.1', 0), invite.Downloads)
        server.directory = c['publishNodes']['local']['directory']
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        local = 'http://127.0.0.1:' + str(server.server_address[1]) + '/' + token
        # Ignore inherited proxies: this client talks only to loopback.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.assertEqual(opener.open(local).read(), b'PK-test')
        with self.assertRaises(urllib.error.HTTPError):
            opener.open(local)
        self.assertFalse((Path(server.directory) / token).exists())
        url = invite.receive(c, 'local', io.BytesIO(payload))
        token = url.rsplit('/', 1)[1]
        invite.save(Path(server.directory) / token.replace('.zip', '.json'), {'expiresEpoch': time.time()-1})
        with self.assertRaises(urllib.error.HTTPError):
            opener.open(local.rsplit('/', 1)[0]+'/'+token)
        self.assertFalse((Path(server.directory) / token).exists())

    def test_exe_production_invite_flow_real_sshd(self):
        dotnet = Path.home() / '.dotnet/dotnet'
        build = command([dotnet, 'build', ROOT / 'app/launcher/tests/PortableTests.csproj', '-c', 'Release', '--nologo'])
        self.assertEqual(build.returncode, 0, build.stdout.decode()+build.stderr.decode())
        proxy = socketserver.ThreadingTCPServer(('127.0.0.1', 0), Proxy)
        proxy.daemon_threads = True
        proxy.target_port = self.b.port
        threading.Thread(target=proxy.serve_forever, daemon=True).start()
        self.addCleanup(proxy.server_close)
        self.addCleanup(proxy.shutdown)
        relay = self.b.dir / 'relay'
        import shlex
        dll = ROOT / 'app/launcher/tests/bin/Release/net10.0/PortableTests.dll'
        relay.write_text('#!/bin/sh\nexec '+shlex.quote(str(dotnet))+' '+shlex.quote(str(dll))+' "$@"\n')
        relay.chmod(0o700)
        self.b.c['serverAddress'] = '127.0.0.2'  # no listener: direct route refuses
        self.b.c['routes'].append(dict(kind='proxy', proxy=dict(type='http', host='127.0.0.1', port=proxy.server_address[1])))
        self.b.cfg.write_text(json.dumps(self.b.c))
        obj, _, _ = self.b.create()
        path = self.b.dir / 'invite.rainvite'
        # Full CRLF invitation and pass key exercise the Windows->Linux boundary.
        path.write_bytes(json.dumps(obj, ensure_ascii=False, indent=2).replace('\n', '\r\n').encode())
        script = ROOT / 'app/launcher/tests/test-invite.ps1'
        pwsh = Path.home() / '.cache/pwsh-test/pwsh'
        args = [pwsh, '-NoProfile', '-NonInteractive', '-File', script, '-TestHome', self.b.dir / 'client', '-InvitePath', path, '-Relay', relay]
        result = command(args)
        self.assertEqual(result.returncode, 0, result.stdout.decode()+result.stderr.decode())
        self.assertEqual(invite.load(invite.entry(self.b.c, obj['id']))['status'], 'used')
        print(result.stdout.decode().strip())
        args[args.index('-TestHome')+1] = self.b.dir / 'other-client'
        result = command([*args, '-ExpectedFailure', 'used'])
        self.assertEqual(result.returncode, 0, result.stdout.decode()+result.stderr.decode())
        print(result.stdout.decode().strip())
        # Another unused invitation with an unrelated host key must stop before registration.
        obj, _, _ = self.b.create()
        other = self.b.dir / 'other-host'
        command(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', other])
        obj['hostKeys'] = [' '.join(other.with_suffix('.pub').read_text().split()[:2])]
        path.write_text(json.dumps(obj))
        args[args.index('-TestHome')+1] = self.b.dir / 'untrusted-client'
        result = command([*args, '-HostMismatch'])
        self.assertEqual(result.returncode, 0, result.stdout.decode()+result.stderr.decode())
        self.assertEqual(invite.load(invite.entry(self.b.c, obj['id']))['status'], 'open')
        print(result.stdout.decode().strip())
        obj['expiresUtc'] = '2000-01-01T00:00:00Z'
        obj['hostKeys'] = self.b.c['hostKeys']
        path.write_text(json.dumps(obj))
        args[args.index('-TestHome')+1] = self.b.dir / 'expired-client'
        result = command([*args, '-ExpectedFailure', 'expired'])
        self.assertEqual(result.returncode, 0, result.stdout.decode()+result.stderr.decode())
        self.assertEqual(invite.load(invite.entry(self.b.c, obj['id']))['status'], 'open')
        print(result.stdout.decode().strip())

    def test_production_invite_through_key_hop(self):
        Path(self.b.c['workerAuthorizedKeys']).write_bytes(self.b.pub)
        self.b.c['routes'] = [dict(kind='hop', hop=dict(name='fixture', ssh=self.b.user+'@127.0.0.1:'+str(self.b.port), hostKey=self.b.c['hostKeys'][0], keyFile=str(self.b.own)))]
        self.b.cfg.write_text(json.dumps(self.b.c))
        obj, _, _ = self.b.create()
        self.assertIn('privateKey', obj['routes'][0]['hop'])
        self.assertNotIn('keyFile', obj['routes'][0]['hop'])
        path = self.b.dir / 'hop.rainvite'
        path.write_text(json.dumps(obj))
        result = command([Path.home()/'.cache/pwsh-test/pwsh', '-NoProfile', '-NonInteractive', '-File',
                          ROOT/'app/launcher/tests/test-invite.ps1', '-TestHome', self.b.dir/'hop-client', '-InvitePath', path])
        self.assertEqual(result.returncode, 0, result.stdout.decode()+result.stderr.decode())
        print(result.stdout.decode().strip())

    def test_publisher_needs_no_root_or_identity_provisioning(self):
        from unittest.mock import patch
        public = dict(self.b.c, sandbox=False)
        self.b.cfg.write_text(json.dumps(public))
        trusted = type('Stat', (), {'st_uid': os.getuid(), 'st_mode': 0o100600})()
        with patch.object(invite.Path, 'stat', return_value=trusted):
            c = invite.config(self.b.cfg, administrative=False)
        self.assertEqual(c['publishNodes'], {})
        # Same settings cannot be used to bypass administrative enrollment checks.
        with self.assertRaises(invite.Error):
            invite.config(self.b.cfg, administrative=True)

    def test_production_provision_idempotent_mock_only(self):
        from unittest.mock import patch
        c = dict(self.b.c, sandbox=False, enrollHome=str(self.b.dir / 'service'), sudoersFile=str(self.b.dir / 'sudoers'))
        c['enrollAuthorizedKeys'] = c['enrollHome'] + '/.ssh/authorized_keys'
        c['_file'] = str(self.b.cfg)
        Path(c['enrollHome']).mkdir()
        Path(c['enrollAuthorizedKeys']).parent.mkdir()
        Path(c['enrollAuthorizedKeys']).write_text('')
        account = type('Account', (), {'pw_dir': c['enrollHome'], 'pw_shell': '/bin/sh', 'pw_uid': 900})()
        # Absolutely no account/sudoers operation reaches the operating system.
        with patch.object(invite, 'run', return_value=b'enroll L 2026-11-11 0 99999 7 -1\n') as run, patch.object(invite.pwd, 'getpwnam', side_effect=[KeyError(), account]), patch.object(invite.os, 'chown'), patch.object(invite.Path, 'stat', return_value=type('Stat', (), {'st_uid': 0, 'st_mode': 0o40755})()):
            invite.provision(c)
            invite.provision(c)
        self.assertEqual(sum(x.args[0][0] == 'useradd' for x in run.call_args_list), 1)


if __name__ == '__main__':
    unittest.main()
