#!/usr/bin/env python3
"""Offline only: temporary roots, pure generation and a recording process runner."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest
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
            calls.append(args)
            fail = bool(failure and args[:2] == ['systemctl', 'restart'])
            if fail: failure.pop()
            return subprocess.CompletedProcess(args, 1 if fail else 0, '', '')
        system = app.System(root, run)
        system.write('/etc/sing-box/config.json', json.dumps(channel(), indent=2).replace('\n', '\r\n'))
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


if __name__ == '__main__':
    unittest.main(failfast=True)
