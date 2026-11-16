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

    def test_reconcile_preserves_valid_native_agent_settings_edits(self):
        self.c['serverComponents'] = {'bridge': {'enabled': True}}
        self.f.write('/home/worker/.claude.json', '{"mcpServers":{}}')
        self.f.write('/home/worker/.codex/config.toml', 'model = "before"\n')
        self.assertTrue(self.f.complete(self.c)['ok'])
        edits = {'.claude.json': '{"mcpServers":{},"theme":"dark"}',
                 '.codex/config.toml': 'model = "after"\n[mcp_servers.other]\ncommand = "other-mcp"\n'}
        for name, value in edits.items():
            self.f.write('/home/worker/' + name, value)
        self.assertTrue(app.module('server_recovery').reconcile(app, self.f.system))
        for name, value in edits.items():
            self.assertEqual(self.f.path('/home/worker/' + name).read_text(), value)
        # The refreshed recovery snapshot can still repair invalid JSON later.
        self.f.write('/home/worker/.claude.json', '{broken')
        self.assertTrue(app.module('server_recovery').reconcile(app, self.f.system))
        self.assertEqual(self.f.path('/home/worker/.claude.json').read_text(), edits['.claude.json'])

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

    def test_existing_cli_login_is_captured_once_and_repaired_without_proxy_setup(self):
        self.c.pop('proxyOut')
        self.c['agents'] = {'claude': {'enabled': True}}
        auth = '{"claudeAiOauth":{"accessToken":"SYNTHETIC_AUTH"}}'
        file = self.f.path('/home/worker/.claude/.credentials.json')
        self.f.write('/home/worker/.claude/.credentials.json', auth)
        result = self.f.complete(self.c)
        self.assertTrue(result['ok'], result)
        self.assertTrue(self.f.engine(self.c).run('status')['ok'])
        self.assertEqual(self.f.engine(self.c).run('apply')['actions'], [])
        file.unlink()
        self.assertTrue(app.module('server_recovery').reconcile(app, self.f.system))
        self.assertEqual(file.read_text(), auth)

    def test_native_oauth_refresh_is_saved_and_stale_seed_does_not_overwrite_it(self):
        self.c.pop('proxyOut')
        self.c['agents'] = {'claude': {'enabled': True, 'auth': {'secret': 'oauth'}}}
        seed = '{"claudeAiOauth":{"accessToken":"SEED"}}'
        refreshed = '{"claudeAiOauth":{"accessToken":"REFRESHED"}}'
        rotated = '{"claudeAiOauth":{"accessToken":"NEW_CONFIGURED_LOGIN"}}'
        self.assertTrue(self.f.complete(self.c, {'oauth': seed})['ok'])
        file = self.f.path('/home/worker/.claude/.credentials.json')
        file.write_text(refreshed)
        self.assertTrue(app.module('server_recovery').reconcile(app, self.f.system))
        self.assertEqual(file.read_text(), refreshed)
        self.assertEqual(self.f.read('/etc/remoteagents/server-apply/recovery.json')['secrets']['oauth'], refreshed)
        self.assertTrue(self.f.engine(self.c, {'oauth': seed}).run('status')['ok'])
        self.assertEqual(self.f.engine(self.c, {'oauth': seed}).run('apply')['actions'], [])
        file.write_text('{broken')
        self.assertTrue(app.module('server_recovery').reconcile(app, self.f.system))
        self.assertEqual(file.read_text(), refreshed)
        self.assertTrue(self.f.engine(self.c, {'oauth': rotated}).run('apply')['ok'])
        self.assertEqual(file.read_text(), rotated)

    def test_version_cannot_be_an_installer_option(self):
        for version in ('--uninstall', '--version', '0.2.17 --uninstall'):
            self.c['serverComponents'] = {'happier': {'enabled': True, 'version': version}}
            with self.assertRaises(app.Error):
                app.validate(self.c)
            with self.assertRaises(comp.Error):
                comp.install_vendor(self.f.engine(self.c), 'happier', version)
        self.assertEqual(self.f.calls, [])

    def test_no_codex_adoption_by_username(self):
        self.c['agents'] = {'codex': {'enabled': True}}
        result = self.f.engine(self.c)
        self.assertFalse(comp.agents(result, 'codex', True))
        self.assertEqual(result.rows[-1]['state'], 'blocked')



