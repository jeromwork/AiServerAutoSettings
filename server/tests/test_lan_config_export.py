"""LAN computer config export: public settings only, all IO in temporary paths."""
import copy
import json
from pathlib import Path
import tempfile
import unittest

from test_config_export import Env, rc


def networks():
    return [dict(name='office', kind='openvpn', ovpn={'secret': 'lan-office-ovpn'},
                 auth={'secret': 'lan-office-auth'}, password={'secret': 'lan-office-password'},
                 subnets=['10.123.0.0/24'], testHost='10.123.0.10', testPort=443,
                 share=dict(subnets=['10.123.0.0/24'], domains=['*.example.org'], dnsServers=['10.123.0.53'],
                            forwards=[dict(name='old', host='10.123.0.10', port=22, localPort=18022)])),
            dict(name='branch', kind='openvpn', ovpn={'secret': 'lan-branch-ovpn'},
                 subnets=['10.124.0.0/24'], host='10.124.0.10', port=22,
                 dnsDomain='branch.example.org', dnsServer='10.124.0.53')]


class LanConfigExportTests(unittest.TestCase):
    def test_full_export_all_networks_without_openvpn_refs_and_slots(self):
        with tempfile.TemporaryDirectory(prefix='lan-config-export-') as directory:
            env = Env(directory)
            data = {'lan': networks()}
            data['lan'][0]['share']['enabled'] = False
            snapshot = Path(env.c['serverConfig'])
            snapshot.write_bytes(json.dumps(data, indent=2).replace('\n', '\r\n').encode())
            exported, _ = env.export()
            self.assertEqual([r['name'] for r in exported['lan']], ['office', 'branch'])
            self.assertEqual(exported['lan'][0]['share']['dnsServers'], ['10.123.0.53'])
            self.assertFalse(exported['lan'][0]['share']['enabled'])
            self.assertEqual(exported['lan'][1]['share'], dict(subnets=['10.124.0.0/24'], domains=['branch.example.org'], dnsServers=['10.124.0.53'], enabled=True))
            for row in exported['lan']:
                self.assertEqual(set(row), {'name', 'kind', 'share', 'testHost', 'testPort'})
                self.assertNotIn('forwards', row['share'])
            self.assertFalse(any(k.startswith('lan-') for k in exported['secrets']))
            self.assertEqual(json.loads(snapshot.read_text()), data, 'server snapshot must stay intact')

    def test_legacy_crlf_share_defaults_and_export_does_not_mutate_source(self):
        with tempfile.TemporaryDirectory(prefix='lan-config-old-') as directory:
            row = networks()[0]
            row['share'].pop('domains'); row['share'].pop('dnsServers')
            data = {'lan': [row]}
            snapshot = Path(directory) / 'snapshot.json'
            snapshot.write_bytes(json.dumps(data, indent=2).replace('\n', '\r\n').encode())
            snapshot.chmod(0o600)
            source = rc.server_sections({'serverConfig': str(snapshot)})
            before = copy.deepcopy(source)
            public = rc.computer_sections(source)
            self.assertEqual(source, before)
            self.assertEqual(public['lan'][0]['share'], dict(subnets=['10.123.0.0/24'], domains=[], dnsServers=[], enabled=True))

    def test_dns_requires_own_network_and_domain_requires_dns(self):
        for servers in (['8.8.8.8'], ['10.124.0.53'], ['10.123.0.999'], ['10.123.0.053'], ['::1'], [53], '10.123.0.53', None,
                        ['10.123.0.' + str(i) for i in range(50, 55)]):
            data = {'lan': networks()}
            data['lan'][0]['share']['dnsServers'] = servers
            with self.subTest(servers=servers), self.assertRaises(rc.Error):
                rc.computer_sections(data)
        data = {'lan': networks()}
        data['lan'][0]['share'].pop('dnsServers')
        with self.assertRaisesRegex(rc.Error, 'Для доменов сети office укажите share.dnsServers'):
            rc.computer_sections(data)

    def test_explicit_share_wins_over_server_dns(self):
        data = {'lan': networks()}
        data['lan'][1]['share'] = dict(subnets=['10.124.0.0/24'], domains=[], dnsServers=[], enabled=False)
        public = rc.computer_sections(data)
        self.assertEqual(public['lan'][1]['share'], data['lan'][1]['share'])


if __name__ == '__main__':
    unittest.main()
