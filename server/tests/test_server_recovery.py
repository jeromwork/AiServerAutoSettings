#!/usr/bin/env python3
"""Recovery boundary tests; fake services, real files/permissions. Docker covers kernel."""
import json
import os
import tempfile
import unittest
from unittest.mock import patch
from test_server_apply import Fake, app, config, VALUES
from test_base_network import Fresh

recovery = app.module('server_recovery')


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.f = Fresh(self.tmp.name)
        self.c = config()
        self.c['serverNetwork'] = dict(enabled=True)
        self.c['lan'] = []
        self.c.pop('tailscale'); self.c.pop('telegramGateway')

    def install(self):
        result = self.f.complete(self.c)
        self.assertTrue(result['ok'], result)
        return self.f.read(recovery.ENVELOPE)

    def test_confirmed_snapshot_private_minimal_and_idempotent(self):
        self.c['server']['rootPassword'] = {'secret': 'root-pass'}
        values = dict(VALUES, **{'root-pass': 'ROOT_SENTINEL', 'unused': 'UNUSED_SENTINEL'})
        self.assertTrue(self.f.complete(self.c, values)['ok'])
        file = self.f.path(recovery.ENVELOPE)
        data = json.loads(file.read_text())
        self.assertEqual(file.stat().st_mode & 0o777, 0o600)
        self.assertEqual(file.parent.stat().st_mode & 0o777, 0o700)
        self.assertNotIn('ROOT_SENTINEL', file.read_text())
        self.assertNotIn('UNUSED_SENTINEL', file.read_text())
        self.assertEqual(data['secrets'], {'proxy-out-password': VALUES['proxy-out-password']})
        self.assertIn('singbox', data)
        self.assertEqual(self.f.engine(self.c, values).run('apply')['actions'], [])
        self.assertEqual(self.f.engine(self.c, values).run('status')['actions'], [])
        log = self.f.path('/var/log/remoteagents/server-apply.log')
        log.write_text('x' * (1024 * 1024 + 1)); log.chmod(0o644)
        self.f.system.audit([])
        self.assertLess(log.stat().st_size, 1024)
        self.assertEqual(log.stat().st_mode & 0o777, 0o600)
        self.assertEqual(log.with_name(log.name + '.1').stat().st_mode & 0o777, 0o600)

    def test_missing_backup_is_a_plan_change_even_when_services_match(self):
        self.install()
        self.f.path(recovery.ENVELOPE).unlink()
        result = self.f.engine(self.c).run('plan')
        self.assertEqual(result['actions'], [])
        self.assertEqual(next(r['state'] for r in result['parts'] if r['part'] == 'recovery'), 'change')
        self.assertFalse(result['ok'])

    def test_rotated_secret_updates_backup_even_when_service_needs_no_change(self):
        self.c['tailscale'] = dict(enabled=False, authKey={'secret': 'tailscale-auth-key'})
        self.install()
        values = dict(VALUES, **{'tailscale-auth-key': 'ROTATED_SENTINEL'})
        plan = self.f.engine(self.c, values).run('plan')
        self.assertEqual(next(r['state'] for r in plan['parts'] if r['part'] == 'recovery'), 'change')
        self.assertTrue(self.f.engine(self.c, values).run('apply')['ok'])
        self.assertEqual(self.f.read(recovery.ENVELOPE)['secrets']['tailscale-auth-key'], 'ROTATED_SENTINEL')
        self.assertEqual(self.f.engine(self.c, values).run('apply')['actions'], [])
        self.assertNotIn('ROTATED_SENTINEL', json.dumps(plan))

    def test_repairs_corrupt_config_stopped_service_and_deleted_rules(self):
        data = self.install()
        self.f.write('/etc/sing-box/config.json', '{broken')
        self.f.active.discard('sing-box')
        self.f.rules = False
        self.f.reply_rules['-4'] = []
        self.f.nft.clear()
        self.f.system.actions.clear()
        self.assertTrue(recovery.reconcile(app, self.f.system))
        self.assertEqual(self.f.path('/etc/sing-box/config.json').read_text(), data['singbox'])
        self.assertTrue(self.f.engine(self.c).egress_check()[0])
        self.assertTrue(self.f.engine(self.c).inbound_check()[0])
        self.assertIn('remoteagents_ipv6', self.f.nft)

    def test_restores_confirmed_lan_files_without_starting_new_transaction(self):
        self.c['lan'] = config()['lan']
        data = self.install()
        self.f.active.discard('remoteagents-lan@office.service')
        self.f.write('/etc/remoteagents/lan/office/client.conf', '# broken')
        self.f.write('/etc/remoteagents/lan/office/config.json', '{broken')
        self.assertTrue(recovery.reconcile(app, self.f.system))
        for name, text in data['lan']['office'].items():
            self.assertEqual(self.f.path('/etc/remoteagents/lan/office/' + name).read_text(), text)
        self.assertFalse(self.f.path('/var/lib/remoteagents/lan/pending').exists())
        self.assertIn('remoteagents-lan@office.service', self.f.active)

    def test_pending_transactions_are_never_self_confirmed_or_overwritten(self):
        self.install()
        for path in recovery.PENDING:
            with self.subTest(path=path):
                pending = self.f.path(path); pending.mkdir(parents=True)
                self.f.system.actions.clear()
                self.assertFalse(recovery.reconcile(app, self.f.system))
                self.assertEqual(self.f.system.actions, [])
                pending.rmdir()

    def test_no_adoption_of_manual_network_or_world_readable_envelope(self):
        f = Fake(self.tmp.name)
        c = config(); c['lan'] = []; c.pop('tailscale'); c.pop('telegramGateway')
        self.assertTrue(f.complete(c)['ok'])
        self.assertNotIn('singbox', f.read(recovery.ENVELOPE))
        os.chmod(f.path(recovery.ENVELOPE), 0o644)
        with self.assertRaises(app.Error):
            recovery.reconcile(app, f.system)

    def test_docker_refuses_before_any_mutation(self):
        self.c['deployment'] = dict(method='docker', dockerfile='server/docker/Dockerfile')
        app.validate(self.c)
        for verb in ('plan', 'status', 'apply'):
            r = self.f.engine(self.c).run(verb)
            self.assertFalse(r['ok']); self.assertEqual(r['actions'], [])
            self.assertIn('ещё не поддерживается', r['parts'][0]['summary'])

    def test_server_tailscale_cannot_enable_kernel_networking(self):
        self.c['tailscale'] = dict(enabled=True, userspace=False)
        with self.assertRaises(app.Error):
            app.validate(self.c)


if __name__ == '__main__':
    unittest.main()
