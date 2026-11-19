"""LAN computer config export: public settings only, all IO in temporary paths."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from test_config_export import Env, rc, ROOT


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
    def test_export_clinic_from_pc_access_when_snapshot_has_no_lan(self):
        with tempfile.TemporaryDirectory(prefix='clinic-export-') as directory:
            env = Env(directory)
            conf = json.loads((ROOT / 'server/lan-pc-access.clinic.example.json').read_text())
            runtime = Path(directory) / 'runtime' / 'clinic'
            runtime.mkdir(parents=True)
            subnets = conf['lans'][0]['subnets']
            (runtime / 'subnets').write_text('\n'.join(subnets))
            # Only confirmed subnet files are read, not VPN profiles or credentials.
            (runtime / 'profile.ovpn').write_text('SECRET-OVPN-SENTINEL')
            conf['lans'][0]['subnets'] = 'auto'
            access = Path(directory) / 'pc-access.json'
            access.write_text(json.dumps(conf)); access.chmod(0o600)
            env.c.update(lanPcAccess=str(access), lanRuntimeDir=str(runtime.parent)); env.write()
            snapshot = Path(env.c['serverConfig'])
            before = snapshot.read_bytes()
            exported, process = env.export()
            row = exported['lan'][0]
            self.assertEqual(set(row), {'name', 'share', 'testHost', 'testPort'})
            self.assertEqual((row['name'], row['testHost'], row['testPort']), ('clinic', '192.168.88.244', 22))
            self.assertEqual(set(row['share']['subnets']), set(subnets))
            self.assertEqual(len(row['share']['subnets']), 20)
            self.assertEqual(row['share']['domains'], ['*.eastclinic.ru'])
            self.assertEqual(row['share']['dnsServers'], ['192.168.88.11'])
            self.assertEqual(row['share']['hosts'], ['portal.eastclinic.ru'])
            self.assertNotIn('SECRET-OVPN-SENTINEL', process.stdout.decode())
            self.assertFalse(any(k.startswith('lan-') for k in exported['secrets']))
            self.assertEqual(snapshot.read_bytes(), before)

    def test_local_source_priority_missing_and_invalid(self):
        with tempfile.TemporaryDirectory(prefix='pc-source-') as directory:
            access = Path(directory) / 'pc-access.json'
            settings = {'lanPcAccess': str(access)}
            with self.assertRaises(rc.Error):
                rc.computer_lans(settings, {})
            with patch.object(rc, 'DEFAULT_LAN_PC_ACCESS', str(access)):
                self.assertEqual(rc.computer_lans({}, {'lan': []}), {'lan': []})
            access.write_text(json.dumps({'lans': [dict(name='office', subnets='obsolete')]})); access.chmod(0o600)
            explicit = rc.computer_sections({'lan': networks()})
            before = copy.deepcopy(explicit)
            self.assertEqual(rc.computer_lans(settings, explicit), explicit)
            self.assertEqual(explicit, before)
            access.write_text(json.dumps({'lans': [dict(name='office', subnets=['10.1.0.0/16'], testHost='10.1.0.1',
                                                       domains=['*.example.org'], testPort=22)]}))
            with self.assertRaises(rc.Error):
                rc.computer_lans(settings, {})
            access.write_text('{"lans":[{"name":"clinic","ovpn":"SECRET-SENTINEL"}]}')
            with self.assertRaises(rc.Error) as error:
                rc.computer_lans(settings, {})
            self.assertNotIn('SECRET-SENTINEL', str(error.exception))
            access.chmod(0o666)
            with self.assertRaises(rc.Error):
                rc.computer_lans(settings, {})

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

    def test_share_hosts_pass_through_and_are_validated(self):
        data = {'lan': networks()}
        data['lan'][0]['share']['hosts'] = ['portal.example.org', 'crm-api.example.org']
        public = rc.computer_sections(data)
        self.assertEqual(public['lan'][0]['share']['hosts'], ['portal.example.org', 'crm-api.example.org'])
        self.assertNotIn('hosts', public['lan'][1]['share'], 'empty list is not exported')
        data = {'lan': networks()}
        data['lan'][0]['share']['hosts'] = []
        self.assertNotIn('hosts', rc.computer_sections(data)['lan'][0]['share'], 'explicit empty list is not exported')
        too_many = ['h%d.example.org' % i for i in range(101)]
        bad = (['*.example.org'], ['portal.example.com'], ['example.com'], ['PORTAL.example.org'], ['10.123.0.5'], ['portal'],
               ['a.example.org', 'a.example.org'], 'portal.example.org', [5], too_many, ['bad name.example.org'])
        for hosts in bad:
            data = {'lan': networks()}
            data['lan'][0]['share']['hosts'] = hosts
            with self.subTest(hosts=hosts), self.assertRaises(rc.Error):
                rc.computer_sections(data)
        data = {'lan': networks()}
        data['lan'][0]['share']['hosts'] = ['h%d.example.org' % i for i in range(100)]
        self.assertEqual(len(rc.computer_sections(data)['lan'][0]['share']['hosts']), 100)
        data = {'lan': networks()}
        data['lan'][1]['share'] = dict(subnets=['10.124.0.0/24'], domains=[], dnsServers=[], hosts=['x.branch.example.org'])
        with self.assertRaises(rc.Error):
            rc.computer_sections(data)


if __name__ == '__main__':
    unittest.main()
