#!/usr/bin/env python3
"""Offline only: temporary roots, pure generation and a recording process runner."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]

def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'server' / (name + '.py'))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m

app = load('server_apply')
share = app.lan_share


def profile():
    return dict(kind='remoteagents-config', schema=1, lan=[dict(name='office', kind='openvpn',
        ovpn={'secret': 'office-ovpn'}, testHost='10.123.0.1', testPort=443,
        share=dict(subnets=['10.123.0.0/24'], domains=['*.example.org', 'service.example.org'],
                   forwards=[dict(name='ssh', host='10.123.0.2', port=22, localPort=18222)]))])


def channel():
    return dict(inbounds=[dict(type='vless', tag='channel'), dict(type='tun', tag='tun')],
        outbounds=[dict(type='direct', tag='direct-out'), dict(type='socks', tag='proxy-out')],
        route=dict(final='proxy-out', rules=[dict(ip_is_private=True, action='reject')]))


def live_like():
    # Как основной sing-box: auto_detect_interface привязывает direct-out к внешнему интерфейсу.
    return dict(inbounds=[dict(type='vless', tag='vless-in'), dict(type='tun', tag='system-tun')],
        outbounds=[dict(type='socks', tag='proxy-out'), dict(type='direct', tag='direct-out')],
        route=dict(final='proxy-out', auto_detect_interface=True, rules=[dict(ip_is_private=True, outbound='direct-out')]))


class Tests(unittest.TestCase):
    def test_schema_migration_crlf_export(self):
        old = profile(); del old['lan'][0]['share']
        app.validate(old)
        self.assertFalse(share.enabled(share.policy(old)))
        new = json.loads(json.dumps(profile(), indent=2).replace('\n', '\r\n'))
        app.validate(new)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'snapshot.json'
            path.write_text(json.dumps({'lan': new['lan']}, indent=2).replace('\n', '\r\n'))
            path.chmod(0o600)
            rc = load('remoteagents_config')
            self.assertEqual(rc.server_sections({'serverConfig': str(path)})['lan'], new['lan'])
        for invalid in ('0.0.0.0/0', '8.8.8.0/24', '10.123.0.1/24'):
            bad = profile(); bad['lan'][0]['share']['subnets'] = [invalid]
            with self.assertRaises(share.Error):
                app.validate(bad)
        bad = profile(); bad['lan'][0]['testHost'] = '10.124.0.1'
        with self.assertRaises(share.Error):
            app.validate(bad)
        bad = profile(); bad['lan'][0]['share']['forwards'][0]['localPort'] = 80
        with self.assertRaises(app.Error):
            app.validate(bad)
        only = profile(); only['lan'][0].pop('testHost'); only['lan'][0]['share'] = {'forwards': only['lan'][0]['share']['forwards']}
        app.validate(only)

    def test_scoped_generation_idempotence_remove(self):
        original = channel(); before = copy.deepcopy(original)
        generated, record = share.generate(original, share.policy(profile()), 'singbox')
        self.assertEqual(original, before)
        rules = generated['route']['rules']
        self.assertEqual(rules[-1], original['route']['rules'][0])
        self.assertTrue(all(r.get('inbound', r.get('rules', [{}])[0].get('inbound')) == ['channel'] for r in record['rules']))
        self.assertTrue(any(r.get('outbound') == 'proxy-out' for r in record['rules']))
        self.assertEqual(generated['route']['final'], 'proxy-out')
        self.assertEqual(share.generate(generated, share.policy(profile()), 'singbox', record)[0], generated)
        self.assertEqual(share.generate(generated, share.policy({}), 'singbox', record)[0], original)
        generated['route']['rules'][0]['outbound'] = 'foreign'
        with self.assertRaises(share.Error):
            share.generate(generated, share.policy(profile()), 'singbox', record)

    @unittest.skipUnless(shutil.which('sing-box'), 'sing-box not installed')
    def test_singbox_generated_config_syntax(self):
        base = channel()
        base['inbounds'][0].update(listen='127.0.0.1', listen_port=18443,
            users=[{'uuid': '00000000-0000-4000-8000-000000000001'}])
        base['inbounds'].pop()
        base['outbounds'][1].update(server='127.0.0.1', server_port=1080)
        generated, _ = share.generate(base, share.policy(profile()), 'singbox')
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'candidate.json'
            path.write_text(json.dumps(generated))
            result = subprocess.run(['sing-box', 'check', '-c', str(path)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_xray_preserves_private_deny(self):
        original = dict(inbounds=[dict(protocol='vless', settings={'clients': [{'id': 'fixture'}]})],
            outbounds=[dict(protocol='freedom', tag='direct')],
            routing={'rules': [dict(type='field', ip=['10.0.0.0/8'], outboundTag='blocked')]})
        generated, record = share.generate(original, share.policy(profile()), 'xray')
        self.assertEqual(generated['routing']['rules'][-1], original['routing']['rules'][0])
        self.assertIn(dict(type='field', ip=['10.123.0.2/32'], port='22', outboundTag='direct'), record['rules'])
        self.assertEqual(share.generate(generated, share.policy({}), 'xray', record)[0], original)
        original['inbounds'].append({'protocol': 'http'})
        with self.assertRaises(share.Error):
            share.generate(original, share.policy(profile()), 'xray')

    def transaction(self, root):
        calls = []
        failure = []
        def run(args, **kw):
            if args[:3] == ['systemctl', 'is-active', '--quiet']:
                return subprocess.CompletedProcess(args, 3 if args[3] == 'remoteagents-happ' else 0, '', '')
            calls.append(args)
            fail = bool(failure and args[:2] == ['systemctl', 'restart'])
            if fail: failure.pop()
            return subprocess.CompletedProcess(args, 1 if fail else 0, '', '')
        system = app.System(root, run)
        system.write('/etc/sing-box/config.json', json.dumps(channel(), indent=2).replace('\n', '\r\n'))
        # A stopped, never-managed Xray with a local socks inbound must be left alone.
        system.write('/usr/local/etc/remoteagents-happ/config.json', json.dumps({'inbounds': [{'protocol': 'socks', 'listen': '127.0.0.1', 'port': 1080}]}))
        system.write('/etc/remoteagents/lan/office/config.json', json.dumps({'static': ['10.123.0.0/24']}))
        system.actions.clear()
        e = SimpleNamespace(s=system, config=profile(), ssh_checked=False,
            rows=[dict(part='lan:office', state='ready')], install_code=lambda: None, check_ssh=lambda _: calls.append(['check-ssh']))
        def row(part, state, summary):
            e.rows.append(dict(part=part, state=state)); return state == 'ready'
        e.row = row
        return e, calls, failure

    def test_plan_apply_confirm_and_rollback(self):
        with tempfile.TemporaryDirectory() as tmp:
            e, calls, _ = self.transaction(tmp)
            original = e.s.read('/etc/sing-box/config.json')
            self.assertFalse(share.reconcile(e, False))
            self.assertFalse(e.s.actions)
            self.assertFalse(calls)
            self.assertFalse(share.reconcile(e, True))
            self.assertTrue(e.s.path(share.STATE).exists())
            self.assertTrue(any(c[0] == 'systemd-run' for c in calls))
            self.assertFalse(share.reconcile(e, False))
            e.ssh_checked = True
            self.assertTrue(share.reconcile(e, True))
            self.assertIn(['check-ssh'], calls)
            self.assertFalse(e.s.path(share.STATE).exists())
            self.assertTrue(share.reconcile(e, False))
            e.config['lan'][0].pop('share')
            e.ssh_checked = False
            self.assertFalse(share.reconcile(e, True))
            share.rollback(e.s)
            self.assertTrue(share.enabled(share.policy(profile())))
            self.assertNotEqual(e.s.read('/etc/sing-box/config.json'), original)
            # Rollback removal restores the previously confirmed rules.
            self.assertTrue(share.reconcile(SimpleNamespace(**{**vars(e), 'config': profile()}), False))

    def test_reconcile_never_reapplies_pending_lan_share(self):
        with tempfile.TemporaryDirectory() as tmp:
            e, calls, _ = self.transaction(tmp)
            self.assertFalse(share.reconcile(e, True))  # owner apply creates the transaction
            self.assertTrue(e.s.path(share.STATE).exists())
            e.periodic = True
            before = list(calls)
            self.assertTrue(share.reconcile(e, True))  # pending: waits, exit-0 style row
            self.assertEqual(calls, before)
            self.assertTrue(e.s.path(share.STATE).exists())
            # After the one-shot rollback the periodic run must not apply it again either.
            share.rollback(e.s)
            original = e.s.read('/etc/sing-box/config.json')
            calls.clear()
            self.assertFalse(share.reconcile(e, True))
            self.assertFalse(e.s.path(share.STATE).exists())
            self.assertEqual(e.s.read('/etc/sing-box/config.json'), original)
            self.assertFalse([c for c in calls if c[0] in ('systemd-run', 'systemctl')])

    def test_restart_failure_restores_files_and_route_bounds(self):
        with tempfile.TemporaryDirectory() as tmp:
            e, calls, failure = self.transaction(tmp)
            original = e.s.read('/etc/sing-box/config.json')
            failure.append(True)
            with self.assertRaises(app.Error):
                share.reconcile(e, True)
            self.assertEqual(e.s.read('/etc/sing-box/config.json'), original)
            self.assertFalse(e.s.path(share.STATE).exists())
            e.config['lan'][0]['share']['subnets'] = ['10.124.0.0/24']
            e.config['lan'][0]['testHost'] = '10.124.0.1'
            with self.assertRaisesRegex(share.Error, 'маршруты'):
                share.reconcile(e, True)

    def test_lan_subnets_use_bound_outbound(self):
        original = live_like()
        generated, record = share.generate(original, share.policy(profile()), 'singbox')
        outbound = dict(type='direct', tag='lan-office-out', bind_interface='tun-lan-office')
        self.assertIn(outbound, generated['outbounds'])
        self.assertEqual(record['outbounds'], [outbound])
        for rule in record['rules']:
            if ('ip_cidr' in rule or rule.get('type') == 'logical') and rule.get('outbound') != 'proxy-out':
                self.assertNotEqual(rule.get('outbound'), 'direct-out')
        self.assertEqual(share.egress_issues(generated, [dict(name='office', subnets=['10.123.0.0/24'])]), [])
        self.assertIs(generated['route']['auto_detect_interface'], True)
        self.assertEqual(generated['outbounds'][:-1], original['outbounds'])

    def test_detects_lan_route_missing_from_main_singbox(self):
        lans = [dict(name='office', subnets=['10.123.0.0/24'])]
        old = live_like()
        old['route']['rules'].insert(0, dict(inbound=['vless-in'], ip_cidr=['10.123.0.0/24'], action='route', outbound='direct-out'))
        final = live_like(); final['route']['rules'] = []
        unbound = live_like()
        unbound['outbounds'].append(dict(type='direct', tag='lan-office-out'))
        unbound['route']['rules'].insert(0, dict(ip_cidr=['10.123.0.0/24'], outbound='lan-office-out'))
        for config in (live_like(), old, final, unbound):
            with self.subTest(config=config):
                issues = share.egress_issues(config, lans)
                self.assertTrue(issues)
                self.assertIn('10.123.0.0/24', '; '.join(issues))
        self.assertIn('route.final', share.egress_issues(final, lans)[0])

    def test_old_manifest_upgrades_and_removal(self):
        old_cfg = live_like()
        old_rule = dict(inbound=['vless-in'], ip_cidr=['10.123.0.0/24'], action='route', outbound='direct-out')
        old_cfg['route']['rules'].insert(0, old_rule)
        old_record = dict(rules=[old_rule], dns=None, createdDns=False)
        p = profile(); p['lan'][0]['share'] = dict(subnets=['10.123.0.0/24'])
        new, rec = share.generate(old_cfg, share.policy(p), 'singbox', old_record)
        self.assertNotIn(old_rule, new['route']['rules'])
        self.assertEqual(share.egress_issues(new, [dict(name='office', subnets=['10.123.0.0/24'])]), [])
        self.assertEqual(share.generate(new, share.policy({}), 'singbox', rec)[0], live_like())
        self.assertEqual(share.generate(new, share.policy(p), 'singbox', rec)[0], new)
        foreign = live_like(); foreign['outbounds'].append(share.lan_outbound('office'))
        with self.assertRaises(share.Error):
            share.generate(foreign, share.policy(p), 'singbox')
        new['outbounds'][-1]['bind_interface'] = 'eth0'
        with self.assertRaises(share.Error):
            share.generate(new, share.policy(p), 'singbox', rec)

    def test_check_cli_read_only(self):
        generated, _ = share.generate(live_like(), share.policy(profile()), 'singbox')
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'candidate.json'
            for config, code in ((generated, 0), (live_like(), 1)):
                text = json.dumps(config)
                path.write_text(text)
                with patch.object(share, 'rollback', side_effect=AssertionError):
                    self.assertEqual(share.check(['office', '10.123.0.0/24'], path), code)
                self.assertEqual(path.read_text(), text)
        with patch.object(share, 'rollback', side_effect=AssertionError) as rollback, \
             patch.object(sys, 'argv', ['lan_share.py', 'check', 'office', '10.123.0.0/24']), \
             patch.object(share, 'check', return_value=0) as check:
            with self.assertRaises(SystemExit) as raised:
                share.main()
            self.assertEqual(raised.exception.code, 0)
            check.assert_called_once_with(['office', '10.123.0.0/24'])
            rollback.assert_not_called()

    def test_share_requires_lan_interface_name(self):
        for name in ('Office-Main', 'toolongname', '', None):
            with self.subTest(name=name):
                bad = profile(); bad['lan'][0]['name'] = name
                with self.assertRaises(share.Error):
                    share.policy(bad)

    def test_each_lan_has_own_destinations_and_discovered_subnets(self):
        p = profile()
        p['lan'].append(dict(name='lab', testHost='lab.example.org',
            subnets=['10.124.0.0/24'], share=dict(domains=['lab.example.org'],
            forwards=[dict(name='web', host='web.lab.example.org', port=8443)])))
        policy = share.policy(p)
        self.assertEqual([lan['name'] for lan in policy['lans']], ['lab', 'office'])
        generated, record = share.generate(live_like(), policy, 'singbox')
        for rule in record['rules']:
            if rule.get('type') == 'logical' and rule['outbound'].startswith('lan-'):
                cidrs = next(r['ip_cidr'] for r in rule['rules'] if 'ip_cidr' in r)
                self.assertEqual(cidrs, ['10.124.0.0/24'] if rule['outbound'] == 'lan-lab-out' else ['10.123.0.0/24'])
        with tempfile.TemporaryDirectory() as tmp:
            e, _, _ = self.transaction(tmp)
            e.config['lan'][0]['share'] = dict(domains=['service.example.org'])
            e.config['lan'][0]['testHost'] = 'service.example.org'
            e.s.write('/etc/remoteagents/lan/office/subnets', '10.125.0.0/24\n')
            share.reconcile(e, True)
            rules = e.s.read('/etc/sing-box/config.json')['route']['rules']
            local = next(r for r in rules if r.get('type') == 'logical' and r.get('outbound') == 'lan-office-out')
            self.assertIn({'ip_cidr': ['10.123.0.0/24', '10.125.0.0/24']}, local['rules'])


if __name__ == '__main__':
    unittest.main(failfast=True)
