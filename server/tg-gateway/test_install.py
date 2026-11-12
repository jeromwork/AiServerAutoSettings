#!/usr/bin/python3
"""Installer tests: disposable HOME, fake systemd/loginctl/ip, loopback 18xxx only."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import ssl
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

BASE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('setup', BASE / 'tg_gateway_setup.py')
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)

SYSTEMCTL = r'''#!/usr/bin/python3
import json,os,shlex,signal,socket,subprocess,sys,time
from pathlib import Path
h=Path.home();base=h/'.local/opt/tg-gateway';pidfile=h/'fake.pid'
args=sys.argv[1:]
with (h/'systemctl.calls').open('a') as log:log.write(' '.join(args)+'\n')
if args[0]!='--user':sys.exit(90)
command=args[1]
if command=='show':
 prop=next((a.split('=',1)[1] for a in args if a.startswith('--property=')),'')
 if prop=='Environment':
  unit=h/'.config/systemd/user/tg-gateway.service'
  if unit.exists():
   for line in unit.read_text().splitlines():
    if line.startswith('Environment='):print(line.split('=',1)[1])
 elif prop=='MainPID':print(pidfile.read_text() if pidfile.exists() else '0')
 elif prop=='ActiveState':print('active' if pidfile.exists() else 'inactive')
 elif prop=='UnitFileState':print('enabled')
 sys.exit(0)
if command=='restart':
 if pidfile.exists():
  try:os.kill(int(pidfile.read_text()),signal.SIGTERM)
  except ProcessLookupError:pass
  oldport=int((h/'fake.port').read_text())
  for _ in range(100):
   with socket.socket() as sock:
    if sock.connect_ex(('127.0.0.1',oldport))!=0:break
   time.sleep(.02)
 env=dict(os.environ)
 for line in (h/'.config/systemd/user/tg-gateway.service').read_text().splitlines():
  if line.startswith('Environment='):
   key,value=shlex.split(line.split('=',1)[1])[0].replace('%%','%').split('=',1);env[key]=value
 # All tests bind loopback, never the production default of 0.0.0.0.
 runner="import runpy,sys;m=runpy.run_path(sys.argv[1]);m['main']('127.0.0.1')"
 with (h/'fake.gateway.log').open('ab') as log:
  process=subprocess.Popen(['/usr/bin/python3','-I','-u','-c',runner,str(base/'gateway.py')],env=env,stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True)
 pidfile.write_text(str(process.pid));(h/'fake.port').write_text(env['TG_GW_PORT'])
'''


def free_test_port():
    for port in range(18000, 19000):
        with socket.socket() as sock:
            try:
                sock.bind(('127.0.0.1', port))
                return port
            except OSError:
                pass
    raise RuntimeError('No free loopback 18xxx port')


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, {}, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)

    def test_main_default_with_and_without_policy_tun(self):
        ethernet = {'ifname': 'eth0', 'link_type': 'ether', 'addr_info': [
            {'family': 'inet', 'scope': 'global', 'local': '10.1.2.3'},
            {'family': 'inet', 'scope': 'global', 'local': '8.8.4.4'}]}
        for tun in (False, True):
            with self.subTest(tun=tun):
                routes = [{'dst': 'default', 'dev': 'eth0', 'metric': 100}]
                addresses = [ethernet]
                if tun:
                    routes.insert(0, {'dst': 'default', 'dev': 'tun0', 'table': 2022})
                    addresses.insert(0, {'ifname': 'tun0', 'link_type': 'none', 'addr_info': [
                        {'family': 'inet', 'scope': 'global', 'local': '172.29.0.1'}]})
                with patch.object(setup, 'run', side_effect=[json.dumps(routes), json.dumps(addresses)]) as run:
                    self.assertEqual(setup.public_host(), '8.8.4.4')
                    self.assertEqual(run.call_args_list[0].args, ('ip', '-j', 'route', 'show', 'table', 'main', 'default'))
                    self.assertEqual(run.call_args_list[1].args, ('ip', '-j', '-4', 'addr'))

    def test_excludes_private_service_and_virtual_interfaces(self):
        for device, ip in [('eth0', '192.168.1.1'), ('eth0', '10.0.0.1'), ('eth0', '172.29.0.2'),
                           ('eth0', '100.64.0.2'), ('eth0', '169.254.1.1'), ('eth0', '127.0.0.1'),
                           ('eth0', '192.0.2.1'), ('eth0', '224.0.0.1'), ('eth0', '255.255.255.255'),
                           ('docker0', '8.8.4.4'), ('tun0', '8.8.4.4'), ('lo', '8.8.4.4')]:
            with self.subTest(device=device, ip=ip):
                values = [[{'dev': device}], [{'ifname': device, 'addr_info': [
                    {'family': 'inet', 'scope': 'global', 'local': ip}]}]]
                with patch.object(setup, 'run', side_effect=list(map(json.dumps, values))):
                    with self.assertRaisesRegex(ValueError, 'TG_GW_PUBLIC_HOST'):
                        setup.public_host()

    def test_no_main_public_address_does_not_use_other_interfaces(self):
        values = [[{'dev': 'eth0'}], [{'ifname': 'eth1', 'addr_info': [
            {'family': 'inet', 'scope': 'global', 'local': '8.8.4.4'}]}]]
        with patch.object(setup, 'run', side_effect=list(map(json.dumps, values))):
            with self.assertRaisesRegex(ValueError, 'TG_GW_PUBLIC_HOST'):
                setup.public_host()
        with patch.object(setup, 'run', side_effect=FileNotFoundError):
            with self.assertRaisesRegex(ValueError, 'TG_GW_PUBLIC_HOST'):
                setup.public_host()

    def test_explicit_host_wins_even_without_ip(self):
        for host in ('gateway.example', '8.8.4.4', '2001:4860:4860::8888'):
            with patch.dict(os.environ, TG_GW_PUBLIC_HOST=host), patch.object(setup, 'run') as run:
                self.assertEqual(setup.public_host(), host)
                run.assert_not_called()
        for host in ('https://example.com', 'example.com:8444', 'x\nIP:evil', 'x/OU=bad'):
            with self.assertRaises(ValueError):
                setup.validate_host(host)

    def test_real_port_probe_respects_bound_and_listening_sockets(self):
        port = free_test_port()
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', port))
            self.assertFalse(setup.port_free(port))
            sock.listen()
            self.assertFalse(setup.port_free(port))
        self.assertTrue(setup.port_free(port))

    def test_port_priority_busy_range_and_our_listener(self):
        with patch.object(setup, 'port_free', side_effect=lambda port: port >= 8446):
            self.assertEqual(setup.choose_port({}), 8446)
        with patch.object(setup, 'port_free', return_value=True):
            self.assertEqual(setup.choose_port({'port': 18445}, 18446), 18445)
            self.assertEqual(setup.choose_port({}, 18446), 18446)
            with patch.dict(os.environ, TG_GW_PORT='18444'):
                self.assertEqual(setup.choose_port({'port': 18445}), 18444)
        with patch.object(setup, 'port_free', return_value=False), patch.object(setup, 'our_listener', return_value=True):
            self.assertEqual(setup.choose_port({'port': 18444}), 18444)
            self.assertEqual(setup.choose_port({}, 8444), 8444) # Original unit port, no real 8444 listener.
        with patch.object(setup, 'port_free', return_value=False), patch.object(setup, 'our_listener', return_value=False):
            with self.assertRaisesRegex(ValueError, 'другим процессом'):
                setup.choose_port({'port': 18444})
            with self.assertRaisesRegex(ValueError, '8444..8499'):
                setup.choose_port({})
        for value in ('0', '65536', '-1', 'garbage', True):
            with self.assertRaises(ValueError):
                setup.valid_port(value)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='.test-install-', dir=BASE)
        self.home = Path(self.temp.name)
        self.base = self.home / '.local/opt/tg-gateway'
        self.bin = self.home / '.local/bin'
        self.bin.mkdir(parents=True)
        for name, source in {'systemctl': SYSTEMCTL, 'loginctl': '#!/bin/sh\nexit 1\n',
                             'ip': '#!/bin/sh\nif [ "$*" = "-j route show table main default" ]; then echo \'[{"dev":"eth0"}]\'; elif [ "$*" = "-j -4 addr" ]; then echo \'[{"ifname":"eth0","addr_info":[{"family":"inet","scope":"global","local":"8.8.4.4"}]}]\'; else exit 99; fi\n'}.items():
            (self.bin / name).write_text(source)
            (self.bin / name).chmod(0o700)
        self.port = free_test_port()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('TG_GW_')}
        self.env.update(HOME=str(self.home), PATH=str(self.bin) + ':' + os.environ['PATH'], TG_GW_PORT=str(self.port))
        self.addCleanup(self.cleanup)

    def cleanup(self):
        pid = self.home / 'fake.pid'
        if pid.exists():
            try:
                os.kill(int(pid.read_text()), signal.SIGTERM)
            except ProcessLookupError:
                pass
            time.sleep(.3)
        self.temp.cleanup()

    def install(self, *, env=None, check=True, installed=False):
        result = subprocess.run(['bash', str((self.base if installed else BASE) / 'install.sh')],
                                env=env or self.env, capture_output=True, text=True, timeout=25)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def keys(self, *args, check=True):
        result = subprocess.run([str(self.bin / 'tg-gateway-keys'), *args], env=self.env,
                                capture_output=True, text=True, timeout=5)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_repeat_preserves_keys_certificate_port_and_installs_outside_source(self):
        result = self.install()
        self.assertIn('linger', result.stderr)
        self.assertIn(f'https://8.8.4.4:{self.port}', result.stdout)
        self.assertTrue((self.base / 'gateway.py').is_file())
        unit = (self.home / '.config/systemd/user/tg-gateway.service').read_text()
        self.assertIn(str(self.base / 'gateway.py'), unit)
        self.assertNotIn(str(BASE / 'gateway.py'), unit)
        data = json.loads(self.keys('add', 'client', '--json').stdout)
        self.assertEqual(data['base_url'].rsplit('/', 1)[0], f'https://8.8.4.4:{self.port}')
        before = {name: (self.base / name).read_bytes() for name in ('tls/cert.pem', 'tls/key.pem', 'state/keys.json')}
        env = dict(self.env);del env['TG_GW_PORT']
        (self.bin / 'loginctl').write_text('#!/bin/sh\nexit 0\n')
        self.assertNotIn('linger', self.install(env=env, installed=True).stderr)
        self.assertEqual(json.loads((self.base / 'state/settings.json').read_text())['port'], self.port)
        for name, content in before.items():
            self.assertEqual((self.base / name).read_bytes(), content)
        self.assertFalse(list((self.base / 'tls').glob('old-*')))
        check = subprocess.run(['bash', str(self.base / 'install.sh'), '--check'], env=env, capture_output=True, timeout=5)
        self.assertEqual(check.returncode, 0)
        self.assertEqual(check.stdout, b'')
        self.assertEqual((self.base / 'state').stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.base / 'state/settings.json').stat().st_mode & 0o777, 0o600)
        self.assertIn('--user enable tg-gateway.service', (self.home / 'systemctl.calls').read_text())

    def test_host_change_archives_pair_and_requires_new_certificate(self):
        self.install()
        self.keys('add', 'client')
        old = {name: (self.base / 'tls' / name).read_bytes() for name in ('cert.pem', 'key.pem')}
        keys = (self.base / 'state/keys.json').read_bytes()
        env = dict(self.env, TG_GW_PUBLIC_HOST='new.example')
        result = self.install(env=env)
        self.assertIn('клиентам нужен новый сертификат', result.stderr)
        archives = list((self.base / 'tls').glob('old-*'))
        self.assertEqual(len(archives), 1)
        for name, content in old.items():
            self.assertEqual((archives[0] / name).read_bytes(), content)
            self.assertNotEqual((self.base / 'tls' / name).read_bytes(), content)
        self.assertEqual(keys, (self.base / 'state/keys.json').read_bytes())
        cert = ssl._ssl._test_decode_cert(str(self.base / 'tls/cert.pem'))
        self.assertIn(('DNS', 'new.example'), cert['subjectAltName'])
        self.assertIn(('IP Address', '127.0.0.1'), cert['subjectAltName'])
        self.install(env=env)
        self.assertEqual(len(list((self.base / 'tls').glob('old-*'))), 1)

    def test_legacy_unit_without_settings_keeps_port_and_keys(self):
        self.install()
        self.keys('add', 'existing')
        (self.base / 'state/settings.json').unlink()
        before = [(self.base / name).read_bytes() for name in ('state/keys.json', 'tls/cert.pem')]
        env = dict(self.env);del env['TG_GW_PORT']
        self.install(env=env)
        self.assertEqual(json.loads((self.base / 'state/settings.json').read_text())['port'], self.port)
        self.assertEqual(before, [(self.base / name).read_bytes() for name in ('state/keys.json', 'tls/cert.pem')])

    def test_busy_explicit_port_fails_without_changing_files(self):
        self.install()
        port = free_test_port()
        before = (self.base / 'state/settings.json').read_bytes()
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', port));sock.listen()
            result = self.install(env=dict(self.env, TG_GW_PORT=str(port)), check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('занят другим процессом', result.stderr)
        self.assertEqual((self.base / 'state/settings.json').read_bytes(), before)
        self.assertEqual((self.home / 'systemctl.calls').read_text().count('--user restart'), 1)

    def test_settings_required_before_issuing_secret(self):
        self.install()
        path = self.base / 'state/settings.json'
        path.unlink()
        result = self.keys('add', 'bad', '--json', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertFalse((self.base / 'state/keys.json').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
