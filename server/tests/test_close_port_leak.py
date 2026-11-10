#!/usr/bin/env python3
import copy
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('close_port_leak', ROOT / 'close_port_leak.py')
leak = importlib.util.module_from_spec(spec)
spec.loader.exec_module(leak)


def config():
    return {'log': {'disabled': True}, 'inbounds': [
        {'type': 'tun', 'tag': 'tun-in', 'address': ['172.30.0.1/30'], 'auto_route': True},
        {'type': 'mixed', 'tag': 'mixed-in', 'listen': '127.0.0.1', 'listen_port': 1080}],
        'outbounds': [{'type': 'socks', 'tag': 'proxy-out', 'server': 'proxy.example.invalid', 'server_port': 1080},
                      {'type': 'direct', 'tag': 'direct-out'}],
        'route': {'rules': [{'port': [22, 3389, 37091], 'outbound': 'direct-out'},
                            {'source_port': [22, 3389, 37091], 'outbound': 'direct-out'},
                            {'ip_is_private': True, 'outbound': 'direct-out'}], 'final': 'proxy-out'}}


class PortLeakTests(unittest.TestCase):
    def test_both_destination_and_source_rules_are_restricted(self):
        before = config()
        after, changes = leak.repair(before)
        self.assertEqual(len(changes), 2)
        self.assertEqual(after['route']['rules'][0]['inbound'], ['tun-in'])
        self.assertEqual(after['route']['rules'][1]['inbound'], ['tun-in'])
        self.assertEqual(after['route']['rules'][2], before['route']['rules'][2])
        self.assertEqual(after['outbounds'], before['outbounds'])
        self.assertEqual(leak.repair(after), (after, []))
        self.assertNotIn('inbound', before['route']['rules'][0])

    def test_only_target_ports_and_other_selectors_preserved(self):
        cfg = config()
        cfg['route']['rules'] = [{'port': [22, 80], 'network': 'tcp', 'outbound': 'direct-out'}]
        result, changes = leak.repair(cfg)
        self.assertEqual(result['route']['rules'], [
            {'port': [22], 'network': 'tcp', 'outbound': 'direct-out', 'inbound': ['tun-in']},
            {'port': [80], 'network': 'tcp', 'outbound': 'direct-out'}])
        self.assertEqual(len(changes), 1)

    def test_semantic_diff_contains_no_config_secrets(self):
        cfg = config()
        cfg['outbounds'][0]['password'] = 'TEST_ONLY_PASSWORD'
        result, changes = leak.repair(cfg)
        self.assertNotIn('TEST_ONLY_PASSWORD', json.dumps(changes))
        self.assertNotIn('proxy.example.invalid', json.dumps(changes))
        self.assertEqual(result['outbounds'], cfg['outbounds'])

    def test_public_cidr_exception_is_server_only_without_exposing_addresses(self):
        cfg = config()
        cfg['route']['rules'].append({'ip_cidr': ['203.0.113.0/24'], 'outbound': 'direct-out'})
        result, changes = leak.repair(cfg)
        self.assertEqual(result['route']['rules'][-1], {
            'ip_cidr': ['203.0.113.0/24'], 'outbound': 'direct-out', 'inbound': ['tun-in']})
        self.assertEqual(changes[-1]['selector'], 'ip_cidr')
        self.assertNotIn('203.0.113', json.dumps(changes))
        import contextlib
        import io
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            leak.show_diff(changes)
        self.assertNotIn('203.0.113', output.getvalue())
        self.assertIn('<addresses hidden>', output.getvalue())

    def test_private_cidr_preserved(self):
        cfg = config()
        private = {'ip_cidr': ['10.123.0.0/16'], 'outbound': 'direct-out'}
        cfg['route']['rules'].append(private)
        result, _ = leak.repair(cfg)
        self.assertEqual(result['route']['rules'][-1], private)

    def test_repaired_fixture_passes_real_singbox_check(self):
        source = config()
        source['route']['rules'].append({'ip_cidr': ['203.0.113.0/24'], 'outbound': 'direct-out'})
        cfg, _ = leak.repair(source)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'config.json'
            path.write_text(json.dumps(cfg))
            result = subprocess.run([shutil.which('sing-box'), 'check', '-c', str(path)],
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, 'sing-box check fixture failed')


if __name__ == '__main__':
    unittest.main()
