#!/usr/bin/env python3
"""Rootless tests: never invoke real OpenVPN, ip, systemd or nft."""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('lan_vpn', ROOT / 'lan_vpn.py')
lan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lan)
FIXTURE = ROOT / 'tests/fixtures/unsafe.ovpn'
FINGERPRINT = ':'.join(['AB', '01', 'CD', 'EF'] * 8)


def config():
    return {'log': {'disabled': True}, 'inbounds': [
        {'type': 'tun', 'tag': 'tun-in', 'address': ['172.30.0.1/30'], 'auto_route': True},
        {'type': 'mixed', 'tag': 'mixed-in', 'listen': '127.0.0.1', 'listen_port': 1080}],
        'outbounds': [{'type': 'socks', 'tag': 'proxy-out', 'server': 'proxy.example.invalid', 'server_port': 1080},
                      {'type': 'direct', 'tag': 'direct-out'}],
        'route': {'rules': [{'ip_is_private': True, 'outbound': 'direct-out'}], 'final': 'proxy-out'}}


class ImportTests(unittest.TestCase):
    def render(self, text=None, extra=(), server_fingerprint=None):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'in.ovpn'
            source.write_bytes((FIXTURE.read_text() if text is None else text).replace('\n', '\r\n').encode())
            out = io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
                client, nets, gateways = lan.import_client('office', source, extra, server_fingerprint=server_fingerprint)
                self.assertEqual(gateways, [])
            self.assertEqual(out.getvalue(), '')
            return client, nets

    def test_fingerprint_normalization_and_server_verification(self):
        for value in (FINGERPRINT, FINGERPRINT.lower(), FINGERPRINT.replace(':', ''),
                      FINGERPRINT.replace(':', '').lower(), FINGERPRINT.replace('CD', 'cD')):
            with self.subTest(value=value):
                client, _ = self.render(server_fingerprint=value)
                self.assertIn('\npeer-fingerprint ' + FINGERPRINT + '\n', client)
                self.assertNotIn('remote-cert-tls', client)
                self.assertIn('<ca>\nTEST ONLY CA PLACEHOLDER\n</ca>', client)
        client, _ = self.render()
        self.assertEqual(client.count('remote-cert-tls server\n'), 1)
        self.assertNotIn('peer-fingerprint', client)

    def test_fingerprint_rejects_malformed_values(self):
        for value in ('', 'AB' * 31, 'AB' * 33, 'GG' * 32, FINGERPRINT + ':', ':' + FINGERPRINT,
                      FINGERPRINT.replace(':', '-', 1), FINGERPRINT.replace(':', '', 1),
                      'A:' * 32, FINGERPRINT + '\n', ' ' + FINGERPRINT, 123, False):
            with self.subTest(value=value), self.assertRaisesRegex(lan.Error, 'Некорректный --server-fingerprint'):
                self.render(server_fingerprint=value)

    def test_profile_cannot_weaken_or_supply_server_verification(self):
        text = FIXTURE.read_text().replace('remote-cert-tls server', 'remote-cert-tls none')
        for pin in (None, FINGERPRINT):
            with self.subTest(pin=pin):
                client, _ = self.render(text, server_fingerprint=pin)
                self.assertNotIn('remote-cert-tls "none"', client)
                self.assertEqual('remote-cert-tls server\n' in client, pin is None)
                self.assertEqual('peer-fingerprint ' + FINGERPRINT + '\n' in client, pin is not None)
                for directive in ('peer-fingerprint ' + FINGERPRINT,
                                  '--peer-fingerprint ' + FINGERPRINT,
                                  '<peer-fingerprint>\n' + FINGERPRINT + '\n</peer-fingerprint>'):
                    with self.subTest(directive=directive), self.assertRaises(lan.Error):
                        self.render(text + '\n' + directive, server_fingerprint=pin)
                without_ca = text.replace('<ca>\nTEST ONLY CA PLACEHOLDER\n</ca>', '')
                with self.assertRaisesRegex(lan.Error, 'Требуется inline CA'):
                    self.render(without_ca, server_fingerprint=pin)

    def test_crlf_inline_and_routes(self):
        client, nets = self.render(extra=['192.168.143.1/24'])
        self.assertNotIn('\r', client)
        self.assertIn('<key>\nTEST_ONLY_SECRET_NEVER_PRINT\n</key>', client)
        self.assertEqual(nets, ['10.123.0.0/16', '192.168.143.0/24'])
        self.assertIn('dev tun-lan-office\n', client)
        self.assertIn('route-noexec\n', client)
        self.assertNotIn('\nroute ', client)
        self.assertNotIn('\nredirect-gateway ', client)
        self.assertNotIn('\ndhcp-option ', client)
        self.assertNotIn('\nroute-ipv6 ', client)
        self.assertNotIn('\nifconfig-ipv6 ', client)
        self.assertNotIn('pull-filter accept', client)
        for option in ['redirect-gateway', 'dhcp-option', 'route-ipv6', 'ifconfig-ipv6']:
            self.assertIn('pull-filter ignore "' + option + '"', client)

    def test_code_execution_and_external_files_rejected(self):
        for extra in ['up /tmp/hook', 'plugin /tmp/plugin.so', 'config more.conf',
                      'management 127.0.0.1 1234', 'setenv PATH /tmp',
                      'log /tmp/secret', 'ca /tmp/ca.crt', '<connection>\nremote other.invalid\n</connection>',
                      '--up /tmp/x', 'script-security 3', 'ifconfig 203.0.113.1 203.0.113.2']:
            with self.subTest(option=extra.split()[0]):
                with self.assertRaises(lan.Error) as error:
                    self.render(FIXTURE.read_text() + '\n' + extra + '\n')
                self.assertNotIn('/tmp', str(error.exception))

    def test_blocks_and_names(self):
        for text in [FIXTURE.read_text() + '\n<key>\nX\n</key>', FIXTURE.read_text() + '\n<key>',
                     FIXTURE.read_text().replace('</key>', '<ca>')]:
            with self.assertRaises(lan.Error):
                self.render(text)
        for name in ['../a', 'toolongname', 'OFFICE', 'a-b', 'a;id', '']:
            with self.assertRaises(lan.Error):
                lan.import_client(name, FIXTURE)

    def test_public_v6_and_partial_default_forbidden(self):
        for subnet in ['0.0.0.0/0', '0.0.0.0/1', '128.0.0.0/1', '203.0.113.0/24',
                       '100.64.0.0/10', '127.0.0.0/8', '::/0', 'fd00::/8', '0.0.0.0/2']:
            with self.subTest(subnet=subnet), self.assertRaises(lan.Error):
                lan.networks([subnet])

    def test_push_ignores_split_default_and_public(self):
        env = {'route_network_1': '0.0.0.0', 'route_netmask_1': '128.0.0.0',
               'route_network_2': '128.0.0.0', 'route_netmask_2': '128.0.0.0',
               'route_network_3': '10.124.0.0', 'route_netmask_3': '255.255.0.0',
               'route_ipv6_network_1': '::/0'}
        self.assertEqual(lan.pushed_routes(env), ['10.124.0.0/16'])
        # Public, CGNAT and private-straddling pushes are dropped, never routed into the LAN.
        env.update(route_network_4='203.0.113.0', route_netmask_4='255.255.255.0',
                   route_network_5='100.64.0.0', route_netmask_5='255.192.0.0',
                   route_network_6='192.168.0.0', route_netmask_6='255.254.0.0',
                   route_network_7='192.168.88.0', route_netmask_7='255.255.255.0',
                   route_network_8='104.18.32.47')
        self.assertEqual(lan.pushed_routes(env), ['10.124.0.0/16', '192.168.88.0/24'])
        self.assertEqual(lan.pushed_routes({'route_network_1': '8.8.8.0', 'route_netmask_1': '255.255.255.0'}), [])
        env.update(route_network_9='not-an-ip')
        with self.assertRaises(lan.Error):
            lan.pushed_routes(env)


