#!/usr/bin/env python3
"""Private file restore and component state using real IO, synthetic vendor CLIs."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from test_server_apply import Fake, app, config

comp = app.components


class UserServices(Fake):
    def write(self, path, text):
        super().write(path, text)
        for parent in self.path(path).parents:
            if parent == self.root:
                break
            parent.chmod(0o700)

    def __init__(self, root):
        super().__init__(root)
        self.vendor = {'claude': '2.1.311', 'happier': '0.2.17'}

    def run(self, args, **kw):
        if args[0] == 'runuser' and 'systemctl' in args:
            self.calls.append(args)
            i = args.index('systemctl'); sub = args[i + 2:]
            unit = args[-1]
            code = 0
            if sub[0] in ('is-active', 'is-enabled'):
                code = 0 if unit in self.active else 3
            elif sub[0] in ('start', 'restart', 'enable'):
                self.active.add(unit)
            elif sub[0] in ('stop', 'disable'):
                self.active.discard(unit)
            return subprocess.CompletedProcess(args, code, '', '')
        if args[0] == 'runuser' and '--version' in args:
            self.calls.append(args)
            name = Path(args[-2]).name
            return subprocess.CompletedProcess(args, 0 if name in self.vendor else 127, self.vendor.get(name, ''), '')
        if args[0] == 'runuser' and 'mcp' in args and 'list' in args:
            return subprocess.CompletedProcess(args, 0, 'windows-control', '')
        return super().run(args, **kw)


class ComponentsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.f = UserServices(self.tmp.name)
        self.c = config(); self.c['lan'] = []; self.c.pop('tailscale'); self.c.pop('telegramGateway')

    def test_fixed_identity_format_rejects_paths_and_incomplete_disk(self):
        for kind, files in [('bridge', {'../../root/.ssh/authorized_keys': 'SECRET'}),
                            ('bridge', {'.local/share/remote-agents-nodes/../evil.json': 'SECRET'}),
                            ('happier', {'.happier/servers/../access.key': 'SECRET'}), ('disk', {})]:
            with self.subTest(kind=kind, files=files), self.assertRaises(ValueError):
                app.component_files.validate(kind, files)

    def test_semantically_corrupt_telegram_key_store_is_not_adopted(self):
        for raw in ('{"version":1,"keys":{"client":{"sha256":"broken","created":"2026-11-15"}}}',
                    '{"version":1,"keys":{"client":{"sha256":"' + 'a' * 64 + '","created":"broken"}}}'):
            with self.assertRaises(ValueError):
                app.component_files.telegram_keys(raw)

    def test_symlink_private_user_restore_never_escapes_home(self):
        engine = self.f.engine(self.c); engine.install_code()
        outside = self.f.path('/outside'); outside.mkdir()
        ssh = self.f.path('/home/worker/.ssh'); ssh.parent.mkdir(parents=True, exist_ok=True); ssh.symlink_to(outside)
        with self.assertRaises(app.Error):
            comp.io(engine, 'bridge', 'identity', {'.ssh/authorized_keys': 'KEY_SENTINEL'})
        self.assertFalse((outside / 'authorized_keys').exists())

    def test_bridge_identity_and_assets_survive_corruption_and_full_snapshot(self):
        self.c['serverComponents'] = {'bridge': {'enabled': True}}
        self.f.write('/home/worker/.ssh/authorized_keys', 'SSH_KEY_SENTINEL\n')
        first = self.f.complete(self.c)
        self.assertTrue(first['ok'], first)
        backup = self.f.read('/etc/remoteagents/server-apply/recovery.json')
        ref = backup['config']['serverComponents']['bridge']['identity']['secret']
        self.assertIn('SSH_KEY_SENTINEL', backup['secrets'][ref])
        self.assertNotIn('SSH_KEY_SENTINEL', json.dumps(first))
        self.f.write('/home/worker/.ssh/authorized_keys', '')
        self.f.write('/home/worker/.local/share/codex-remote/codex-windows-bridge.py', 'corrupted')
        self.assertTrue(app.module('server_recovery').reconcile(app, self.f.system))
        self.assertIn('SSH_KEY_SENTINEL', self.f.path('/home/worker/.ssh/authorized_keys').read_text())
        self.assertEqual(self.f.engine(self.c).run('apply')['actions'], [])

    def test_explicit_revocation_survives_restore_of_old_authorized_keys(self):
        self.c['serverComponents'] = {'bridge': {'enabled': True}}
        self.f.write('/home/worker/.ssh/authorized_keys', 'ssh-ed25519 YWJj ra-config:0123456789abcdef Test\n')
        self.assertTrue(self.f.complete(self.c)['ok'])
        self.f.write('/home/worker/.ssh/remoteagents-revoked.json', '["0123456789abcdef"]')
        self.f.write('/home/worker/.ssh/authorized_keys', '')
        self.assertTrue(app.module('server_recovery').reconcile(app, self.f.system))
        self.assertNotIn('0123456789abcdef', self.f.path('/home/worker/.ssh/authorized_keys').read_text())
        self.assertEqual(json.loads(self.f.path('/home/worker/.ssh/remoteagents-revoked.json').read_text()), ['0123456789abcdef'])

    def test_happier_restores_identity_unit_and_deleted_auth_dropin(self):
        self.c['serverComponents'] = {'happier': {'enabled': True, 'version': '0.2.17', 'identity': {'secret': 'happy'}}}
        files = {'.happier/settings.json': '{"machineId":"SYNTHETIC"}', '.happier/access.key': '{"token":"HAPPY_SENTINEL"}'}
        values = dict(happy=json.dumps(files))
        e = self.f.engine(self.c, values)
        self.assertTrue(comp.happier(e, True))
        unit = self.f.path('/home/worker/.config/systemd/user/remoteagents-happier.service')
        self.assertIn('EnvironmentFile=-%h/.config/remoteagents/claude.env', unit.read_text())
        unit.unlink(); self.f.active.discard('remoteagents-happier.service')
        self.f.write('/home/worker/.happier/access.key', 'broken')
        e = self.f.engine(self.c, values)
        self.assertFalse(comp.happier(e, False)); self.assertTrue(comp.happier(e, True))
        self.assertEqual(self.f.path('/home/worker/.happier/access.key').read_text(), files['.happier/access.key'])

    def test_agents_missing_login_wait_and_secret_stays_off_argv(self):
        self.c['agents'] = {'claude': {'enabled': True, 'channel': 'stable'}}
        e = self.f.engine(self.c); e.install_code()
        self.assertFalse(comp.agents(e, 'claude', True))
        self.assertEqual(e.rows[-1]['state'], 'waiting'); self.assertIn('нужен вход', e.rows[-1]['summary'])
        self.c['agents']['claude']['token'] = {'secret': 'claude-token'}
        e = self.f.engine(self.c, {'claude-token': 'TOKEN_SENTINEL'})
        self.assertTrue(comp.agents(e, 'claude', True))
        self.assertNotIn('TOKEN_SENTINEL', json.dumps(self.f.calls))
        self.assertNotIn('TOKEN_SENTINEL', json.dumps(e.rows))
        p = self.f.path('/home/worker/.config/remoteagents/claude.env')
        self.assertEqual(p.stat().st_mode & 0o777, 0o600)
        p.unlink()
        self.assertTrue(comp.agents(self.f.engine(self.c, {'claude-token': 'TOKEN_SENTINEL'}), 'claude', True))
        self.assertTrue(p.is_file())

    def test_waiting_login_does_not_prevent_persistent_repair(self):
        self.c['agents'] = {'claude': {'enabled': True}}
        result = self.f.complete(self.c)
        self.assertFalse(result['ok'], result)
        self.assertTrue(self.f.path('/etc/remoteagents/server-apply/recovery.json').is_file(), result)
        self.assertIn('нужен вход', next(r['summary'] for r in result['parts'] if r['part'] == 'agents:claude'))

    def test_unavailable_manual_extra_does_not_disable_core_recovery(self):
        self.c['projectViews'] = {'enabled': True}
        self.c['serverComponents'] = {'bridge': {'enabled': True}}
        self.assertFalse(self.f.complete(self.c)['ok'])
        file = self.f.path('/home/worker/.local/share/codex-remote/codex-windows-bridge.py')
        file.write_text('broken')
        self.assertFalse(app.module('server_recovery').reconcile(app, self.f.system))
        self.assertNotEqual(file.read_text(), 'broken')

    def test_no_codex_adoption_by_username(self):
        self.c['agents'] = {'codex': {'enabled': True}}
        result = self.f.engine(self.c)
        self.assertFalse(comp.agents(result, 'codex', True))
        self.assertEqual(result.rows[-1]['state'], 'blocked')


if __name__ == '__main__':
    unittest.main()
