#!/usr/bin/env python3
"""Rootless proxy-out tests: fake systemd/curl, real `sing-box check`, no network changes."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('proxy_out', ROOT / 'proxy_out.py')
proxy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proxy)
lan = proxy.lan
SECRET_USER, SECRET_PASS = 'TEST_ONLY_USER', 'TEST_ONLY_PASS"\\word'


def config(with_proxy=True):
    outbounds = [{'type': 'direct', 'tag': 'direct-out'}]
    if with_proxy:
        outbounds.insert(0, {'type': 'socks', 'tag': 'proxy-out', 'server': 'old.example.invalid', 'server_port': 1080,
                             'version': '5', 'username': 'OLD_USER_SECRET', 'password': 'OLD_PASS_SECRET'})
    return {'log': {'disabled': True},
            'inbounds': [{'type': 'tun', 'tag': 'tun-in', 'address': ['172.30.0.1/30'], 'auto_route': True},
                         {'type': 'mixed', 'tag': 'mixed-in', 'listen': '127.0.0.1', 'listen_port': 1080},
                         {'type': 'vless', 'tag': 'vless-in', 'listen': '::', 'listen_port': 8443,
                          'users': [{'uuid': '00000000-0000-4000-8000-000000000000'}]}],
            'outbounds': outbounds,
            'route': {'rules': [{'port': [22], 'inbound': ['tun-in'], 'outbound': 'direct-out'},
                                {'ip_is_private': True, 'outbound': 'direct-out'}],
                      'final': 'proxy-out' if with_proxy else 'direct-out', 'auto_detect_interface': True}}


class Server:
    """A fake server: sing-box restart 'activates' the current config for curl answers."""
    def __init__(self, tmp, initial):
        self.tmp = Path(tmp)
        self.sb = self.tmp / 'etc/sing-box/config.json'
        self.sb.parent.mkdir(parents=True)
        self.sb.write_text(json.dumps(initial))
        os.chmod(self.sb, 0o640)
        self.active = initial
        self.calls, self.inputs = [], []
        self.ips = {'socks5h://old.example.invalid:1080': '9.9.9.9', 'socks5h://new.example.invalid:1081': '8.8.8.8',
                    'http://new.example.invalid:3128': '8.8.4.4'}
        self.system_override = None
        self.check_fails = False

    def exit_ip(self):
        out = next((o for o in self.active['outbounds'] if o.get('tag') == 'proxy-out'), None)
        if not out or self.active['route'].get('final') != 'proxy-out':
            return '1.1.1.1'
        return self.ips[proxy.proxy_url(out['type'], out['server'], out['server_port'])]

    def run(self, args, check=True, input=None, timeout=20):
        args = [str(a) for a in args]
        self.calls.append(args)
        self.inputs.append(input)
        out, code = '', 0
        if args[0] == 'curl':
            conf = dict(line.split(' = ', 1) for line in input.splitlines())
            url = json.loads(conf['proxy'])
            if url == '':
                out = self.system_override or self.exit_ip()
            elif url.startswith('socks5h://127.0.0.1'):
                out = self.exit_ip()
            else:
                out = self.ips.get(url, '')
                code = 0 if out else 7
        elif args[:2] == ['sing-box', 'check']:
            binary = shutil.which('sing-box')
            code = subprocess.run([binary, 'check', '-c', args[3]], capture_output=True, timeout=20).returncode if binary else 0
            code = code or int(self.check_fails)
        elif args[:2] == ['systemctl', 'restart']:
            self.active = json.loads(self.sb.read_text())
        if check and code:
            raise lan.Error('Проверка/команда завершилась ошибкой: ' + args[0] + ' (вывод скрыт).')
        return subprocess.CompletedProcess(args, code, out, '')

    @contextlib.contextmanager
    def patched(self):
        state = self.tmp / 'var/lib/remoteagents'
        with patch.object(lan, 'SB', self.sb), patch.object(lan, 'STATE', state / 'lan'), \
             patch.object(lan, 'LOG', self.tmp / 'log/lan.log'), patch.object(lan, 'PUBLIC', self.tmp / 'public'), \
             patch.object(lan, 'PENDING', (state / 'lan/pending', state / 'port-leak/pending', state / 'proxy-out/pending')), \
             patch.object(proxy, 'STATE', state / 'proxy-out'), patch.object(proxy, 'ETC', self.tmp / 'etc/remoteagents/proxy'), \
             patch.object(proxy, 'BIN', self.tmp / 'bin'), patch.object(proxy, 'install'), \
             patch.object(lan, 'run', side_effect=self.run), patch.object(lan.os, 'chown'):
            (state / 'proxy-out').mkdir(parents=True)
            yield state


def args(kind='socks', host='new.example.invalid', port=1081, stdin=True):
    return type('Args', (), {'type': kind, 'server': host, 'port': port, 'ip_check_url': 'https://ip.example.invalid/',
                             'credentials_stdin': stdin, 'ask_credentials': False})()


def secret_stdin():
    # The sudo password line comes first when sudo is NOPASSWD; it must be ignored.
    return io.StringIO('SUDO_LINE_NEVER_USED\r\n' + proxy.MARKER + '\r\n' +
                       json.dumps({'username': SECRET_USER, 'password': SECRET_PASS}) + '\r\n')


class PatchTests(unittest.TestCase):
    def test_only_proxy_out_changes(self):
        before = config()
        after, created = proxy.patch(before, ('http', 'new.example.invalid', 3128, SECRET_USER, SECRET_PASS))
        self.assertFalse(created)
        self.assertEqual(after['inbounds'], before['inbounds'])
        self.assertEqual(after['route'], before['route'])
        self.assertEqual(after['outbounds'][1:], before['outbounds'][1:])
        self.assertEqual(after['outbounds'][0], {'type': 'http', 'tag': 'proxy-out', 'server': 'new.example.invalid',
                                                 'server_port': 3128, 'username': SECRET_USER, 'password': SECRET_PASS})

    def test_created_proxy_becomes_final_with_same_exclusions(self):
        before = config(with_proxy=False)
        before['route']['rules'] = [{'port': [22], 'inbound': ['tun-in'], 'outbound': 'direct-out'}]
        del before['route']['auto_detect_interface']
        after, created = proxy.patch(before, ('socks', 'new.example.invalid', 1081, '', ''))
        self.assertTrue(created)
        self.assertEqual(after['route']['final'], 'proxy-out')
        self.assertEqual(after['route']['rules'][0], before['route']['rules'][0])
        self.assertIn({'ip_is_private': True, 'outbound': 'direct-out'}, after['route']['rules'])
        self.assertTrue(after['route']['auto_detect_interface'])
        self.assertNotIn('username', after['outbounds'][0])

    def test_without_tun_refuses_honestly(self):
        cfg = config()
        cfg['inbounds'] = cfg['inbounds'][1:]
        with self.assertRaises(lan.Error):
            proxy.patch(cfg, ('socks', 'new.example.invalid', 1081, '', ''))

    def test_validation(self):
        for bad in [('ftp', 'a.invalid', 1), ('socks', 'a b', 1), ('socks', '-x.invalid', 1), ('socks', 'a.invalid', 0),
                    ('socks', 'a.invalid', 70000), ('socks', 'a;id', 1)]:
            with self.subTest(bad=bad), self.assertRaises(lan.Error):
                proxy.endpoint(*bad)
        for bad in [('a:b', 'x'), ('u', 'x\ny'), ('', 'only-password')]:
            with self.subTest(bad=bad[0]), self.assertRaises(lan.Error):
                proxy.credentials(*bad)
        self.assertEqual(proxy.endpoint('socks', '2001:db8::1', 1080)[1], '2001:db8::1')
        self.assertEqual(proxy.proxy_url('socks', '2001:db8::1', 1080), 'socks5h://[2001:db8::1]:1080')

    def test_diff_hides_credentials(self):
        before = config()
        after, _ = proxy.patch(before, ('http', 'new.example.invalid', 3128, SECRET_USER, SECRET_PASS))
        diff = proxy.semantic_diff(before, after)
        for secret in (SECRET_USER, SECRET_PASS, 'OLD_USER_SECRET', 'OLD_PASS_SECRET', '00000000-0000'):
            self.assertNotIn(secret, diff)
        self.assertIn('~ password: <скрыто> (изменён)', diff)
        self.assertIn('- type: "socks"', diff)
        self.assertIn('+ type: "http"', diff)
        self.assertNotIn('vless', diff)

    def test_real_singbox_accepts_both_types(self):
        binary = shutil.which('sing-box')
        self.assertIsNotNone(binary, 'Требуется sing-box в PATH')
        for kind in ('socks', 'http'):
            after, _ = proxy.patch(config(with_proxy=False), (kind, 'new.example.invalid', 1081, SECRET_USER, SECRET_PASS))
            with tempfile.TemporaryDirectory() as tmp, self.subTest(kind=kind):
                path = Path(tmp) / 'c.json'
                path.write_text(json.dumps(after))
                result = subprocess.run([binary, 'check', '-c', str(path)], capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0, 'sing-box check failed')


class ApplyTests(unittest.TestCase):
    def apply(self, fake, **kw):
        out = io.StringIO()
        with patch.object(sys, 'stdin', secret_stdin()), contextlib.redirect_stdout(out):
            proxy.apply(args(**kw))
        return out.getvalue()

    def assert_no_secret_leak(self, server, text, state):
        for call in server.calls:
            self.assertFalse(any(SECRET_PASS in a or SECRET_USER in a for a in call), 'secret in argv')
        self.assertNotIn(SECRET_PASS, text)
        log = (server.tmp / 'log/lan.log')
        if log.exists():
            self.assertNotIn(SECRET_PASS, log.read_text())
        for public in (server.tmp / 'public').glob('*.json'):
            self.assertNotIn(SECRET_PASS, public.read_text())
            self.assertEqual(public.stat().st_mode & 0o777, 0o644)
        self.assertFalse((state / 'proxy-out/candidate.json').exists(), 'candidate with secrets removed')

    def test_apply_arms_timer_first_checks_ip_then_confirm(self):
        with tempfile.TemporaryDirectory() as tmp:
            server = Server(tmp, config())
            with server.patched() as state:
                text = self.apply(server)
                kinds = [c[0] + ' ' + c[1] for c in server.calls]
                self.assertLess(kinds.index('systemd-run --quiet'), kinds.index('systemctl restart'))
                self.assertLess(kinds.index('sing-box check'), kinds.index('systemd-run --quiet'))
                # The new proxy is tested directly BEFORE the timer and any change.
                first_curl = server.inputs[kinds.index('curl --disable')]
                self.assertIn('new.example.invalid:1081', first_curl)
                self.assertIn(json.dumps(SECRET_USER + ':' + SECRET_PASS)[1:-1], first_curl)
                self.assertLess(kinds.index('curl --disable'), kinds.index('systemd-run --quiet'))
                self.assertIn('@@ outbounds[proxy-out] @@', text)
                self.assertEqual(json.loads(server.sb.read_text())['outbounds'][0]['server'], 'new.example.invalid')
                self.assertEqual(server.sb.stat().st_mode & 0o777, 0o640)
                self.assertTrue((state / 'proxy-out/pending').exists())
                self.assertEqual(json.loads((server.tmp / 'public/proxy.json').read_text())['state'], 'pending')
                with self.assertRaises(lan.Error):
                    proxy.confirm(False)
                with contextlib.redirect_stdout(io.StringIO()):
                    proxy.confirm(True)
                saved = server.tmp / 'etc/remoteagents/proxy/proxy.json'
                self.assertEqual(saved.stat().st_mode & 0o777, 0o600)
                self.assertEqual(json.loads(saved.read_text())['password'], SECRET_PASS)
                self.assertFalse((state / 'proxy-out/pending').exists())
                self.assertTrue(json.loads((server.tmp / 'public/proxy.json').read_text())['ok'])
                self.assert_no_secret_leak(server, text, state)

    def test_wrong_exit_ip_rolls_back_byte_exact(self):
        with tempfile.TemporaryDirectory() as tmp:
            server = Server(tmp, config())
            original = server.sb.read_bytes()
            server.system_override = '1.0.0.1'
            with server.patched() as state:
                with self.assertRaises(lan.Error):
                    self.apply(server)
                self.assertEqual(server.sb.read_bytes(), original)
                self.assertEqual(server.sb.stat().st_mode & 0o777, 0o640)
                self.assertFalse((state / 'proxy-out/pending').exists())
                self.assertEqual(server.active, json.loads(original))
                self.assertIn(['systemctl', 'stop', 'remoteagents-proxy-out-rollback.timer'], server.calls)
                self.assert_no_secret_leak(server, '', state)

    def test_unreachable_proxy_changes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            server = Server(tmp, config())
            original = server.sb.read_bytes()
            with server.patched() as state:
                with self.assertRaises(lan.Error):
                    self.apply(server, host='down.example.invalid')
                self.assertEqual(server.sb.read_bytes(), original)
                self.assertFalse(any(c[0] in ('systemd-run', 'systemctl') for c in server.calls))
                self.assertFalse((state / 'proxy-out/pending').exists())

    def test_invalid_candidate_rejected_by_singbox_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            server = Server(tmp, config())
            server.check_fails = True
            original = server.sb.read_bytes()
            with server.patched():
                with self.assertRaises(lan.Error):
                    self.apply(server)
                self.assertEqual(server.sb.read_bytes(), original)
                self.assertFalse(any(c[0] == 'systemd-run' for c in server.calls))

    def test_other_pending_network_change_blocks(self):
        with tempfile.TemporaryDirectory() as tmp:
            server = Server(tmp, config())
            with server.patched() as state:
                (state / 'lan/pending').mkdir(parents=True)
                with self.assertRaises(lan.Error):
                    self.apply(server)
                self.assertEqual(server.calls, [])

    def test_boot_recover_restores_without_restart(self):
        with tempfile.TemporaryDirectory() as tmp:
            server = Server(tmp, config())
            original = server.sb.read_bytes()
            with server.patched() as state:
                self.apply(server)
                server.calls.clear()
                with contextlib.redirect_stdout(io.StringIO()) as out:
                    proxy.rollback(boot=True)
                self.assertEqual(server.sb.read_bytes(), original)
                self.assertFalse(any(c[:2] == ['systemctl', 'restart'] for c in server.calls))
                self.assertNotIn(SECRET_PASS, out.getvalue())
                self.assertNotIn('OLD_PASS_SECRET', out.getvalue())


class ScriptTests(unittest.TestCase):
    def test_non_root_refuses_and_never_echoes_stdin(self):
        if os.geteuid() == 0:
            self.skipTest('тест для обычного пользователя')
        result = subprocess.run(['bash', str(ROOT / 'proxy-out.sh'), 'apply', '--type', 'socks', '--server', 'a.invalid',
                                 '--port', '1080', '--ip-check-url', 'https://ip.invalid/', '--credentials-stdin'],
                                input=proxy.MARKER + '\n{"username":"u","password":"' + SECRET_PASS.replace('\\', '') + '"}\n',
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 1)
        self.assertIn('root', result.stderr)
        self.assertNotIn('TEST_ONLY_PASS', result.stderr + result.stdout)

    def test_status_without_root(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(lan, 'PUBLIC', Path(tmp)), \
             contextlib.redirect_stdout(io.StringIO()) as out:
            proxy.status()
        self.assertEqual(json.loads(out.getvalue())['state'], 'unknown')


if __name__ == '__main__':
    unittest.main()