class RenderTests(unittest.TestCase):
    def test_nft_separates_interfaces_and_blocks_all_other_traffic(self):
        rules = lan.nft_rules({'office': {'subnets': ['10.123.0.0/16']},
                               'other': {'subnets': ['192.168.143.0/24']}})
        self.assertIn('table inet remoteagents_lan', rules)
        for chain in ['input', 'output', 'forward', 'postrouting']:
            self.assertIn('hook ' + chain, rules)
        self.assertIn('oifname "tun-lan-office" ip daddr { 10.123.0.0/16 } accept', rules)
        self.assertIn('oifname "tun-lan-other" ip daddr { 192.168.143.0/24 } accept', rules)
        self.assertEqual(rules.count('oifname "tun-lan-*" drop'), 3)
        self.assertIn('ct state established,related accept', rules)
        self.assertIn('iifname "tun-lan-*" drop', rules)
        self.assertNotIn('ip6 daddr', rules)
        self.assertNotIn('0.0.0.0/0', rules)
        self.assertNotIn('ip saddr { 192.168.143.0/24 } ct state new', rules)

    def test_empty_guard_still_denies(self):
        rules = lan.nft_rules({})
        self.assertEqual(rules.count('oifname "tun-lan-*" drop'), 3)
        self.assertNotIn(' daddr ', rules)

    def test_singbox_only_exclusions_and_idempotent(self):
        old = config()
        old['inbounds'][0]['route_exclude_address'] = ['203.0.113.7/32', '10.124.0.0/16']
        old['test-secret'] = 'UUID-SECRET-NEVER-PRINT'
        new = lan.patch_singbox(old, ['10.124.0.0/16'], ['10.123.0.0/16'])
        want = copy.deepcopy(old)
        want['inbounds'][0]['route_exclude_address'] = ['203.0.113.7/32', '10.123.0.0/16']
        self.assertEqual(new, want)
        self.assertEqual(lan.patch_singbox(new, ['10.123.0.0/16'], ['10.123.0.0/16']), new)
        diff = lan.exclusion_diff(old, new)
        self.assertIn('- 10.124.0.0/16', diff)
        self.assertIn('+ 10.123.0.0/16', diff)
        self.assertNotIn('UUID-SECRET', diff)
        self.assertNotIn('203.0.113.7', diff)
        self.assertNotIn('proxy.example.invalid', diff)

    def test_singbox_rejects_unsupported_config(self):
        for change in ['final', 'private', 'redirect']:
            cfg = config()
            if change == 'final':
                cfg['route']['final'] = 'direct-out'
            elif change == 'private':
                cfg['route']['rules'] = []
            else:
                cfg['inbounds'][0]['auto_redirect'] = True
            with self.assertRaises(lan.Error):
                lan.patch_singbox(cfg, [], [])

    def test_real_singbox_check_1_14_4(self):
        binary = shutil.which('sing-box')
        self.assertIsNotNone(binary, 'Требуется sing-box в PATH')
        version = subprocess.run([binary, 'version'], text=True, capture_output=True, check=True)
        self.assertIn('1.14.4', version.stdout.splitlines()[0])
        cfg = lan.patch_singbox(config(), [], ['10.123.0.0/16', '192.168.143.0/24', '93.184.216.34/32'])
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'config.json'
            path.write_text(json.dumps(cfg))
            result = subprocess.run([binary, 'check', '-c', str(path)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, 'sing-box check fixture failed')


class SafetyTests(unittest.TestCase):
    def test_atomic_permissions(self):
        with tempfile.TemporaryDirectory() as tmp:
            file = Path(tmp) / 'secret'
            lan.atomic(file, 'synthetic-secret')
            self.assertEqual(file.stat().st_mode & 0o777, 0o600)

    def test_timer_failure_prevents_network_mutation(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / 'state'
            state.mkdir()
            sb = Path(tmp) / 'sing-box.json'
            sb.write_text(json.dumps(config()))
            calls = []
            def fail(args, **kwargs):
                calls.append(args)
                if args[0] == 'nft':
                    return subprocess.CompletedProcess(args, 1, '', '')
                raise lan.Error('timer failed')
            with patch.object(lan, 'STATE', state), patch.object(lan, 'SB', sb), \
                 patch.object(lan, 'profiles', return_value={}), patch.object(lan, 'network_pending', return_value=[]), \
                 patch.object(lan, 'run', side_effect=fail):
                with self.assertRaises(lan.Error):
                    lan.start_transaction('office', 'enable')
            self.assertFalse((state / 'pending').exists())
            self.assertEqual(len(calls), 2)
            self.assertEqual(calls[-1][0], 'systemd-run')

    def test_rollback_restores_nft_snapshot_and_config_metadata(self):
        for boot in [False, True]:
            with self.subTest(boot=boot), tempfile.TemporaryDirectory() as tmp:
                state = Path(tmp) / 'state'
                pending = state / 'pending'
                pending.mkdir(parents=True)
                sb = Path(tmp) / 'config.json'
                before = config()
                sb.write_text(json.dumps(lan.patch_singbox(before, [], ['10.123.0.0/16'])))
                lan.save(pending / 'sing-box.json', before)
                lan.save(pending / 'profiles.json', {})
                lan.save(pending / 'managed.json', [])
                lan.save(pending / 'meta.json', {'name': 'office', 'uid': 123, 'gid': 456, 'mode': 0o640})
                nft = 'table inet remoteagents_lan { }\n'
                lan.save(pending / 'nft.json', {'present': True, 'text': nft})
                calls = []
                def run(args, **kwargs):
                    calls.append((args, kwargs.get('input')))
                    return subprocess.CompletedProcess(args, 0, '{"nftables":[]}', '')
                with patch.object(lan, 'STATE', state), patch.object(lan, 'SB', sb), \
                     patch.object(lan, 'profiles', return_value={}), patch.object(lan, 'event'), \
                     patch.object(lan, 'run', side_effect=run), patch.object(lan.os, 'chown') as chown, \
                     contextlib.redirect_stdout(io.StringIO()):
                    lan.rollback(boot=boot)
                self.assertEqual(json.loads(sb.read_text()), before)
                self.assertEqual(sb.stat().st_mode & 0o777, 0o640)
                chown.assert_called_once_with(sb, 123, 456)
                batches = [data for args, data in calls if args[:2] == ['nft', '-f']]
                self.assertEqual(batches, ['delete table inet remoteagents_lan\n' + nft])
                restarts = [args for args, _ in calls if args[:2] == ['systemctl', 'restart']]
                self.assertEqual(bool(restarts), not boot)
                self.assertFalse(pending.exists())

    def test_global_route_audit_rejects_unknown_tunnel_internet_and_multipath(self):
        for route in [
            {'dst': 'default', 'dev': 'tun-lan-rogue'},
            {'dst': '0.0.0.0/1', 'dev': 'tun-lan-office'},
            {'dst': '128.0.0.0/1', 'nexthops': [{'dev': 'tun-lan-office'}]},
            {'dst': '203.0.113.0/24', 'dev': 'tun-lan-office'}]:
            def run(args, **kwargs):
                return subprocess.CompletedProcess(args, 0, json.dumps([route]) if '-4' in args else '[]', '')
            with patch.object(lan, 'run', side_effect=run), self.assertRaises(lan.Error):
                lan.audit_all_tunnels()
        def ipv6(args, **kwargs):
            return subprocess.CompletedProcess(args, 0, '[]' if '-4' in args else
                                               '[{"dst":"::/0","dev":"tun-lan-office"}]', '')
        with patch.object(lan, 'run', side_effect=ipv6), self.assertRaises(lan.Error):
            lan.audit_all_tunnels()

    def test_stop_all_attempts_remaining_clients_if_one_fails(self):
        called = []
        def stop(name, boot):
            called.append(name)
            if name == 'office':
                raise lan.Error('failure')
        with patch.object(lan, 'stop_client', side_effect=stop), patch.object(lan, 'event'):
            with self.assertRaises(lan.Error):
                lan.stop_clients(['office', 'other'])
        self.assertEqual(called, ['office', 'other'])

    def test_watchdog_denies_traffic_and_stops_every_client(self):
        calls = []
        data = {n: {'subnets': ['10.123.0.0/16'], 'table': 42000 + i, 'priority': 1000 + i}
                for i, n in enumerate(['office', 'other'])}
        def run(args, **kwargs):
            calls.append(args)
            if args[:2] == ['systemctl', 'is-active'] or args[:4] == ['ip', '-j', 'link', 'show']:
                return subprocess.CompletedProcess(args, 1, '', '')
            return subprocess.CompletedProcess(args, 0, '', '')
        def fw(profiles):
            calls.append(['firewall', profiles])
        with patch.object(lan, 'active', return_value=data), \
             patch.object(lan, 'nft_identity', side_effect=lan.Error('missing')), \
             patch.object(lan, 'run', side_effect=run), \
             patch.object(lan, 'route_ops'), patch.object(lan, 'update'), \
             patch.object(lan, 'event'), patch.object(lan, 'revert_dns'), patch.object(lan, 'sync_singbox'), \
             patch.object(lan, 'firewall', side_effect=fw):
            lan.watch()
        stopped = [c for c in calls if c[:2] == ['systemctl', 'stop']]
        self.assertEqual(len(stopped), 2)
        self.assertEqual(calls[0], ['firewall', {}])
        self.assertEqual(calls[-1], ['firewall', {}])
        self.assertTrue(all(not p['enabled'] for p in data.values()))


class ReconnectRouteTests(unittest.TestCase):
    def test_rule_dst_reads_separate_prefix_length(self):
        self.assertEqual(lan.rule_dst({'dst': '192.168.88.0', 'dstlen': 24}), '192.168.88.0/24')
        self.assertEqual(lan.rule_dst({'dst': '10.0.0.1'}), '10.0.0.1/32')
        self.assertIsNone(lan.rule_dst({'src': 'all'}))

    def test_reconnect_does_not_add_existing_rules(self):
        data = {'table': 42000, 'priority': 1000, 'subnets': ['192.168.87.0/24', '192.168.88.0/21']}
        existing = [{'priority': 1000, 'src': 'all', 'dst': '192.168.87.0', 'dstlen': 24, 'table': '42000'},
                    {'priority': 1000, 'src': 'all', 'dst': '192.168.88.0', 'dstlen': 21, 'table': '42000'}]
        calls = []

        def fake_run(args, check=True, **kwargs):
            calls.append([str(a) for a in args])
            return SimpleNamespace(returncode=0, stdout=json.dumps(existing) if 'show' in args else '')
        with patch.object(lan, 'run', fake_run):
            lan.route_ops('clinic', data)
        self.assertFalse([c for c in calls if c[:4] == ['ip', '-4', 'rule', 'add']])
        self.assertEqual(sum(c[:4] == ['ip', '-4', 'route', 'replace'] for c in calls), 3)


class InternetNeverViaLanTests(unittest.TestCase):
    """Owner requirement 1: Internet only via proxy-out, even if the LAN offers a gateway/DNS."""
    def test_profile_and_push_cannot_become_default_route_or_dns(self):
        client, nets = ImportTests.render(self)
        for unsafe in ('redirect-gateway', 'dhcp-option', 'route 0.0.0.0', 'route-ipv6', 'pull-filter accept'):
            self.assertNotIn('\n' + unsafe, '\n' + client.split('pull-filter ignore')[0])
        for pushed in ('redirect-gateway', 'redirect-private', 'dhcp-option', 'dns', 'route-ipv6', 'ifconfig-ipv6', 'block-ipv6'):
            self.assertIn('pull-filter ignore "' + pushed + '"', client)
        self.assertIn('route-noexec\n', client)
        self.assertTrue(all(lan.ipaddress.ip_network(n).is_private for n in nets))
        env = {'route_network_1': '0.0.0.0', 'route_netmask_1': '0.0.0.0', 'route_network_2': '10.124.0.0',
               'route_netmask_2': '255.255.0.0'}
        self.assertEqual(lan.pushed_routes(env), ['10.124.0.0/16'])

    def test_singbox_final_stays_proxy_out_and_lan_requires_it(self):
        cfg = config()
        cfg['outbounds'][0]['password'] = 'TEST_ONLY_PROXY_PASSWORD'
        patched = lan.patch_singbox(cfg, [], ['10.123.0.0/16', '192.168.143.0/24'])
        self.assertEqual(patched['route'], cfg['route'])
        self.assertEqual(patched['outbounds'], cfg['outbounds'])
        cfg['route']['final'] = 'direct-out'
        with self.assertRaises(lan.Error):
            lan.patch_singbox(cfg, [], ['10.123.0.0/16'])

    def test_kernel_guard_drops_everything_but_lan_subnets(self):
        rules = lan.nft_rules({'office': {'subnets': ['10.123.0.0/16']}})
        for chain in ('output', 'egress'):
            body = rules.split(' chain ' + chain + ' ')[1].split('\n }')[0]
            self.assertIn('oifname "tun-lan-office" ip daddr { 10.123.0.0/16 } accept', body)
            self.assertTrue(body.rstrip().endswith('oifname "tun-lan-*" drop'))


class AuthAndMultiLanTests(unittest.TestCase):
    def write(self, tmp, text):
        source = Path(tmp) / 'p.ovpn'
        source.write_text(text.replace('\n', '\r\n'))
        return source

    def test_interactive_auth_needs_credentials_and_is_inlined(self):
        base = 'remote vpn.example.invalid 1194\n<ca>\nX\n</ca>\nauth-user-pass\n'
        with tempfile.TemporaryDirectory() as tmp:
            source = self.write(tmp, base)
            with self.assertRaises(lan.Error) as error:
                lan.import_client('office', source)
            self.assertIn('логин и пароль', str(error.exception))
            client, _, _ = lan.import_client('office', source, auth=('TEST_ONLY_LAN_USER', 'TEST_ONLY_LAN_PASS'))
            self.assertIn('<auth-user-pass>\nTEST_ONLY_LAN_USER\nTEST_ONLY_LAN_PASS\n</auth-user-pass>', client)
            self.assertNotIn('\nauth-user-pass\n', client)
            for bad in [('u\n', 'p'), ('u', ''), ('</auth-user-pass>', 'p')]:
                with self.assertRaises(lan.Error):
                    lan.import_client('office', source, auth=bad)
            self.assertNotIn('/', str(error.exception))

    def test_auth_stdin_skips_sudo_line_and_marker(self):
        args = type('A', (), {'auth_stdin': True, 'ask_auth': False})()
        data = 'SUDO_LINE\r\n' + lan.MARKER + '\r\n' + json.dumps({'username': 'u', 'password': 'p w'}) + '\n'
        with patch.object(lan.sys, 'stdin', io.StringIO(data)):
            self.assertEqual(lan.read_auth(args), ('u', 'p w'))
        with patch.object(lan.sys, 'stdin', io.StringIO('{"username":"u","password":"p"}')), self.assertRaises(lan.Error):
            lan.read_auth(args)

    def test_two_lans_have_separate_tables_and_guards(self):
        rules = lan.nft_rules({'office': {'subnets': ['10.123.0.0/16']}, 'home': {'subnets': ['192.168.143.0/24']}})
        self.assertIn('oifname "tun-lan-home" ip daddr { 192.168.143.0/24 } accept', rules)
        self.assertNotIn('oifname "tun-lan-home" ip daddr { 10.123.0.0/16 }', rules)

    def test_lan_cannot_shadow_server_networks(self):
        routes = [{'dst': 'default', 'dev': 'eth0'}, {'dst': '172.17.0.0/16', 'dev': 'docker0'},
                  {'dst': '10.124.0.0/16', 'dev': 'tun-lan-other'}]
        def run(args, **kwargs):
            return subprocess.CompletedProcess(args, 0, json.dumps(routes), '')
        with tempfile.TemporaryDirectory() as tmp:
            sb = Path(tmp) / 'c.json'
            sb.write_text(json.dumps(config()))
            with patch.object(lan, 'run', side_effect=run), patch.object(lan, 'SB', sb):
                lan.local_conflicts(['10.123.0.0/16', '192.168.1.0/24'])
                with self.assertRaises(lan.Error) as error:
                    lan.local_conflicts(['172.16.0.0/12'])
                self.assertIn('docker0', str(error.exception))
                with self.assertRaises(lan.Error):
                    lan.local_conflicts(['172.30.0.0/24'])  # sing-box TUN address
                lan.local_conflicts(['10.124.0.0/16'])  # another LAN is checked by enable() separately

    def test_any_pending_network_change_blocks_transaction(self):
        with tempfile.TemporaryDirectory() as tmp:
            pending = Path(tmp) / 'proxy-out/pending'
            pending.mkdir(parents=True)
            with patch.object(lan, 'PENDING', (pending,)), patch.object(lan, 'run') as run, \
                 patch.object(lan, 'STATE', Path(tmp) / 'lan'):
                with self.assertRaises(lan.Error):
                    lan.start_transaction('office', 'enable')
                run.assert_not_called()

    def test_public_status_has_no_secrets(self):
        with tempfile.TemporaryDirectory() as tmp:
            state, public = Path(tmp) / 'state', Path(tmp) / 'public'
            state.mkdir()
            lan.save(state / 'office.json', {'ok': True, 'summary': 'test passed', 'updatedAt': 'x'})
            data = {'enabled': True, 'ready': True, 'subnets': ['10.123.0.0/16'], 'baseline': 'HASH_NEVER_PUBLIC'}
            with patch.object(lan, 'STATE', state), patch.object(lan, 'PUBLIC', public), \
                 patch.object(lan, 'profiles', return_value={'office': data}):
                lan.publish_lan()
                text = (public / 'lan.json').read_text()
                self.assertEqual((public / 'lan.json').stat().st_mode & 0o777, 0o644)
                self.assertNotIn('HASH_NEVER_PUBLIC', text)
                self.assertNotIn('10.123', text)
                ok = subprocess.CompletedProcess([], 0, '', '')
                with patch.object(lan, 'run', return_value=ok), contextlib.redirect_stdout(io.StringIO()) as out:
                    lan.public_status()
                row = json.loads(out.getvalue())
                self.assertEqual((row['name'], row['active'], row['ok']), ('office', True, True))


def endpoint(ip='93.184.216.34', proto='udp', port=1313):
    return {'ip': ip, 'proto': proto, 'port': port}


def lan_profile(subnet='10.123.0.0/16', gateways=None, enabled=False, slot=0):
    data = {'$schema': '../config.schema.json', 'version': 1, 'enabled': enabled, 'ready': enabled,
            'static': [subnet], 'subnets': [subnet], 'dns': None, 'table': 42000 + slot, 'priority': 1000 + slot}
    if gateways is not None:
        data['endpoints'] = gateways
    return data


class FingerprintConfigTests(unittest.TestCase):
    def test_cli_persists_pin_and_checks_repeated_add(self):
        for pin in (None, FINGERPRINT):
            with self.subTest(pin=pin), tempfile.TemporaryDirectory() as tmp, contextlib.ExitStack() as stack:
                state, etc = Path(tmp) / 'state', Path(tmp) / 'etc'
                stack.enter_context(patch.object(lan, 'STATE', state))
                stack.enter_context(patch.object(lan, 'ETC', etc))
                stack.enter_context(patch.object(lan.os, 'geteuid', return_value=0))
                stack.enter_context(patch.object(lan.os, 'chown'))
                stack.enter_context(patch.object(lan.os, 'fchown'))
                stack.enter_context(patch.object(lan, 'network_pending', return_value=[]))
                stack.enter_context(patch.object(lan, 'install_runtime'))
                enable = stack.enter_context(patch.object(lan, 'enable'))
                base = ['lan', 'add', 'office', str(FIXTURE), '--ip-check-url', 'https://ip.example.invalid']
                flags = ['--server-fingerprint', pin.replace(':', '').lower()] if pin else []
                with patch.object(lan.sys, 'argv', base + flags):
                    lan.main()
                data = lan.profile('office')
                self.assertEqual(data.get('server_fingerprint'), pin)
                self.assertEqual('server_fingerprint' in data, pin is not None)
                client = (etc / 'office/client.conf').read_text()
                self.assertEqual('peer-fingerprint ' + FINGERPRINT + '\n' in client, pin is not None)
                self.assertEqual('remote-cert-tls server\n' in client, pin is None)
                enable.assert_called_once_with('office', 'https://ip.example.invalid')
                with patch.object(lan.sys, 'argv', base + (['--server-fingerprint', pin] if pin else [])):
                    lan.main()
                # Dropping or changing the pin requires explicit remove/add.
                alternate = [] if pin else ['--server-fingerprint', FINGERPRINT]
                with patch.object(lan.sys, 'argv', base + alternate), self.assertRaisesRegex(lan.Error, 'Имя занято'):
                    lan.main()
                self.assertEqual(lan.profile('office'), data)
                self.assertEqual((etc / 'office/client.conf').read_text(), client)
                if pin:
                    # Even an identical generated client must agree with the JSON pin.
                    data['server_fingerprint'] = ':'.join(['00'] * 32)
                    lan.update('office', data)
                    with patch.object(lan.sys, 'argv', base + flags), self.assertRaisesRegex(lan.Error, 'Имя занято'):
                        lan.main()

    def test_cli_invalid_pin_fails_before_files_or_runtime(self):
        with patch.object(lan.sys, 'argv', ['lan', 'add', 'office', str(FIXTURE),
                         '--server-fingerprint', 'TEST_ONLY_INVALID', '--ip-check-url', 'https://ip.example.invalid']), \
             patch.object(lan, 'install_runtime') as runtime, patch.object(lan, 'import_client') as importer, \
             patch.object(lan.Path, 'mkdir') as mkdir, self.assertRaisesRegex(lan.Error, 'Некорректный --server-fingerprint'):
            lan.main()
        runtime.assert_not_called()
        importer.assert_not_called()
        mkdir.assert_not_called()

    def test_config_read_requires_canonical_pin(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(lan, 'ETC', Path(tmp)):
            data = lan_profile()
            lan.update('office', data)
            self.assertNotIn('server_fingerprint', lan.profile('office'))
            data['server_fingerprint'] = FINGERPRINT
            lan.update('office', data)
            self.assertEqual(lan.profile('office')['server_fingerprint'], FINGERPRINT)
            for value in (None, '', FINGERPRINT.lower(), FINGERPRINT.replace(':', ''),
                          '00:' * 32, 0, [], {}, FINGERPRINT + '\nverb 9'):
                with self.subTest(value=value):
                    data['server_fingerprint'] = value
                    lan.update('office', data)
                    with self.assertRaises(lan.Error):
                        lan.profile('office')

    def test_transaction_snapshot_keeps_pin(self):
        with tempfile.TemporaryDirectory() as tmp, contextlib.ExitStack() as stack:
            state, etc, sb = Path(tmp) / 'state', Path(tmp) / 'etc', Path(tmp) / 'sb.json'
            state.mkdir()
            for attr, value in [('STATE', state), ('ETC', etc), ('SB', sb)]:
                stack.enter_context(patch.object(lan, attr, value))
            stack.enter_context(patch.object(lan, 'network_pending', return_value=[]))
            stack.enter_context(patch.object(lan, 'event'))
            stack.enter_context(patch.object(lan, 'run', return_value=subprocess.CompletedProcess([], 0, '', '')))
            data = lan_profile()
            data['server_fingerprint'] = FINGERPRINT
            lan.update('office', data)
            lan.save(sb, config())
            lan.start_transaction('office', 'enable')
            self.assertEqual(lan.read(state / 'pending/profiles.json')['office']['server_fingerprint'], FINGERPRINT)


class DirectEndpointTests(unittest.TestCase):
    def render(self, directives, direct=True, answers=('93.184.216.34',)):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'synthetic.ovpn'
            source.write_text(directives + '\n<ca>\nTEST_ONLY_CA\n</ca>\n<key>\nTEST_ONLY_SECRET_NEVER_PRINT\n</key>\n')
            records = [(lan.socket.AF_INET, lan.socket.SOCK_DGRAM, 17, '', (ip, 0)) for ip in answers]
            with patch.object(lan.socket, 'getaddrinfo', return_value=records) as resolver, \
                 contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()) as err:
                result = lan.import_client('office', source, direct_endpoint=direct)
            self.assertEqual(out.getvalue() + err.getvalue(), '')
            return result, resolver

    def test_safe_profile_options_and_inherited_port_proto(self):
        (client, nets, gateways), resolver = self.render('remote vpn.example.invalid\nport 1313\nproto udp\nfloat\npasstos')
        self.assertIn('\nremote 93.184.216.34 1313 udp\n', '\n' + client)
        self.assertEqual(gateways, [endpoint()])
        self.assertEqual(nets, [])
        resolver.assert_called_once_with('vpn.example.invalid', None, lan.socket.AF_INET)
        for line in ('port "1313"', 'float', 'passtos', 'verb 3', 'log /var/log/remoteagents/lan-office.openvpn.log'):
            self.assertIn(line + '\n', client)
        self.assertNotIn('verb 0', client)
        self.assertNotIn('mute 1', client)

    def test_multiple_remotes_multiple_addresses_deduplicate_and_pin(self):
        records = lambda *ips: [(lan.socket.AF_INET, 2, 17, '', (ip, 0)) for ip in ips]
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'synthetic.ovpn'
            source.write_text('remote a.example.invalid\nremote b.example.invalid 443 tcp-client\n'
                              'remote 93.184.216.34\nremote-random-hostname\nport 1313\nproto udp4\n<ca>\nX\n</ca>\n')
            with patch.object(lan.socket, 'getaddrinfo', side_effect=[records('93.184.216.34', '1.1.1.1', '1.1.1.1'),
                                                                   records('8.8.8.8', '1.1.1.1')]) as resolver:
                client, _, gateways = lan.import_client('office', source, direct_endpoint=True)
            self.assertEqual(resolver.call_count, 2)
            self.assertEqual(gateways, [endpoint('1.1.1.1'), endpoint(), endpoint('1.1.1.1', 'tcp', 443),
                                        endpoint('8.8.8.8', 'tcp', 443)])
            self.assertEqual(client.count('remote 93.184.216.34 1313 udp\n'), 1)
            self.assertNotIn('example.invalid', client)
            self.assertNotIn('remote-random-hostname', client)
            for item in gateways:
                self.assertIn('remote {ip} {port} {proto}\n'.format(**item), client)

    def test_literal_default_port_and_supported_protocols(self):
        for given, normalized in [('tcp-client', 'tcp'), ('tcp4-client', 'tcp'), ('tcp', 'tcp'),
                                  ('udp4', 'udp'), ('udp', 'udp')]:
            with self.subTest(proto=given):
                (client, _, gateways), resolver = self.render('remote 93.184.216.34\nproto ' + given)
                self.assertEqual(gateways, [endpoint(proto=normalized, port=1194)])
                self.assertIn('remote 93.184.216.34 1194 ' + normalized + '\n', client)
                resolver.assert_not_called()
        (_, _, gateways), _ = self.render('remote vpn.example.invalid 443 tcp-client\nport 1313\nproto udp')
        self.assertEqual(gateways, [endpoint(proto='tcp', port=443)])

    def test_without_flag_keeps_hostname_and_has_no_endpoint_data(self):
        (client, _, gateways), resolver = self.render('remote vpn.example.invalid\nport 1313\nproto udp\nfloat\npasstos', direct=False)
        self.assertIn('remote "vpn.example.invalid"\n', client)
        self.assertEqual(gateways, [])
        resolver.assert_not_called()

    def test_nonpublic_resolver_answers_and_literals_are_rejected(self):
        for ip in ['10.1.2.3', '192.168.1.2', '172.16.1.2', '100.64.1.2', '127.0.0.1', '169.254.1.2',
                   '0.0.0.0', '224.0.0.1', '240.0.0.1', '203.0.113.10', '::1']:
            for literal in (False, True):
                with self.subTest(ip=ip, literal=literal), self.assertRaises(lan.Error) as error:
                    self.render('remote ' + (ip if literal else 'vpn.example.invalid'), answers=('93.184.216.34', ip))
                self.assertNotIn(ip, str(error.exception))

    def test_resolver_failure_never_quotes_exception_or_secrets(self):
        out, err = io.StringIO(), io.StringIO()
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'p.ovpn'
            source.write_text(FIXTURE.read_text())
            with patch.object(lan.socket, 'getaddrinfo', side_effect=lan.socket.gaierror('TEST_ONLY_LAN_PASS')), \
                 contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), self.assertRaises(lan.Error) as error:
                lan.import_client('office', source, auth=('TEST_ONLY_LAN_USER', 'TEST_ONLY_LAN_PASS'), direct_endpoint=True)
        self.assertEqual(str(error.exception), 'Не удалось разрешить адрес шлюза.')
        self.assertEqual(out.getvalue() + err.getvalue(), '')
        with patch.object(lan.socket, 'getaddrinfo', side_effect=UnicodeError('TEST_ONLY_SECRET_NEVER_PRINT')), \
             self.assertRaises(lan.Error) as error:
            lan.remote_endpoints([['vpn.example.invalid']], '1194', 'udp')
        self.assertEqual(str(error.exception), 'Не удалось разрешить адрес шлюза.')

    def test_invalid_remote_port_protocol_and_address_limit(self):
        for directive in ['remote 93.184.216.34 0', 'remote 93.184.216.34 65536',
                          'remote 93.184.216.34 https', 'remote 93.184.216.34 1194 tcp-server',
                          'remote 0177.0.0.1', 'remote 93.184.216.34\nport', 'remote 93.184.216.34\nproto']:
            with self.subTest(directive=directive), self.assertRaises(lan.Error):
                self.render(directive)
        with self.assertRaises(lan.Error):
            self.render('remote vpn.example.invalid', answers=tuple('93.184.216.' + str(n) for n in range(1, 18)))
        (_, _, gateways), _ = self.render('remote vpn.example.invalid', answers=tuple('93.184.216.' + str(n) for n in range(1, 17)))
        self.assertEqual(len(gateways), 16)

    def test_profile_old_and_valid_endpoints_and_invalid_values(self):
        bad = [None, {}, 'bad', [None], [{}], [endpoint(), endpoint()],
               [endpoint(port=True)], [endpoint(port=0)], [endpoint(port=65536)], [endpoint(port='1313')],
               [endpoint(proto='icmp')], [endpoint(proto=[])], [endpoint(ip=123)], [endpoint(ip='093.184.216.34')],
               [endpoint(ip='::1')], [endpoint(ip='10.1.2.3')], [endpoint(ip='100.64.1.2')],
               [endpoint(ip='224.0.0.1')], [dict(endpoint(), extra='TEST_ONLY_SECRET_NEVER_PRINT')],
               [endpoint('93.184.216.' + str(n)) for n in range(1, 18)]]
        with tempfile.TemporaryDirectory() as tmp, patch.object(lan, 'ETC', Path(tmp)):
            for gateways in ('absent', [], [endpoint()], *bad):
                with self.subTest(gateways=gateways):
                    data = lan_profile()
                    if gateways != 'absent':
                        data['endpoints'] = gateways
                    lan.update('office', data)
                    if gateways == 'absent' or gateways == [] or gateways == [endpoint()]:
                        self.assertEqual(lan.profile('office'), data)
                    else:
                        with self.assertRaises(lan.Error):
                            lan.profile('office')
                        with self.assertRaises(lan.Error):
                            lan.nft_rules({'office': data})

    def test_nft_transport_allowlist_precedes_tunnels_in_both_chains(self):
        data = {'office': lan_profile(gateways=[endpoint()]),
                'other': lan_profile('192.168.143.0/24', [endpoint('1.1.1.1', 'tcp', 443)], slot=1)}
        rules = lan.nft_rules(data)
        for chain in ('output', 'egress'):
            body = rules.split(' chain ' + chain + ' ')[1].split('\n }')[0]
            expected = ['ip daddr 1.1.1.1 meta skuid 0 tcp dport 443 accept',
                        'ip daddr 93.184.216.34 meta skuid 0 udp dport 1313 accept',
                        'ip daddr { 1.1.1.1, 93.184.216.34 } drop']
            for line in expected:
                self.assertIn(line, body)
                self.assertLess(body.index(line), body.index('oifname "tun-lan-'))
            self.assertLess(body.index(expected[0]), body.index(expected[2]))
            self.assertLess(body.index(expected[1]), body.index(expected[2]))
            self.assertEqual(body.count('meta skuid 0'), 2)
            accepts = [line.strip() for line in body.splitlines() if 'oifname "tun-lan-' in line and line.endswith('accept')]
            self.assertEqual(accepts, ['oifname "tun-lan-office" ip daddr { 10.123.0.0/16 } accept',
                                       'oifname "tun-lan-other" ip daddr { 192.168.143.0/24 } accept'])
        self.assertEqual(lan.nft_rules({'office': lan_profile()}), lan.nft_rules({'office': lan_profile(gateways=[])}))

    def test_no_endpoints_nft_matches_previous_synthetic_fixture(self):
        self.assertEqual(lan.nft_rules({'office': {'subnets': ['10.123.0.0/16']},
                                         'other': {'subnets': ['192.168.143.0/24']}}),
                         (ROOT / 'tests/fixtures/lan-no-endpoints.nft').read_text())

    def test_sync_owns_only_new_exclusions_and_retires_one_lan(self):
        for foreign_gateway in (False, True):
            with self.subTest(foreign_gateway=foreign_gateway), tempfile.TemporaryDirectory() as tmp:
                state = Path(tmp)
                sb = state / 'config.json'
                original = config()
                foreign = ['203.0.113.7/32'] + (['93.184.216.34/32'] if foreign_gateway else [])
                original['inbounds'][0]['route_exclude_address'] = foreign[:]
                lan.save(sb, original)
                data = {'office': lan_profile(gateways=[endpoint()], enabled=True),
                        'other': lan_profile('192.168.143.0/24', [endpoint('1.1.1.1', 'tcp', 443)], True, 1)}
                with patch.object(lan, 'STATE', state), patch.object(lan, 'SB', sb), \
                     patch.object(lan, 'active', side_effect=lambda: {n: p for n, p in data.items() if p['enabled']}), \
                     patch.object(lan.os, 'chown'), patch.object(lan, 'run', return_value=subprocess.CompletedProcess([], 0, '', '')), \
                     contextlib.redirect_stdout(io.StringIO()):
                    lan.sync_singbox()
                    own = lan.managed_subnets()
                    self.assertNotIn('203.0.113.7/32', own)
                    self.assertEqual('93.184.216.34/32' in own, not foreign_gateway)
                    self.assertEqual(set(lan.read(sb)['inbounds'][0]['route_exclude_address']),
                                     set(foreign + lan.managed_exclusions(data)))
                    data['office']['enabled'] = False
                    lan.sync_singbox()
                    self.assertEqual(set(lan.read(sb)['inbounds'][0]['route_exclude_address']),
                                     set(foreign + ['1.1.1.1/32', '192.168.143.0/24']))
                    data['other']['enabled'] = False
                    lan.sync_singbox()
                    self.assertEqual(lan.read(sb), original)
                    self.assertEqual(lan.managed_subnets(), [])

    def test_enable_applies_endpoint_exclusion_before_client_start(self):
        for direct in (False, True):
            with self.subTest(direct=direct), tempfile.TemporaryDirectory() as tmp:
                state = Path(tmp)
                sb = state / 'sing-box.json'
                lan.save(sb, config())
                data = lan_profile(gateways=[endpoint()] if direct else None)
                data['server_fingerprint'] = FINGERPRINT
                calls = []
                def run(args, **kwargs):
                    calls.append(args)
                    if args == ['systemctl', 'start', lan.service('office')]:
                        exclusions = lan.read(sb)['inbounds'][0].get('route_exclude_address', [])
                        self.assertEqual('93.184.216.34/32' in exclusions, direct)
                        lan.save(state / 'office.discovery.json', {'subnets': data['static']})
                    return subprocess.CompletedProcess(args, 0, '', '')
                with contextlib.ExitStack() as stack:
                    for attr, value in [('STATE', state), ('SB', sb), ('LOG', state / 'lan.log'), ('ETC', state / 'etc')]:
                        stack.enter_context(patch.object(lan, attr, value))
                    for attr in ('preflight', 'local_conflicts', 'start_transaction', 'route_ops', 'apply_dns', 'audit_routes', 'event'):
                        stack.enter_context(patch.object(lan, attr))
                    lan.update('office', data)
                    client, _, _ = lan.import_client('office', FIXTURE, server_fingerprint=FINGERPRINT)
                    lan.atomic(lan.ETC / 'office/client.conf', client)
                    stack.enter_context(patch.object(lan, 'baseline', return_value='hash'))
                    stack.enter_context(patch.object(lan, 'firewall', side_effect=lambda _: calls.append(['firewall'])))
                    stack.enter_context(patch.object(lan, 'guard_batch', return_value='synthetic nft'))
                    stack.enter_context(patch.object(lan.os, 'chown'))
                    stack.enter_context(patch.object(lan, 'run', side_effect=run))
                    stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                    lan.enable('office', 'https://ip.example.invalid')
                    self.assertTrue(lan.profile('office')['ready'])
                    self.assertEqual(lan.profile('office')['server_fingerprint'], FINGERPRINT)
                    self.assertEqual((lan.ETC / 'office/client.conf').read_text(), client)
                    data = lan.profile('office')
                client_start = calls.index(['systemctl', 'start', lan.service('office')])
                fw_start = calls.index(['systemctl', 'start', 'remoteagents-lan-firewall.service'])
                restarts = [i for i, args in enumerate(calls) if args == ['systemctl', 'restart', 'sing-box']]
                self.assertLess(calls.index(['firewall']), fw_start)
                self.assertLess(fw_start, client_start)
                self.assertEqual(any(fw_start < i < client_start for i in restarts), direct)
                self.assertTrue(data['ready'])

    def test_cli_flag_only_add_and_persists_general_endpoints(self):
        with tempfile.TemporaryDirectory() as tmp:
            state, etc = Path(tmp) / 'state', Path(tmp) / 'etc'
            source = Path(tmp) / 'p.ovpn'
            source.write_text('remote 93.184.216.34\nport 1313\n<ca>\nX\n</ca>\n')
            with patch.object(lan, 'STATE', state), patch.object(lan, 'ETC', etc), \
                 patch.object(lan.os, 'geteuid', return_value=0), patch.object(lan.os, 'chown'), patch.object(lan.os, 'fchown'), \
                 patch.object(lan, 'network_pending', return_value=[]), patch.object(lan, 'install_runtime'), patch.object(lan, 'enable') as enable, \
                 patch.object(lan.sys, 'argv', ['lan', 'add', 'office', str(source), '--direct-endpoint', '--ip-check-url', 'https://ip.example.invalid']):
                lan.main()
                self.assertEqual(lan.profile('office')['endpoints'], [endpoint()])
                enable.assert_called_once_with('office', 'https://ip.example.invalid')
            with patch.object(lan.sys, 'argv', ['lan', 'enable', 'office', '--direct-endpoint', '--ip-check-url', 'https://ip.example.invalid']), \
                 contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                lan.main()


class OpenvpnDiagnosticTests(unittest.TestCase):
    def test_certificate_diagnoses_precede_generic_tls_and_hide_log_values(self):
        role_reason = ('у сертификата шлюза нет отметки «сервер»; если это его собственный CA, '
                       'задайте --server-fingerprint (отпечаток сверьте отдельно)')
        # Exact OpenVPN 2.6 ssl_verify.c verify_cert() message (with/without later bracket fix).
        mismatch = ('TLS Error: --tls-verify/--peer-fingerprint certificate hash verification failed. '
                    '(got certificate fingerprint: TEST_ONLY_SECRET')
        for line, expected in [('VERIFY KU ERROR', role_reason),
                               ('Certificate does not have key usage extension', role_reason),
                               (mismatch, 'отпечаток сертификата шлюза не совпал'),
                               (mismatch + ')', 'отпечаток сертификата шлюза не совпал')]:
            with self.subTest(line=line):
                reason = lan.openvpn_reason(line + '\nTLS Error: TLS handshake failed\nTEST_ONLY_SECRET', 'office')
                self.assertEqual(reason, expected)
                self.assertNotIn('TEST_ONLY', reason)

    def test_classification_only_returns_fixed_reasons_without_log_text(self):
        rows = json.loads((ROOT / 'tests/fixtures/openvpn-reasons.json').read_text())
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            for row in rows:
                with self.subTest(marker=row['line'].split()[0]):
                    reason = lan.openvpn_reason(row['line'], 'office')
                    self.assertEqual(reason, row['reason'])
                    self.assertNotIn(row['line'], reason)
                    self.assertNotIn('TEST_ONLY', reason)
            unknown = lan.openvpn_reason('TEST_ONLY_SECRET_NEVER_PRINT', 'office')
            self.assertEqual(unknown, 'причина не распознана; подробности в /var/log/remoteagents/lan-office.openvpn.log (только root)')
            self.assertEqual(lan.openvpn_reason('AUTH_FAILED\nTLS Error', 'office'), rows[0]['reason'])
        self.assertEqual(out.getvalue() + err.getvalue(), '')

    def test_log_read_is_root_only_private_bounded_and_no_symlinks(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as tmp, patch.object(lan, 'LOG', Path(tmp) / 'lan.log'):
            path = lan.openvpn_log('office')
            path.write_text('AUTH_FAILED\n' + 'x' * 70000 + '\nTLS Error TEST_ONLY_SECRET_NEVER_PRINT')
            path.chmod(0o600)
            real_stat = path.stat()
            root_stat = SimpleNamespace(st_mode=real_stat.st_mode, st_uid=0, st_size=real_stat.st_size)
            with patch.object(lan.os, 'geteuid', return_value=1001), patch.object(lan.os, 'open') as opened:
                self.assertIn('причина не распознана', lan.openvpn_failure('office'))
                opened.assert_not_called()
            with patch.object(lan.os, 'geteuid', return_value=0), patch.object(lan.os, 'fstat', return_value=root_stat):
                self.assertIn('шлюз не отвечает', lan.openvpn_failure('office'))
            # A user-owned or world-readable file must never influence diagnosis.
            for uid, mode in [(1001, real_stat.st_mode), (0, real_stat.st_mode | 0o044)]:
                with patch.object(lan.os, 'geteuid', return_value=0), \
                     patch.object(lan.os, 'fstat', return_value=SimpleNamespace(st_mode=mode, st_uid=uid, st_size=real_stat.st_size)):
                    self.assertIn('причина не распознана', lan.openvpn_failure('office'))
            target = path.with_suffix('.target')
            path.rename(target)
            path.symlink_to(target)
            with patch.object(lan.os, 'geteuid', return_value=0):
                self.assertIn('причина не распознана', lan.openvpn_failure('office'))

    def test_enable_timeout_and_failed_client_report_one_reason_and_rollback(self):
        for failure in ('timeout', 'start', 'exited', 'after-discovery'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as tmp, contextlib.ExitStack() as stack:
                state = Path(tmp)
                data = lan_profile(gateways=[endpoint()])
                stack.enter_context(patch.object(lan, 'STATE', state))
                stack.enter_context(patch.object(lan, 'LOG', state / 'lan.log'))
                for attr in ('preflight', 'local_conflicts', 'start_transaction', 'update', 'firewall', 'sync_singbox'):
                    stack.enter_context(patch.object(lan, attr))
                stack.enter_context(patch.object(lan, 'profile', return_value=data))
                stack.enter_context(patch.object(lan, 'active', side_effect=lambda: {'office': data} if data['enabled'] else {}))
                stack.enter_context(patch.object(lan, 'baseline', return_value='hash'))
                rollback = stack.enter_context(patch.object(lan, 'rollback'))
                reason = lan.openvpn_reason('AUTH_FAILED TEST_ONLY_LAN_PASS', 'office')
                diagnose = stack.enter_context(patch.object(lan, 'openvpn_failure', return_value=reason))
                stack.enter_context(patch.object(lan.time, 'monotonic', side_effect=[0, 21] if failure == 'timeout' else [0, 0]))
                def run(args, **kwargs):
                    if failure == 'after-discovery' and args == ['systemctl', 'start', lan.service('office')]:
                        lan.save(state / 'office.discovery.json', {'subnets': data['static']})
                    rc = int((failure == 'start' and args == ['systemctl', 'start', lan.service('office')]) or
                             (failure in ('exited', 'after-discovery') and args[:2] == ['systemctl', 'is-active']))
                    return subprocess.CompletedProcess(args, rc, 'TEST_ONLY_LAN_USER', 'TEST_ONLY_LAN_PASS')
                stack.enter_context(patch.object(lan, 'run', side_effect=run))
                out, err = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), self.assertRaises(lan.Error) as error:
                    lan.enable('office', 'https://ip.example.invalid')
                self.assertEqual(str(error.exception), reason)
                self.assertEqual(out.getvalue() + err.getvalue(), '')
                diagnose.assert_called_once_with('office')
                rollback.assert_called_once_with()


class EndpointLifecycleTests(unittest.TestCase):
    def test_disable_and_remove_one_lan_keep_other_gateway_and_foreign_exclusion(self):
        for remove in (False, True):
            with self.subTest(remove=remove), tempfile.TemporaryDirectory() as tmp, contextlib.ExitStack() as stack:
                state, etc = Path(tmp) / 'state', Path(tmp) / 'etc'
                state.mkdir()
                sb = Path(tmp) / 'sb.json'
                data = {'office': lan_profile(gateways=[endpoint()], enabled=True),
                        'other': lan_profile('192.168.143.0/24', [endpoint('1.1.1.1', 'tcp', 443)], True, 1)}
                for attr, value in [('STATE', state), ('ETC', etc), ('SB', sb)]:
                    stack.enter_context(patch.object(lan, attr, value))
                for name, p in data.items():
                    p['server_fingerprint'] = FINGERPRINT
                    lan.update(name, p)
                    client, _, _ = lan.import_client(name, FIXTURE, server_fingerprint=FINGERPRINT)
                    lan.atomic(etc / name / 'client.conf', client)
                own = lan.managed_exclusions(data)
                cfg = config()
                cfg['inbounds'][0]['route_exclude_address'] = ['203.0.113.7/32'] + own
                lan.save(sb, cfg)
                lan.save(state / 'managed-subnets.json', own)
                def begin(*args):
                    (state / 'pending').mkdir()
                for attr in ('stop_client', 'route_ops', 'firewall', 'cancel_timer', 'event'):
                    stack.enter_context(patch.object(lan, attr))
                stack.enter_context(patch.object(lan, 'start_transaction', side_effect=begin))
                stack.enter_context(patch.object(lan, 'guard_batch', return_value='synthetic nft'))
                stack.enter_context(patch.object(lan.os, 'chown'))
                stack.enter_context(patch.object(lan, 'run', return_value=subprocess.CompletedProcess([], 0, '', '')))
                stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                lan.disable('office', remove=remove)
                self.assertEqual(set(lan.read(sb)['inbounds'][0]['route_exclude_address']),
                                 {'203.0.113.7/32', '1.1.1.1/32', '192.168.143.0/24'})
                self.assertEqual(lan.managed_subnets(), ['1.1.1.1/32', '192.168.143.0/24'])
                self.assertEqual((etc / 'office').exists(), not remove)
                self.assertTrue(lan.profile('other')['enabled'])
                self.assertEqual(lan.profile('other')['server_fingerprint'], FINGERPRINT)
                if not remove:
                    self.assertEqual(lan.profile('office')['server_fingerprint'], FINGERPRINT)
                    self.assertIn('peer-fingerprint ' + FINGERPRINT, (etc / 'office/client.conf').read_text())

    def test_rollback_and_boot_recovery_remove_owned_endpoint_exclusions(self):
        for boot in (False, True):
            with self.subTest(boot=boot), tempfile.TemporaryDirectory() as tmp, contextlib.ExitStack() as stack:
                state, etc = Path(tmp) / 'state', Path(tmp) / 'etc'
                pending = state / 'pending'
                pending.mkdir(parents=True)
                sb = Path(tmp) / 'sb.json'
                for attr, value in [('STATE', state), ('ETC', etc), ('SB', sb)]:
                    stack.enter_context(patch.object(lan, attr, value))
                previous = {'office': lan_profile(gateways=[endpoint()], enabled=True)}
                current = dict(previous, other=lan_profile('192.168.143.0/24', [endpoint('1.1.1.1', 'tcp', 443)], True, 1))
                for name, p in current.items():
                    p['server_fingerprint'] = FINGERPRINT
                    lan.update(name, p)
                    client, _, _ = lan.import_client(name, FIXTURE, server_fingerprint=FINGERPRINT)
                    lan.atomic(etc / name / 'client.conf', client)
                before = config()
                before['inbounds'][0]['route_exclude_address'] = ['203.0.113.7/32'] + lan.managed_exclusions(previous)
                lan.save(pending / 'sing-box.json', before)
                lan.save(sb, lan.patch_singbox(before, [], lan.managed_exclusions(current)))
                lan.save(pending / 'profiles.json', previous)
                lan.save(pending / 'managed.json', lan.managed_exclusions(previous))
                lan.save(pending / 'meta.json', {'name': 'other', 'uid': os.getuid(), 'gid': os.getgid(), 'mode': 0o600})
                lan.save(pending / 'nft.json', {'present': False, 'text': ''})
                for attr in ('stop_clients', 'route_ops', 'event', 'cancel_timer'):
                    stack.enter_context(patch.object(lan, attr))
                run = stack.enter_context(patch.object(lan, 'run', return_value=subprocess.CompletedProcess([], 1, '', '')))
                stack.enter_context(patch.object(lan.os, 'chown'))
                stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                if boot:
                    stack.enter_context(patch.object(lan.sys, 'argv', ['lan', '_recover']))
                    stack.enter_context(patch.object(lan.os, 'geteuid', return_value=0))
                    stack.enter_context(patch.object(lan.os, 'fchown'))
                    lan.main()
                else:
                    lan.rollback()
                self.assertEqual(lan.read(sb)['inbounds'][0]['route_exclude_address'], ['203.0.113.7/32'])
                self.assertEqual(lan.managed_subnets(), [])
                self.assertFalse(any(p['enabled'] for p in lan.profiles().values()))
                for name, p in lan.profiles().items():
                    self.assertEqual(p['server_fingerprint'], FINGERPRINT)
                    self.assertIn('peer-fingerprint ' + FINGERPRINT, (etc / name / 'client.conf').read_text())
                restarts = [c.args[0] for c in run.call_args_list if c.args[0][:2] == ['systemctl', 'restart']]
                self.assertEqual(bool(restarts), not boot)
                self.assertFalse(pending.exists())


if __name__ == '__main__':
    unittest.main()


class ReconnectAndReplaceTests(unittest.TestCase):
    def test_reconnect_keeps_historical_confirmation_and_new_pending_does_not(self):
        for pending in (False, True):
            with self.subTest(pending=pending), tempfile.TemporaryDirectory() as tmp:
                state = Path(tmp)
                data = {'enabled': True, 'ready': True, 'static': ['10.123.0.0/16'],
                        'subnets': ['10.123.0.0/16'], 'confirmed_at': '2026-11-15T00:00:00+00:00'}
                if pending:
                    (state / 'pending').mkdir()
                with patch.object(lan, 'STATE', state), patch.object(lan, 'profile', return_value=data), \
                     patch.object(lan, 'prestart'), patch.object(lan, 'route_ops'), patch.object(lan, 'apply_dns'), \
                     patch.object(lan, 'pushed_routes', return_value=[]), patch.object(lan, 'event') as event, \
                     patch.dict(os.environ, {'dev': 'tun-lan-office'}):
                    lan.hook('office')
                message = event.call_args.args[1]
                if pending:
                    self.assertIn('ожидается test', message)
                else:
                    self.assertNotIn('ожидается test', message)
                    self.assertIn('подтверждён ранее', message)
                    self.assertTrue(event.call_args.args[2])

    def test_transaction_snapshots_private_profile_and_rollback_restores_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            state, etc = root / 'state', root / 'etc'
            state.mkdir(); (etc / 'office').mkdir(parents=True)
            client = etc / 'office/client.conf'
            client.write_text('OLD_PRIVATE_CLIENT_SENTINEL')
            sb = root / 'sing-box.json'; sb.write_text(json.dumps(config()))
            old = {'enabled': True, 'ready': True, 'subnets': ['10.123.0.0/16']}
            def run(args, **kw):
                return subprocess.CompletedProcess(args, 1 if args[0] == 'nft' and 'list' in args else 0, '', '')
            with patch.object(lan, 'STATE', state), patch.object(lan, 'ETC', etc), patch.object(lan, 'SB', sb), \
                 patch.object(lan, 'network_pending', return_value=[]), patch.object(lan, 'profiles', return_value={'office': old}), \
                 patch.object(lan, 'managed_subnets', return_value=[]), patch.object(lan, 'event'), \
                 patch.object(lan, 'run', side_effect=run), patch.object(lan, 'stop_clients'), \
                 patch.object(lan, 'route_ops'), patch.object(lan, 'update'), patch.object(lan.os, 'chown'), \
                 contextlib.redirect_stdout(io.StringIO()):
                lan.start_transaction('office', 'replace')
                backup = state / 'pending/clients/office'
                self.assertEqual(backup.read_text(), 'OLD_PRIVATE_CLIENT_SENTINEL')
                self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
                client.write_text('NEW_PRIVATE_CLIENT_SENTINEL')
                lan.rollback()
                self.assertEqual(client.read_text(), 'OLD_PRIVATE_CLIENT_SENTINEL')

    def test_replace_arms_rollback_before_stopping_old_client(self):
        with tempfile.TemporaryDirectory() as tmp:
            etc = Path(tmp); (etc / 'office').mkdir()
            (etc / 'office/client.conf').write_text('old profile')
            old = {'enabled': True, 'ready': True, 'static': ['10.123.0.0/16'], 'table': 42000, 'priority': 1000}
            calls = []
            with patch.object(lan, 'ETC', etc), patch.object(lan, 'profiles', return_value={'office': old}), \
                 patch.object(lan, 'preflight'), patch.object(lan, 'local_conflicts'), patch.object(lan, 'baseline'), \
                 patch.object(lan, 'run', return_value=subprocess.CompletedProcess([], 0, '', '')), \
                 patch.object(lan, 'start_transaction', side_effect=lambda *a: calls.append('timer')), \
                 patch.object(lan, 'stop_client', side_effect=lambda *a: calls.append('stop')), \
                 patch.object(lan, 'route_ops'), patch.object(lan, 'update'), patch.object(lan, 'enable') as enable:
                lan.add_profile('office', 'new profile', old['static'], [], None, FINGERPRINT, False,
                                'https://ip.example.invalid/', replace=True)
            self.assertEqual(calls, ['timer', 'stop'])
            self.assertTrue(enable.call_args.kwargs['transaction_started'])
