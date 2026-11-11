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
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('lan_vpn', ROOT / 'lan_vpn.py')
lan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lan)
FIXTURE = ROOT / 'tests/fixtures/unsafe.ovpn'


def config():
    return {'log': {'disabled': True}, 'inbounds': [
        {'type': 'tun', 'tag': 'tun-in', 'address': ['172.30.0.1/30'], 'auto_route': True},
        {'type': 'mixed', 'tag': 'mixed-in', 'listen': '127.0.0.1', 'listen_port': 1080}],
        'outbounds': [{'type': 'socks', 'tag': 'proxy-out', 'server': 'proxy.example.invalid', 'server_port': 1080},
                      {'type': 'direct', 'tag': 'direct-out'}],
        'route': {'rules': [{'ip_is_private': True, 'outbound': 'direct-out'}], 'final': 'proxy-out'}}


class ImportTests(unittest.TestCase):
    def render(self, text=None, extra=()):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'in.ovpn'
            source.write_bytes((FIXTURE.read_text() if text is None else text).replace('\n', '\r\n').encode())
            out = io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
                client, nets = lan.import_client('office', source, extra)
            self.assertEqual(out.getvalue(), '')
            return client, nets

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

    def test_push_ignores_split_default_and_rejects_public(self):
        env = {'route_network_1': '0.0.0.0', 'route_netmask_1': '128.0.0.0',
               'route_network_2': '128.0.0.0', 'route_netmask_2': '128.0.0.0',
               'route_network_3': '10.124.0.0', 'route_netmask_3': '255.255.0.0',
               'route_ipv6_network_1': '::/0'}
        self.assertEqual(lan.pushed_routes(env), ['10.124.0.0/16'])
        env.update(route_network_4='203.0.113.0', route_netmask_4='255.255.255.0')
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
        cfg = lan.patch_singbox(config(), [], ['10.123.0.0/16', '192.168.143.0/24'])
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
                 patch.object(lan, 'profiles', return_value={}), patch.object(lan, 'run', side_effect=fail):
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
             patch.object(lan, 'event'), patch.object(lan, 'revert_dns'), patch.object(lan, 'firewall', side_effect=fw):
            lan.watch()
        stopped = [c for c in calls if c[:2] == ['systemctl', 'stop']]
        self.assertEqual(len(stopped), 2)
        self.assertEqual(calls[0], ['firewall', {}])
        self.assertEqual(calls[-1], ['firewall', {}])
        self.assertTrue(all(not p['enabled'] for p in data.values()))


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
            client, _ = lan.import_client('office', source, auth=('TEST_ONLY_LAN_USER', 'TEST_ONLY_LAN_PASS'))
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


if __name__ == '__main__':
    unittest.main()
