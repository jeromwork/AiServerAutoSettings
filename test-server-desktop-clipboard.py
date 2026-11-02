#!/usr/bin/env python3
"""Offline Ubuntu checks. Never launches services or reads a live clipboard.

Usage: python3 -I test-server-desktop-clipboard.py [server-desktop-bootstrap.sh]
Only public bootstrap source is inspected; embedded Python is compiled, not run.
"""
import ast
import configparser
import io
from pathlib import Path
import re
import shlex
import sys
import unittest
import os
import socket
import stat
import subprocess
import tempfile

SOURCE = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).with_name('server-desktop-bootstrap.sh')
TEXT = SOURCE.read_text(encoding='utf-8')


def heredoc(name):
    match = re.search(r'<<\s*[\'\"]?' + re.escape(name) + r'[\'\"]?\s*\n(.*?)\n' + re.escape(name) + r'\s*(?:\n|$)', TEXT, re.S)
    if not match:
        raise AssertionError('Missing public bootstrap fixture: ' + name)
    return match.group(1)


def ini(text):
    result = configparser.ConfigParser(interpolation=None, strict=False)
    result.read_file(io.StringIO(text))
    return result


def unit_values(text):
    """Retain repeated systemd directives; ConfigParser would discard them."""
    result = {}
    section = None
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith(('#', ';')):
            continue
        if line.startswith('['):
            section = line.strip('[]')
        elif '=' in line:
            key, value = line.split('=', 1)
            result.setdefault((section, key), []).append(value.strip())
    return result


