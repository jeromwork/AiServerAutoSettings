"""Device lifecycle and client refresh on rootless loopback sshd, disposable HOME."""
import json
from pathlib import Path
import tempfile
import time
import unittest
from test_invite import Bench, ROOT, command, invite


class RefreshTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ra-refresh-')
        self.b = Bench(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self.b.close)
        self.b.c['settingsFile'] = str(self.b.dir/'home/.config/remoteagents/invite-settings.json')
        self.b.cfg.write_text(json.dumps(self.b.c))
        obj, _, _ = self.b.create()
        invite.enroll(self.b.c, obj['id'], self.b.pub)
        self.device = invite.devices(self.b.c)[0]
        channel = json.loads(self.b.channel.read_text())
        channel['outbounds'] = [dict(type='vless', tag='fixture', server='127.0.0.1', server_port=self.b.port, uuid='00000000-0000-4000-8000-000000000001')]
        self.b.channel.write_text(json.dumps(channel))
        # New path, old removed. JSON from remote and package is deliberately CRLF.
        self.b.catalog.write_text(json.dumps(dict(schema=1, entries=[], hops=[], relays=[dict(name='new', host='127.0.0.1', port=self.b.port)], cdn=[])))
        self.b.cfg.write_text(json.dumps(self.b.c))
        self.profile = self.b.dir/'profile.json'
        self.profile.write_text(json.dumps(dict(sshExecutable='/usr/bin/ssh', serverAddress='127.0.0.1', login=self.b.user,
            keyPath=str(self.b.own), configPath='/dev/null', knownHostsPath=str(self.b.known), strictHostKey=True,
            arguments=['-F','/dev/null','-T','-p',str(self.b.port),'-l',self.b.user,'-i',str(self.b.own),'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','GlobalKnownHostsFile=none','-o','UserKnownHostsFile='+str(self.b.known),'127.0.0.1'])))

    def package(self):
        started = time.monotonic()
        result = self.b.cli('refresh', '--device', self.device['id'], '--hours', '2')
        self.assertEqual(result.returncode, 0, result.stdout.decode())
        path = Path(result.stdout.decode().splitlines()[1])
        files = invite.overlay.read(path.read_bytes())
        data = json.loads(files['invite.rainvite'])
        self.assertEqual(path.read_bytes()[:len(self.b.exe.read_bytes())], self.b.exe.read_bytes())
        self.assertEqual(data['deviceKey'], invite.public_key(self.b.pub))
        self.assertFalse(set(data) & {'passKey', 'enrollUser'})
        print(f'PASS personal refresh release: {time.monotonic()-started:.3f}s (fixture release EXE)')
        return data, path

    def client(self, data, mode):
        payload = self.b.dir/('payload-'+mode+'.json')
        payload.write_bytes(json.dumps(data, ensure_ascii=False, indent=2).replace('\n', '\r\n').encode())
        result = command([Path.home()/'.cache/pwsh-test/pwsh', '-NoProfile', '-NonInteractive', '-File',
            ROOT/'app/launcher/tests/test-refresh.ps1', '-TestHome', self.b.dir/('client-'+mode),
            '-Payload', payload, '-Profile', self.profile, '-SingBoxFile', self.b.exe, '-Mode', mode], timeout=110)
        self.assertEqual(result.returncode, 0, result.stdout.decode()+result.stderr.decode())
        print(result.stdout.decode().strip())

    def test_refresh_own_foreign_expired_and_idempotence(self):
        data, path = self.package()
        # Another machine cannot substitute just a .pub; production derives the private key.
        foreign = self.b.dir/'foreign'
        self.assertEqual(command(['ssh-keygen','-q','-t','ed25519','-N','','-f',foreign]).returncode, 0)
        bad = dict(data, deviceKey=invite.public_key(foreign.with_suffix('.pub').read_bytes()))
        saved_public = self.b.own.with_suffix('.pub').read_bytes()
        self.b.own.with_suffix('.pub').write_bytes(foreign.with_suffix('.pub').read_bytes())
        self.client(bad, 'foreign')
        self.b.own.with_suffix('.pub').write_bytes(saved_public)
        self.client(dict(data, expiresUtc='2000-01-01T00:00:00Z'), 'expired')
        self.client(data, 'untrusted')
        self.client(data, 'refresh')
        self.client(dict(data, id='c'*32), 'offline')
        # C# parser reads actual refresh envelope too, same format as enrollment.
        from test_invite import build_portable
        build_portable()
        pe = self.b.dir/'overlay-check'
        pe.mkdir()
        (pe/'plain.exe').write_bytes(self.b.exe.read_bytes())
        (pe/'refresh.exe').write_bytes(path.read_bytes())
        result = command([Path.home()/'.dotnet/dotnet', ROOT/'app/launcher/tests/bin/Release/net10.0/PortableTests.dll', '--overlay', pe])
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_refresh_replaces_previous_transport_route(self):
        data, _ = self.package()
        self.client(data, 'old-route')

    def test_sync_and_untrusted_host_rejection(self):
        (self.b.dir/'new-vps').mkdir()
        new_vps = Bench(self.b.dir/'new-vps')
        self.addCleanup(new_vps.close)
        Path(new_vps.c['workerAuthorizedKeys']).write_bytes(self.b.pub)
        self.b.c.update(serverPort=new_vps.port, hostKeys=new_vps.c['hostKeys'])
        self.b.catalog.write_text(json.dumps(dict(schema=1, entries=[], hops=[], relays=[dict(name='new', host='127.0.0.1', port=new_vps.port)], cdn=[])))
        self.b.cfg.write_text(json.dumps(self.b.c))
        data, _ = self.package()
        self.assertEqual(self.b.cli('sync').returncode, 0)
        server_catalog = self.b.dir/'home/.config/remoteagents/transport-catalog.json'
        server_catalog.write_bytes(self.b.catalog.read_text().replace('\n','\r\n').encode())
        next_config = new_vps.dir/'home/.config/remoteagents'
        next_config.mkdir(parents=True)
        (next_config/'invite-settings.json').write_bytes(Path(self.b.c['settingsFile']).read_bytes())
        (next_config/'transport-catalog.json').write_bytes(server_catalog.read_bytes())
        self.client(data, 'sync')
        # A changed host key from an unverified source never replaces local pins.
        self.b.known.write_text('[127.0.0.1]:'+str(self.b.port)+' '+invite.public_key(self.b.pub)+'\n')
        result = self.b.ssh(self.b.own, remote='cat "$HOME/.config/remoteagents/invite-settings.json"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'HOST IDENTIFICATION HAS CHANGED', result.stderr)
        print('PASS auto settings: changed untrusted host rejected by actual OpenSSH before snapshot read')

    def test_revoke_device_with_reused_key(self):
        # Re-inviting the same computer under a new name must still allow revocation.
        obj, _, _ = self.b.create('--name', 'Renamed')
        invite.enroll(self.b.c, obj['id'], self.b.pub)
        self.assertEqual(self.b.ssh(self.b.own, remote='true').returncode, 0)
        result = self.b.cli('revoke-device', self.device['id'])
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotEqual(self.b.ssh(self.b.own, remote='true').returncode, 0)
        self.assertEqual(invite.devices(self.b.c), [])

    def test_devices_revoke_and_legacy_metadata(self):
        result = self.b.cli('devices')
        self.assertEqual(result.returncode, 0)
        row = json.loads(result.stdout)
        self.assertEqual(row['name'], 'Ноутбук')
        self.assertTrue(row['registeredUtc'])
        self.assertTrue(row['fingerprint'].startswith('SHA256:'))
        self.assertNotIn('publicKey', row)
        record = next(Path(self.b.c['stateDir']).glob('*.json'))
        legacy = invite.load(record)
        legacy.pop('deviceKey')
        invite.save(record, legacy)
        self.assertEqual(invite.devices(self.b.c)[0]['registeredUtc'], row['registeredUtc'])
        self.assertEqual(self.b.ssh(self.b.own, remote='true').returncode, 0)
        # Preserve unrelated authorized key/comment verbatim.
        auth = Path(self.b.c['workerAuthorizedKeys'])
        auth.write_text(auth.read_text()+'# unrelated\n')
        result = self.b.cli('revoke-device', row['id'])
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotEqual(self.b.ssh(self.b.own, remote='true').returncode, 0)
        self.assertEqual(auth.read_text(), '# unrelated\n')
        self.assertEqual(invite.devices(self.b.c), [])
        self.assertNotEqual(self.b.cli('refresh', '--device', row['id']).returncode, 0)
        self.assertNotEqual(self.b.cli('revoke-device', row['id']).returncode, 0)
        print('PASS devices/revoke: timestamp, fingerprint, own-key access then denied; unrelated line preserved')
