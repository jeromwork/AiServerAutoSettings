#!/usr/bin/env python3
"""Transaction failure boundaries in a disposable filesystem; no host networking."""
import copy
import json
import shutil
import subprocess
import unittest
import tempfile
from unittest.mock import patch
from test_server_apply import Fake, app, config, VALUES


class Fresh(Fake):
    def __init__(self, root):
        super().__init__(root)
        self.path('/etc/sing-box/config.json').unlink()
        self.sb = {}
        self.active.discard('sing-box')

    def run(self, args, **kw):
        if args[0] == 'jq':
            file = self.path('/etc/sing-box/config.json')
            if not file.exists():
                return subprocess.CompletedProcess(args, 1, '', '')
            try:
                self.sb = json.loads(file.read_text())
            except ValueError:
                return subprocess.CompletedProcess(args, 1, '', '')
        if args[:2] == ['systemctl', 'restart'] and args[-1] == 'sing-box':
            self.sb = self.read('/etc/sing-box/config.json')
        if args[0] == 'ip' and 'rule' in args and 'del' in args:
            self.reply_rules[args[1]] = []
        result = super().run(args, **kw)
        if args[0] == 'ip' and 'rule' in args and 'show' in args:
            result.stdout = result.stdout.replace('tun0', 'ra-tun')
        return result


class BaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.fake = Fake(self.tmp.name)

    def fresh(self):
        f = Fresh(self.tmp.name)
        c = config()
        c['serverNetwork'] = {'enabled': True}
        c['proxyOut']['ipv6'] = 'block'
        c['lan'] = []
        c.pop('tailscale'); c.pop('telegramGateway')
        return f, c

    def test_initial_activation_needs_later_session_even_with_flag(self):
        f, c = self.fresh()
        first = f.engine(c, ssh_checked=True).run('apply')
        self.assertEqual(first['parts'][0]['state'], 'pending', first)
        self.assertTrue(f.path(app.base.STATE).exists())
        names = [a[0] for a in f.calls]
        arm = next(i for i,a in enumerate(f.calls) if a[0] == 'systemd-run')
        guard = next(i for i,a in enumerate(f.calls) if a[0] == 'nft' and '-c' not in a and '-f' in a)
        start = next(i for i,a in enumerate(f.calls) if a[:2] == ['systemctl', 'enable'] and a[-1] == 'sing-box')
        self.assertLess(arm, guard); self.assertLess(guard, start)
        self.assertFalse(any('route_exclude_address' in i for i in f.sb['inbounds']))
        final = f.engine(c, ssh_checked=True).run('apply')
        self.assertTrue(final['ok'], final)
        again = f.engine(c).run('apply')
        self.assertEqual(again['actions'], [], again)

    def test_rollback_restores_absent_config_rules_firewall_service_state(self):
        f, c = self.fresh()
        first = f.engine(c).run('apply')
        self.assertEqual(first['parts'][0]['state'], 'pending', first)
        app.base.rollback(f.system)
        self.assertFalse(f.path('/etc/sing-box/config.json').exists())
        self.assertNotIn('sing-box', f.active)
        self.assertFalse(f.nft)
        self.assertEqual(f.reply_rules, {'-4': [], '-6': []})
        self.assertFalse(f.path(app.base.STATE).exists())

    def test_packaged_sample_is_not_mistaken_for_preexisting_owner_config(self):
        f, c = self.fresh()
        def packages(engine):
            f.write('/etc/sing-box/config.json', '{"outbounds": []}')
            f.active.add('sing-box')
        with patch.object(app.base, 'install_packages', side_effect=packages):
            first = f.engine(c).run('apply')
        self.assertEqual(first['parts'][0]['state'], 'pending', first)
        app.base.rollback(f.system)
        self.assertFalse(f.path('/etc/sing-box/config.json').exists())
        self.assertNotIn('sing-box', f.active)
        # Retry can produce a fresh plan instead of blocking on the package sample.
        self.assertEqual(f.engine(c).run('plan')['parts'][0]['state'], 'change')

    def test_preflight_failure_removes_package_sample_and_restores_service_state(self):
        f, c = self.fresh()
        def packages(engine):
            f.write('/etc/sing-box/config.json', '{"outbounds": []}')
            f.active.add('sing-box')
        f.exit = '9.9.9.9'  # Proxy is reachable, but is the wrong exit.
        with patch.object(app.base, 'install_packages', side_effect=packages):
            result = f.engine(c).run('apply')
        self.assertFalse(result['ok'])
        self.assertFalse(f.path('/etc/sing-box/config.json').exists())
        self.assertNotIn('sing-box', f.active)
        self.assertFalse(f.path(app.base.STATE).exists())
        self.assertEqual(f.engine(c).run('plan')['parts'][0]['state'], 'change')

    def test_failed_restart_rolls_back_without_lan_or_agent(self):
        f, c = self.fresh()
        f.fail = 'restart'
        result = f.engine(c).run('apply')
        self.assertFalse(result['ok'])
        self.assertFalse(f.path('/etc/sing-box/config.json').exists())
        self.assertFalse(f.path(app.base.STATE).exists())
        self.assertFalse(f.path('/etc/sudoers.d').exists())

    def test_missing_ipv6_or_secret_or_existing_config_never_activates(self):
        for variant in ('secret', 'existing'):
            with self.subTest(variant=variant):
                f, c = self.fresh()
                values = dict(VALUES)
                if variant == 'ipv6': c['proxyOut'].pop('ipv6')
                if variant == 'secret': values.clear()
                if variant == 'existing': f.write('/etc/sing-box/config.json', '{}')
                result = f.engine(c, values).run('apply')
                self.assertFalse(result['ok'])
                self.assertFalse(any(a[0] == 'systemd-run' for a in f.calls))
                self.assertFalse(any(a[0] == 'apt-get' for a in f.calls))

    def test_enabled_base_without_proxy_never_reports_success(self):
        f, c = self.fresh()
        c.pop('proxyOut')
        app.validate(c)  # This is accepted by the public configuration schema.
        for command in ('plan', 'status', 'apply'):
            with self.subTest(command=command):
                result = f.engine(c).run(command)
                self.assertFalse(result['ok'])
                self.assertEqual(result['parts'][0]['state'], 'blocked')
                self.assertIn('proxyOut', result['parts'][0]['summary'])
                self.assertEqual(result['actions'], [])
        self.assertFalse(f.path('/var/lib/remoteagents-status/server-config.json').exists())

    def test_changed_pending_config_does_not_confirm(self):
        f, c = self.fresh()
        self.assertEqual(f.engine(c).run('apply')['parts'][0]['state'], 'pending')
        c['serverNetwork']['tunName'] = 'other'
        result = f.engine(c, ssh_checked=True).run('apply')
        self.assertFalse(result['ok'])
        self.assertTrue(f.path(app.base.STATE).exists())

    def test_watch_leaves_initial_transaction_to_rollback(self):
        f, c = self.fresh()
        f.engine(c).run('apply')
        f.calls.clear()
        self.assertFalse(app.egress_watch(f.engine(c)))
        self.assertEqual(f.calls, [])

    def test_sshd_invalid_dropin_is_restored_without_reload(self):
        f = self.fake
        old = 'LoginGraceTime 100\n'
        f.write('/etc/ssh/sshd_config.d/10-remoteagents-startups.conf', old)
        f.fail = '-t'
        result = f.engine().run('apply')
        self.assertEqual(next(r for r in result['parts'] if r['part'] == 'sshd')['state'], 'error')
        self.assertEqual(f.path('/etc/ssh/sshd_config.d/10-remoteagents-startups.conf').read_text(), old)
        self.assertFalse(any(a[:2] == ['systemctl', 'reload'] for a in f.calls))

    def test_test_host_aliases_and_conflicts(self):
        c = config()
        c['lan'][0]['testHost'] = c['lan'][0].pop('host')
        c['lan'][0]['testPort'] = c['lan'][0].pop('port')
        app.validate(c)
        self.assertTrue(self.fake.complete(c)['ok'])
        c['lan'][0]['host'] = '10.100.0.2'
        with self.assertRaises(app.Error): app.validate(c)


if __name__ == '__main__':
    unittest.main()
