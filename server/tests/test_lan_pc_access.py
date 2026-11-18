#!/usr/bin/env python3
"""Offline: чистые функции lan_pc_access, без sing-box и сети."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('lan_pc_access', ROOT / 'server' / 'lan_pc_access.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

BASE = {'inbounds': [{'type': 'vless', 'tag': 'vless-in', 'listen_port': 443}],
        'outbounds': [{'type': 'direct', 'tag': 'direct-out'}, {'type': 'socks', 'tag': 'proxy-out'}],
        'route': {'rules': [{'ip_is_private': True, 'outbound': 'direct-out'}], 'final': 'proxy-out'}}


class PcAccess(unittest.TestCase):
    def lan_dir(self):
        d = tempfile.mkdtemp()
        (Path(d) / 'corp').mkdir()
        (Path(d) / 'corp' / 'config.json').write_text(json.dumps({'subnets': ['10.123.0.0/24']}))
        (Path(d) / 'corp' / 'subnets').write_text('10.124.0.0/23\n')
        return d

    def test_auto_subnets_route_to_bound_outbound(self):
        d = self.lan_dir()
        generated, record, _ = m.plan(BASE, {'lans': [{'name': 'corp'}]}, None, d)
        out = [o for o in generated['outbounds'] if o['tag'] == 'lan-corp-out'][0]
        self.assertEqual(out['bind_interface'], 'tun-lan-corp')
        first = generated['route']['rules'][0]
        self.assertEqual(first['outbound'], 'lan-corp-out')
        self.assertEqual(first['ip_cidr'], ['10.123.0.0/24', '10.124.0.0/23'])
        self.assertEqual(first['inbound'], ['vless-in'])

    def test_idempotent_and_removable(self):
        d = self.lan_dir()
        conf = {'lans': [{'name': 'corp'}]}
        generated, record, _ = m.plan(BASE, conf, None, d)
        again, _, _ = m.plan(generated, conf, record, d)
        self.assertEqual(again, generated)
        removed, _, _ = m.plan(generated, None, record, d)
        self.assertEqual(removed, BASE)

    def test_bad_input_rejected(self):
        d = self.lan_dir()
        for conf in ({'lans': [{'name': 'Bad'}]}, {'lans': [{'name': 'corp', 'subnets': ['8.8.8.0/24']}]},
                     {'lans': [{'name': 'nolan'}]}):
            with self.assertRaises(m.Error):
                m.plan(BASE, conf, None, d)


if __name__ == '__main__':
    unittest.main()