class HappierWebComponentsTests(unittest.TestCase):
    def test_worker_io_idempotent_disable_and_reconcile_repairs_units(self):
        with tempfile.TemporaryDirectory() as tmp:
            class WebServices(UserServices):
                def __init__(self, root):
                    super().__init__(root)
                    self.ui_installed = False

                def run(self, args, **kw):
                    if args[:2] == ['loginctl', 'enable-linger']:
                        self.write('/var/lib/systemd/linger/worker', '')
                    if args[0] == 'runuser' and any(str(a).endswith('happier_web.py') for a in args):
                        self.calls.append(args)
                        command = args[-1]
                        if command == 'update':
                            self.ui_installed = True
                            self.system.actions.append('fixture UI update')
                            return subprocess.CompletedProcess(args, 0, '', '')
                        ready = self.ui_installed and (command == 'installed' or 'remoteagents-happier-web.service' in self.active)
                        return subprocess.CompletedProcess(args, 0 if ready else 1, '', '')
                    return super().run(args, **kw)
            f = WebServices(tmp)
            c = config(); c['lan'] = []; c.pop('tailscale'); c.pop('telegramGateway'); c.pop('proxyOut')
            c['serverComponents'] = {'happierWeb': {'enabled': True,'port':47832,'keepChats':12}}
            self.assertEqual(f.engine(c).run('plan')['parts'][1]['state'], 'change')
            first = f.complete(c)
            self.assertTrue(first['ok'],first)
            again = f.engine(c).run('apply')
            self.assertTrue(again['ok'],again); self.assertEqual(again['actions'],[])
            self.assertEqual(sum(args[-1]=='update' for args in f.calls),1)
            unit = f.path('/home/worker/.config/systemd/user/remoteagents-happier-web.service')
            unit.unlink(); f.active.discard('remoteagents-happier-web.service')
            self.assertTrue(app.module('server_recovery').reconcile(app,f.system))
            self.assertTrue(unit.is_file())
            self.assertEqual(f.engine(c).run('apply')['actions'],[])
            c['serverComponents']['happierWeb']['enabled']=False
            self.assertTrue(f.engine(c).run('apply')['ok'])
            self.assertNotIn('remoteagents-happier-web.service',f.active)
            self.assertNotIn('remoteagents-happier-web-update.timer',f.active)
            self.assertTrue(unit.is_file()); self.assertTrue(f.ui_installed)

    def test_schema_bounds_and_file_delivery(self):
        base = {'kind':'remoteagents-config','schema':1,'serverComponents':{'happierWeb':{'enabled':True}}}
        app.validate(base)
        for field, value in [('port',0),('keepReleases',1),('keepChats',0),('updateIntervalHours',0),('unknown',True)]:
            with self.subTest(field=field), self.assertRaises(app.Error):
                app.validate({**base,'serverComponents':{'happierWeb':{'enabled':True,field:value}}})
        for field, value in [('claudeProbeSec',0),('claudeProbe','yes')]:
            with self.assertRaises(app.Error):
                app.validate({**base,'serverComponents':{'happierWeb':{'quotas':{field:value}}}})
        with tempfile.TemporaryDirectory() as tmp:
            e=UserServices(tmp).engine(base)
            files=e.code_files()
            for name in ('happier_web.py','happier_web_verify.cjs','happier_web_addon.js','happier-web.schema.json'):
                self.assertIn('/usr/local/lib/remoteagents/server/'+name,files)


if __name__ == '__main__':
    unittest.main()