class ClipboardContract(unittest.TestCase):
    @unittest.skipUnless(os.name=='posix','Real owner-local Unix socket metadata')
    def test_reconnect_restores_recreated_socket_permissions_without_restart(self):
        helper=heredoc('DESKTOP_CLIPBOARD_SOCKET').replace("Path('/run/remoteagents-desktop-clipboard')",'Path(sys.argv[1])')
        with tempfile.TemporaryDirectory(prefix='clipboard-permissions-') as temporary:
            folder=Path(temporary);folder.chmod(0o700)
            sockets=[]
            try:
                for name in ('xrdp_chansrv_socket_98','xrdpapi_98'):
                    endpoint=socket.socket(socket.AF_UNIX);endpoint.bind(str(folder/name));sockets.append(endpoint)
                    (folder/name).chmod(0o660)
                for _ in range(2):
                    (folder/'xrdp_chansrv_socket_98').chmod(0o660)
                    subprocess.run([sys.executable,'-I','-',str(folder)],input=helper,text=True,check=True,capture_output=True,timeout=10)
                    self.assertTrue(all(stat.S_IMODE((folder/name).lstat().st_mode)==0o600 for name in ('xrdp_chansrv_socket_98','xrdpapi_98')))
                self.assertEqual(stat.S_IMODE(folder.stat().st_mode),0o700)
            finally:
                for endpoint in sockets:endpoint.close()
        enable=TEXT.index('systemctl enable --now remoteagents-desktop-clipboard.service')
        repair=TEXT.index('runuser -u "$server_user" -- python3 -I "$install_dir/clipboard-socket.py"',enable)
        check=TEXT.index("<<'DESKTOP_CLIPBOARD_READY'",enable)
        self.assertLess(repair,check)

    def test_configuration_keeps_text_and_disables_file_transfer(self):
        cfg = ini(heredoc('DESKTOP_CLIPBOARD_CONFIG'))
        self.assertEqual(cfg['Globals']['ListenAddress'], '127.0.0.1', 'This exact value selects AF_UNIX in chansrv 0.9.24')
        for direction in ('Inbound', 'Outbound'):
            denied = {x.strip().lower() for x in cfg['Security']['Restrict' + direction + 'Clipboard'].split(',')}
            self.assertEqual(denied, {'file', 'image'})
        self.assertFalse(cfg.getboolean('Chansrv', 'EnableFuseMount'))
        self.assertEqual(cfg['ChansrvLogging']['LogLevel'].upper(), 'WARNING')
        self.assertFalse(cfg.getboolean('ChansrvLogging', 'EnableSyslog'))

    def test_sidecar_namespace_and_identity(self):
        body = heredoc('DESKTOP_CLIPBOARD_UNIT')
        values = unit_values(body)
        def one(key):
            found = values.get(('Service', key), [])
            self.assertEqual(len(found), 1, key)
            return found[0]
        self.assertEqual(one('User'), '$server_user')
        self.assertRegex(TEXT, r'\$server_user\s*!=\s*root', 'Bootstrap must reject root user')
        self.assertIn(one('PrivateNetwork').lower(), ('yes', 'true'))
        self.assertEqual(shlex.split(one('RestrictAddressFamilies')), ['AF_UNIX'])
        self.assertIn('/run/remoteagents-desktop-clipboard:/run/xrdp/sockdir', values.get(('Service', 'BindPaths'), []))
        self.assertIn('$install_dir/chansrv.ini:/etc/xrdp/sesman.ini', values.get(('Service', 'BindReadOnlyPaths'), []))
        self.assertEqual(one('RuntimeDirectory'), 'remoteagents-desktop-clipboard')
        self.assertEqual(int(one('RuntimeDirectoryMode'), 8), 0o700)
        environment = {}
        for value in values.get(('Service', 'Environment'), []):
            for entry in shlex.split(value):
                key, val = entry.split('=', 1)
                environment[key] = val
        self.assertEqual(environment.get('DISPLAY'), ':98')
        self.assertEqual(environment.get('XAUTHORITY'), '/run/remoteagents-desktop-x/Xauthority')
        self.assertEqual(environment.get('CHANSRV_LOG_PATH'), '/run/remoteagents-desktop-clipboard')
        start = shlex.split(one('ExecStart'))
        self.assertEqual(start, ['/usr/sbin/xrdp-chansrv'], '0.9.24 has no --config flag')
        self.assertNotIn(('Service', 'PAMName'), values)
        self.assertNotRegex(body, r'(?im)^\s*(?:Exec\w*|Requires|Wants|After)\s*=.*(?:xrdp-sesman|/sesman(?:\s|$))')

    def test_socket_helper_compiles_and_checks_metadata(self):
        source = heredoc('DESKTOP_CLIPBOARD_SOCKET')
        tree = ast.parse(source, filename='clipboard-socket-mode.py')
        compile(tree, 'clipboard-socket-mode.py', 'exec')
        calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call)]
        attrs = {node.func.attr for node in calls if isinstance(node.func, ast.Attribute)}
        self.assertIn('lstat', attrs, 'Inspect socket itself, not symlink target')
        self.assertIn('S_ISLNK', attrs, 'Reject symlinks explicitly')
        self.assertIn('S_ISSOCK', attrs, 'Reject non-socket objects')
        chmod = [node for node in calls if isinstance(node.func, ast.Attribute) and node.func.attr == 'chmod']
        self.assertTrue(any(any(isinstance(arg, ast.Constant) and arg.value == 0o600 for arg in node.args) for node in chmod), 'Set socket owner-only, overriding chansrv 0660')
        self.assertIn('xrdp_chansrv_socket_98', source)
        self.assertNotIn('subprocess', source, 'Socket helper must not launch unrelated commands')

    def test_desktop_connection_only_if_transform_fixture_exists(self):
        # An optional Python transform is tested dynamically with artificial INI
        # input only; no bootstrap command or service is ever executed.
        if not re.search(r'<<\s*[\'\"]?DESKTOP_CLIPBOARD_INI[\'\"]?\s*\n', TEXT):
            self.skipTest('No DESKTOP_CLIPBOARD_INI transform fixture supplied; connection scope requires review')
        source = heredoc('DESKTOP_CLIPBOARD_INI')
        tree = ast.parse(source)
        functions = [n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name == 'add_desktop_chansrvport']
        self.assertEqual(len(functions), 1, 'Expose pure add_desktop_chansrvport(text) for scope verification')
        # Restrict this optional fixture to a pure text transform: no execution
        # of top-level code/imports, and no access to file/process APIs.
        function = functions[0]
        self.assertIsInstance(function, ast.FunctionDef)
        self.assertFalse(any(isinstance(n, (ast.Import, ast.ImportFrom)) for n in ast.walk(function)))
        safe_names = {'re', 'str', 'ValueError'}
        self.assertFalse(any(isinstance(n, ast.Name) and isinstance(n.ctx, ast.Load) and n.id in {'open', 'eval', 'exec', '__import__', 'os', 'sys', 'subprocess', 'Path'} for n in ast.walk(function)))
        for node in ast.walk(function):
            if isinstance(node, ast.Attribute):
                self.assertFalse(node.attr.startswith('_'))
        namespace = {'__builtins__': {'str': str, 'ValueError': ValueError}, 're': re}
        exec(compile(ast.Module(body=[function], type_ignores=[]), '<public pure transform>', 'exec'), namespace)
        before = '[Other]\nlib=libvnc.so\nip=127.0.0.1\nport=5902\n[Desktop]\nlib=libvnc.so\nip=127.0.0.1\nport=5901\n'
        after = namespace['add_desktop_chansrvport'](before)
        cfg = ini(after)
        self.assertEqual(dict(cfg['Other']), dict(ini(before)['Other']))
        self.assertEqual(cfg['Desktop']['chansrvport'], '/run/remoteagents-desktop-clipboard/xrdp_chansrv_socket_98')
        for key in ('lib', 'ip', 'port'):
            self.assertEqual(cfg['Desktop'][key], ini(before)['Desktop'][key])
        self.assertEqual(namespace['add_desktop_chansrvport'](after), after, 'Transform must be idempotent')


if __name__ == '__main__':
    unittest.main(verbosity=2)
