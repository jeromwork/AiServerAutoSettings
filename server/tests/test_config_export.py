#!/usr/bin/env python3
"""remoteagents config: выдача/список/отзыв/автообновление/enc1/имена компьютеров.

Всё во временных каталогах: свой authorized_keys, свой реестр, свой sshd на loopback.
Настоящие ~/.ssh, authorized_keys рабочего пользователя, службы и мост не трогаются.
"""
import base64
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import pwd
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
MODULE = ROOT / 'server/remoteagents_config.py'
spec = importlib.util.spec_from_file_location('remoteagents_config', MODULE)
rc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rc)
sys.path.insert(0, str(ROOT))
import server_node_catalog as nodes  # noqa: E402

USER = pwd.getpwuid(os.getuid()).pw_name
MASTER = 'Мастер-пароль 1'
# Тот же вектор — в docs/CONFIG-SERVER.md (раздел «Тестовый вектор enc1») для потока A.
VECTOR = dict(password=MASTER, salt='AAECAwQFBgcICQoLDA0ODw==', iterations=200000, iv=bytes(range(16, 32)),
              aes='4a705d00d0b0eb61e464aac6aa0712bcb93c88417d7db998d56d72cfbb87cb6e',
              mac='23756d57411519ab4fd2f3cb1f4ce7d7594d96e01dbc6bafa100fc102eaf6b1b',
              check='enc1:EBESExQVFhcYGRobHB0eH5S/AYvjmvqbyp4eatsIP0ESDucdw0ufuFBNWskJNZdj/a/PyROkWqohaJO+d8dnCA==',
              secret_plain='секрет\nвторая строка',
              secret='enc1:EBESExQVFhcYGRobHB0eH9EATN4mI2yZF1iffFippgsKu5D1MyvAG2NfKVaGcnHzvCO5vWsIX2yfsu90ejzi8negWZF8qpwxkbFOMwPwBMnei8w8zX8GwmtQ4CNs3ZfL')


def run(args, **kw):
    if 'input' not in kw:
        kw.setdefault('stdin', subprocess.DEVNULL)
    return subprocess.run([str(x) for x in args], capture_output=True, timeout=kw.pop('timeout', 60), **kw)


def keygen(path):
    assert run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', path]).returncode == 0
    return ' '.join(Path(str(path) + '.pub').read_text().split()[:2])


class Env:
    """Изолированный сервер: настройки выдачи, authorized_keys, каталог связи, секреты VPN."""

    def __init__(self, directory, **extra):
        self.dir = Path(directory)
        self.home = self.dir / 'worker'
        (self.home / '.ssh').mkdir(parents=True, mode=0o700)
        self.home.chmod(0o755)  # umask стенда может дать g+w — такой HOME sshd (StrictModes) и выдача отвергают
        self.auth = self.home / '.ssh/authorized_keys'
        self.host_key = self.dir / 'host'
        self.host_pub = keygen(self.host_key)
        self.secrets = self.dir / 'secrets'
        self.secrets.mkdir(mode=0o700)
        self.catalog = self.dir / 'catalog.json'
        self.catalog.write_text(json.dumps(dict(schema=1, entries=[dict(name='Entry1', ssh='entry1')],
                                                hops=[dict(name='vhop', ssh='vhop', hostKey=[self.host_pub])],
                                                relays=[dict(name='fixture', host='127.0.0.1', port=1)], cdn=[])))
        self.channel = self.private('channel.json', json.dumps({'outbounds': [{'tag': 'sync', 'uuid': 'CHANNEL-SECRET-UUID'}]}))
        self.entry = self.private('entry1.json', json.dumps({'password': 'ENTRY-SECRET'}))
        self.vhop_key = self.dir / 'secrets/vhop'
        keygen(self.vhop_key)
        self.route_key = self.dir / 'secrets/route'
        keygen(self.route_key)
        self.route_password = self.private('route-password', 'HOP-PASSWORD\n')
        self.log = self.dir / 'auth.log'
        self.cfg = self.dir / 'config-export.json'
        self.c = dict(schema=1, version=1, serverAddress='127.0.0.1', serverPort=22, workerUser=USER,
                      hostKeys=[self.host_pub], workerAuthorizedKeys=str(self.auth), stateDir=str(self.dir / 'state'),
                      syncFile=str(self.home / '.config/remoteagents/config-sync.json'),
                      nodeCatalog=str(self.home / '.local/share/remote-agents-nodes'), catalogFile=str(self.catalog),
                      authLog=[str(self.log)], routes=[{'kind': 'direct'}])
        self.c.update(extra)
        self.write()

    def private(self, name, text):
        path = self.secrets / name
        path.write_text(text)
        path.chmod(0o600)
        return path

    def vpn(self):
        self.c['vpnBootstrap'] = dict(channelFile=str(self.channel), entryFiles={'Entry1': str(self.entry)},
                                      hops={'vhop': dict(host='127.0.0.1', port=2222, user='hopuser', keyFile=str(self.vhop_key))},
                                      vpn=dict(checkUrl='https://check.example.invalid/', dnsServer='192.0.2.53'))
        self.write()

    def write(self):
        self.cfg.write_text(json.dumps(self.c, ensure_ascii=False))
        self.cfg.chmod(0o600)

    def cli(self, *args, **kw):
        return run([sys.executable, '-I', MODULE, '--config', self.cfg, *args], **kw)

    def export(self, name='Ноутбук сына', *extra, password=None):
        args = ['export', '--name', name, *extra]
        if password is not None:
            args.append('--master-password-stdin')
        p = self.cli(*args, input=None if password is None else (password + '\r\n').encode())
        assert p.returncode == 0, p.stderr.decode()
        return json.loads(p.stdout), p


class ConfigExportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ra-config-b-')
        self.addCleanup(self.tmp.cleanup)
        self.e = Env(self.tmp.name)
        # Защита от ошибки в тесте: ни один путь не должен вести в настоящий HOME.
        c = rc.settings(self.e.cfg)
        for field in ('workerAuthorizedKeys', 'syncFile', 'nodeCatalog', 'stateDir', 'catalogFile'):
            self.assertTrue(c[field].startswith(self.tmp.name), field)

    def lines(self):
        return self.e.auth.read_text().splitlines()

    def test_export_labelled_key_permissions_and_format(self):
        self.e.auth.write_text('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExisting existing@host')  # без перевода строки
        self.e.auth.chmod(0o644)
        config, p = self.e.export()
        self.assertEqual(config['kind'], 'remoteagents-config')
        self.assertEqual(config['schema'], 1)
        self.assertEqual(config['device'], {'name': 'Ноутбук сына'})
        server = config['server']
        self.assertEqual((server['address'], server['port'], server['login']), ('127.0.0.1', 22, USER))
        self.assertEqual(server['hostKeys'], [self.e.host_pub])
        self.assertEqual(server['key'], {'secret': 'server-key'})
        self.assertEqual(server['routes'], [{'kind': 'direct'}])
        self.assertEqual(config['happier'], {'mode': 'same'})
        self.assertEqual(config['bridge'], {'enabled': True, 'allowShell': False})
        self.assertNotIn('protected', config['secrets'])
        private = config['secrets']['server-key']
        self.assertTrue(private.startswith('-----BEGIN OPENSSH PRIVATE KEY-----'))
        lines = self.lines()
        self.assertEqual(lines[0], 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExisting existing@host')
        self.assertEqual(len(lines), 2)
        key_file = self.e.dir / 'from-config'
        key_file.write_text(private)
        key_file.chmod(0o600)
        public = ' '.join(run(['ssh-keygen', '-y', '-f', key_file]).stdout.decode().split()[:2])
        ident = lines[1].split()[2][len('ra-config:'):]
        self.assertRegex(ident, r'^[a-f0-9]{16}$')
        self.assertEqual(lines[1], public + ' ra-config:' + ident + ' Ноутбук сына')
        self.assertEqual(self.e.auth.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.e.home / '.ssh').stat().st_mode & 0o777, 0o700)
        self.assertEqual(list((self.e.home / '.ssh').iterdir()), [self.e.auth])  # временных файлов не осталось
        self.assertIn(ident, p.stderr.decode())
        print('PASS export: ed25519 из конфига = строка ra-config:<id> <название>; 0600; прежняя строка сохранена')

    def test_new_authorized_keys_and_ssh_directory_created(self):
        self.e.auth.unlink(missing_ok=True)
        (self.e.home / '.ssh').rmdir()
        self.e.export('Компьютер')
        self.assertEqual((self.e.home / '.ssh').stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.e.auth.stat().st_mode & 0o777, 0o600)
        self.assertEqual(len(self.lines()), 1)

    def test_repeat_export_new_id_and_key(self):
        first, _ = self.e.export('Ноутбук')
        second, _ = self.e.export('Ноутбук')
        lines = self.lines()
        self.assertEqual(len(lines), 2)
        ids = {line.split()[2] for line in lines}
        self.assertEqual(len(ids), 2)
        self.assertNotEqual(first['secrets']['server-key'], second['secrets']['server-key'])
        self.assertNotEqual(lines[0].split()[1], lines[1].split()[1])

    def test_concurrent_exports_lose_no_line(self):
        with concurrent.futures.ThreadPoolExecutor(4) as pool:
            results = list(pool.map(lambda n: self.e.cli('export', '--name', 'Параллельно ' + str(n)), range(4)))
        self.assertTrue(all(r.returncode == 0 for r in results), [r.stderr for r in results])
        self.assertEqual(len(self.lines()), 4)
        self.assertEqual(len({line.split()[2] for line in self.lines()}), 4)

    def test_revoke_removes_only_own_line(self):
        self.e.export('Первый')
        self.e.export('Второй')
        first, second = self.lines()
        ident = first.split()[2][len('ra-config:'):]
        key = ' '.join(first.split()[:2])
        # Тот же ключ записан ещё под другой меткой (вручную), плюс посторонние строки.
        self.e.auth.write_text('# comment\n' + first + '\n' + key + ' ra-device:Старое имя\n' + second + '\n'
                               + 'restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOther other@host\n')
        p = self.e.cli('revoke', ident)
        self.assertEqual(p.returncode, 0, p.stderr.decode())
        self.assertEqual(self.lines(), ['# comment', key + ' ra-device:Старое имя', second,
                                        'restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOther other@host'])
        self.assertIn('не обрываются', p.stdout.decode())
        self.assertIn('ra-device:Старое имя', p.stderr.decode())  # честное предупреждение: доступ по второй строке остаётся
        self.assertEqual(self.e.auth.stat().st_mode & 0o777, 0o600)
        again = self.e.cli('revoke', ident)
        self.assertEqual(again.returncode, 0)
        self.assertIn('уже нет', again.stdout.decode())
        self.assertNotEqual(self.e.cli('revoke', '0' * 16).returncode, 0)
        self.assertNotEqual(self.e.cli('revoke', 'не-id').returncode, 0)
        self.assertEqual(len(self.lines()), 4)
        print('PASS revoke: только своя строка; та же пара под другой меткой — предупреждение; посторонние строки как были')

    def test_list_names_created_last_login_and_unknown(self):
        config, _ = self.e.export('Ноутбук')
        self.e.export('Сын')
        rows = [json.loads(x) for x in self.e.cli('list', '--json').stdout.decode().splitlines()]
        self.assertEqual([r['name'] for r in rows], ['Ноутбук', 'Сын'])
        self.assertTrue(all(r['createdUtc'] and r['state'] == 'действует' for r in rows))
        self.assertEqual([r['lastLogin'] for r in rows], [None, None])  # журнала нет — неизвестно, а не «не входил»
        self.assertIn('неизвестно', self.e.cli('list').stdout.decode())
        fp = rows[0]['fingerprint']
        self.e.log.write_text(
            '2026-11-12T09:00:00+03:00 host sshd[1]: Accepted publickey for %s from 192.0.2.1 port 5 ssh2: ED25519 %s\n'
            '2026-11-12T10:00:00+03:00 host sshd[2]: Accepted publickey for other from 192.0.2.1 port 5 ssh2: ED25519 %s\n'
            'Nov 12 11:00:00 host sshd[3]: Accepted publickey for %s from 192.0.2.1 port 6 ssh2: ED25519 %s\n' % (USER, fp, fp, USER, fp))
        rows = [json.loads(x) for x in self.e.cli('list', '--json').stdout.decode().splitlines()]
        self.assertEqual(rows[0]['lastLogin'], 'Nov 12 11:00:00')
        self.assertEqual(rows[1]['lastLogin'], '')
        self.assertIn('нет в журнале', self.e.cli('list').stdout.decode())
        self.assertEqual(self.e.cli('revoke', rows[0]['id']).returncode, 0)
        rows = [json.loads(x) for x in self.e.cli('list', '--json').stdout.decode().splitlines()]
        self.assertEqual(rows[0]['state'], 'отозван')
        listing = self.e.cli('list').stdout.decode()
        self.assertNotIn('PRIVATE', listing)
        self.assertNotIn(config['secrets']['server-key'].splitlines()[1], listing)
        print('PASS list: id, название, создан, состояние; последний вход из журнала или честно «неизвестно»')

    def test_master_password_enc1_roundtrip_and_tamper(self):
        self.e.vpn()
        config, p = self.e.export('Защищённый', password=MASTER)
        section = config['secrets']
        self.assertEqual(section['protected'], 'master-password')
        self.assertEqual(section['kdf']['name'], 'pbkdf2-sha256')
        self.assertEqual(section['kdf']['iterations'], 200000)
        self.assertEqual(len(base64.b64decode(section['kdf']['salt'])), 16)
        names = [k for k in section if k not in ('protected', 'kdf', 'check')]
        self.assertTrue(all(section[k].startswith('enc1:') for k in names + ['check']))
        self.assertEqual(set(names), {'server-key', 'vpn-channel', 'vpn-entry-entry1', 'vpn-hop-vhop'})
        plain = rc.unprotect(section, MASTER)  # пароль пришёл с CRLF — \r не стал частью пароля
        self.assertTrue(plain['server-key'].startswith('-----BEGIN OPENSSH PRIVATE KEY-----'))
        self.assertIn('CHANNEL-SECRET-UUID', plain['vpn-channel'])
        with self.assertRaises(rc.Error):
            rc.unprotect(section, MASTER + 'x')
        raw = bytearray(base64.b64decode(section['server-key'][5:]))
        raw[20] ^= 1
        with self.assertRaises(rc.Error):
            rc.unprotect(dict(section, **{'server-key': 'enc1:' + base64.b64encode(bytes(raw)).decode()}), MASTER)
        text = json.dumps(config, ensure_ascii=False)
        for value in plain.values():
            self.assertNotIn(value.splitlines()[0] if '\n' in value else value, text)
        print('PASS enc1: все секреты зашифрованы; CRLF-пароль; неверный пароль и подмена → отказ')

    def test_generated_master_password(self):
        import argparse, re as _re
        args = argparse.Namespace(generate_master_password=True, master_password_stdin=False)
        first, second = rc.master_password(args), rc.master_password(args)
        self.assertRegex(first, r'^([a-z]+-){4}[1-9][0-9]$')
        self.assertNotEqual(first, second)
        with self.assertRaises(rc.Error):
            rc.master_password(argparse.Namespace(generate_master_password=True, master_password_stdin=True))
        print('PASS generated master password: readable, random, exclusive with stdin')

    def test_enc1_vector_matches_docs_and_openssl(self):
        salt = base64.b64decode(VECTOR['salt'])
        keys = rc.derive(VECTOR['password'], salt, VECTOR['iterations'])
        self.assertEqual((keys[0].hex(), keys[1].hex()), (VECTOR['aes'], VECTOR['mac']))
        self.assertEqual(rc.enc1('remoteagents', keys, VECTOR['iv']), VECTOR['check'])
        self.assertEqual(rc.enc1(VECTOR['secret_plain'], keys, VECTOR['iv']), VECTOR['secret'])
        section = {'protected': 'master-password', 'kdf': {'name': 'pbkdf2-sha256', 'iterations': VECTOR['iterations'], 'salt': VECTOR['salt']},
                   'check': VECTOR['check'], 'demo': VECTOR['secret']}
        self.assertEqual(rc.unprotect(section, VECTOR['password']), {'demo': VECTOR['secret_plain']})
        # Независимая реализация: OpenSSL расшифровывает тот же шифртекст теми же ключами.
        raw = base64.b64decode(VECTOR['secret'][5:])
        p = run(['openssl', 'enc', '-d', '-aes-256-cbc', '-K', VECTOR['aes'], '-iv', raw[:16].hex()], input=raw[16:-32])
        self.assertEqual(p.stdout.decode(), VECTOR['secret_plain'], p.stderr)
        p = run(['openssl', 'kdf', '-keylen', '64', '-kdfopt', 'digest:SHA256', '-kdfopt', 'pass:' + VECTOR['password'],
                 '-kdfopt', 'hexsalt:' + salt.hex(), '-kdfopt', 'iter:200000', 'PBKDF2'])
        if p.returncode == 0:
            self.assertEqual(p.stdout.decode().strip().replace(':', '').lower(), VECTOR['aes'] + VECTOR['mac'])
        doc = (ROOT / 'docs/CONFIG-SERVER.md').read_text()
        for value in (VECTOR['check'], VECTOR['secret'], VECTOR['aes'], VECTOR['mac'], VECTOR['salt']):
            self.assertIn(value, doc)
        print('PASS enc1 vector: Python = OpenSSL; тот же вектор в docs/CONFIG-SERVER.md')

    def test_export_prints_no_secrets_to_stderr_or_logs(self):
        self.e.vpn()
        config, p = self.e.export('Без утечек', password=MASTER)
        plain = rc.unprotect(config['secrets'], MASTER)
        open_config, q = self.e.export('Открытый')
        leaks = [MASTER, 'CHANNEL-SECRET-UUID', 'ENTRY-SECRET', 'PRIVATE KEY'] + [
            line for value in list(plain.values()) + [open_config['secrets']['server-key']] for line in value.splitlines() if len(line) > 20]
        state = Path(self.e.c['stateDir'])
        texts = {'stderr': p.stderr.decode() + q.stderr.decode(), 'events': (state / 'config-events.log').read_text(),
                 'records': ''.join(f.read_text() for f in state.glob('*.json')),
                 'list': self.e.cli('list').stdout.decode() + self.e.cli('list', '--json').stdout.decode()}
        for where, text in texts.items():
            for secret in leaks:
                self.assertNotIn(secret, text, where)
        self.assertNotIn('Без утечек', texts['events'])
        print('PASS: ни stderr, ни журнал, ни записи, ни list не содержат секретов (%d проверенных строк)' % len(leaks))

    def test_routes_and_vpn_bootstrap_sections(self):
        self.e.vpn()
        self.e.c['routes'] = [{'kind': 'direct'}, {'kind': 'proxy', 'proxy': {'type': 'socks', 'server': '127.0.0.1', 'port': 10808}},
                              {'kind': 'hop', 'hop': {'name': 'relay', 'host': 'relay.example.invalid', 'port': 2200, 'user': 'relayuser',
                                                      'hostKey': self.e.host_pub, 'keyFile': str(self.e.route_key), 'passwordFile': str(self.e.route_password)}}]
        self.e.write()
        config, _ = self.e.export('Маршруты', '--folders', 'Проект,Проект/docs', '--happier', 'new:Сын')
        self.assertEqual(config['server']['routes'][1], {'kind': 'proxy', 'proxy': {'type': 'socks', 'server': '127.0.0.1', 'port': 10808}})
        self.assertEqual(config['server']['routes'][2], {'kind': 'hop', 'hop': {'host': 'relay.example.invalid', 'port': 2200, 'user': 'relayuser',
                         'hostKey': self.e.host_pub, 'key': {'secret': 'hop-relay-key'}, 'password': {'secret': 'hop-relay-password'}}})
        self.assertEqual(config['secrets']['hop-relay-password'], 'HOP-PASSWORD')
        vpn = config['vpn']
        self.assertEqual((vpn['enabled'], vpn['checkUrl'], vpn['dnsServer']), (True, 'https://check.example.invalid/', '192.0.2.53'))
        self.assertEqual(vpn['bootstrap']['channel'], {'secret': 'vpn-channel'})
        self.assertEqual(vpn['bootstrap']['entries'], {'Entry1': {'secret': 'vpn-entry-entry1'}})
        self.assertEqual(vpn['bootstrap']['hops'], {'vhop': {'host': '127.0.0.1', 'port': 2222, 'user': 'hopuser', 'key': {'secret': 'vpn-hop-vhop'}}})
        self.assertEqual(vpn['bootstrap']['catalog']['relays'][0]['name'], 'fixture')
        self.assertEqual(json.loads(config['secrets']['vpn-channel'])['outbounds'][0]['uuid'], 'CHANNEL-SECRET-UUID')
        self.assertEqual(config['disk'], {'folders': ['Проект', 'Проект/docs']})
        self.assertEqual(config['happier'], {'mode': 'new', 'label': 'Сын'})
        for name in config['secrets']:
            self.assertRegex(name, r'^[a-z0-9][a-z0-9._-]{0,63}$')
        off, _ = self.e.export('Без VPN', '--vpn', 'off')
        self.assertFalse(off['vpn']['enabled'])
        self.assertNotIn('channel', off['vpn'].get('bootstrap', {}))
        self.assertEqual(set(off['secrets']), {'server-key', 'hop-relay-key', 'hop-relay-password'})
        # Секрет с правами шире 0600 — отказ до выдачи ключа.
        before = self.e.auth.read_text()
        self.e.channel.chmod(0o644)
        p = self.e.cli('export', '--name', 'Плохие права')
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('0600', p.stderr.decode())
        self.assertEqual(self.e.auth.read_text(), before)
        print('PASS: маршруты direct/proxy/hop и VPN первым → разделы и имена секретов соглашения; плохие права → отказ без ключа')

    def test_refusals_bad_name_untrusted_settings_symlink(self):
        for name in ('', 'a\nb', 'x' * 81, 'tab\there'):
            with self.subTest(name=name):
                self.assertNotEqual(self.e.cli('export', '--name', name).returncode, 0)
        self.assertFalse(self.e.auth.exists() and self.e.auth.read_text())
        self.e.cfg.chmod(0o666)
        p = self.e.cli('list')
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('закрыты от записи', p.stderr.decode())
        self.e.cfg.chmod(0o600)
        victim = self.e.dir / 'victim'
        victim.write_text('unchanged\n')
        self.e.auth.unlink(missing_ok=True)
        self.e.auth.symlink_to(victim)
        p = self.e.cli('export', '--name', 'Symlink')
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(victim.read_text(), 'unchanged\n')
        self.e.auth.unlink()
        (self.e.home / '.ssh').rmdir()
        (self.e.home / '.ssh').symlink_to(self.e.dir)
        self.assertNotEqual(self.e.cli('export', '--name', 'Symlink dir').returncode, 0)
        self.assertFalse((self.e.dir / 'authorized_keys').exists())
        out = self.e.dir / 'out.json'
        out.write_text('old')
        self.assertNotEqual(self.e.cli('export', '--name', 'X', '--output', out).returncode, 0)
        self.assertEqual(out.read_text(), 'old')
        print('PASS отказы: имя, настройки с записью для всех, symlink authorized_keys/.ssh, существующий --output')

    def test_root_run_gives_files_to_worker(self):
        # Запуск от root без root: geteuid и fchown подменены, проверяется только кому отдаются файлы.
        from unittest import mock
        c = rc.settings(self.e.cfg)
        self.e.auth.unlink(missing_ok=True)
        (self.e.home / '.ssh').rmdir()
        account = pwd.getpwnam(USER)
        with mock.patch.object(rc.os, 'geteuid', return_value=0), mock.patch.object(rc.os, 'fchown') as fchown:
            rc.replace_worker(c, c['workerAuthorizedKeys'], lambda old: old + 'ssh-ed25519 AAAA x\n')
        self.assertEqual({call.args[1:] for call in fchown.call_args_list}, {(account.pw_uid, account.pw_gid)})
        self.assertEqual(fchown.call_count, 2)  # созданный .ssh и сам authorized_keys
        self.assertEqual(self.e.auth.read_text(), 'ssh-ed25519 AAAA x\n')

    def test_foreign_bytes_and_crlf_settings_preserved(self):
        self.e.auth.write_bytes(b'# \xff\xfe not utf-8\r\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOther other@host\n')
        self.e.cfg.write_bytes(json.dumps(self.e.c, ensure_ascii=False, indent=1).replace('\n', '\r\n').encode('utf-8-sig'))
        self.e.export('CRLF')
        data = self.e.auth.read_bytes()
        self.assertTrue(data.startswith(b'# \xff\xfe not utf-8\r\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOther other@host\n'))
        ident = data.splitlines()[-1].split()[2].decode()[len('ra-config:'):]
        self.assertEqual(self.e.cli('revoke', ident).returncode, 0)
        self.assertIn(b'\xff\xfe not utf-8', self.e.auth.read_bytes())

    def test_review_unsafe_paths_fifo_and_quoted_options(self):
        # .ssh с записью для группы: sshd (StrictModes) не примет ключ — выдача честно отказывает.
        (self.e.home / '.ssh').chmod(0o770)
        p = self.e.cli('export', '--name', 'Группа')
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('открыт для записи', p.stderr.decode())
        (self.e.home / '.ssh').chmod(0o700)
        # FIFO вместо authorized_keys не подвешивает команду.
        self.e.auth.unlink(missing_ok=True)
        os.mkfifo(self.e.auth)
        started = time.monotonic()
        p = self.e.cli('export', '--name', 'FIFO', timeout=20)
        self.assertNotEqual(p.returncode, 0)
        self.assertLess(time.monotonic() - started, 10)
        self.assertNotEqual(self.e.cli('list', timeout=20).returncode, 0)
        self.e.auth.unlink()
        # Метка внутри кавычек опций — не комментарий; Unicode-разделитель в чужом комментарии не перевод строки.
        foreign = ('command="echo ssh-ed25519 AAAA ra-config:0123456789abcdef x" '
                   'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIForeign foreign\u2028tail\n')
        self.e.auth.write_text(foreign)
        self.e.export('Свой')
        own = self.e.auth.read_text().split('\n')[1].split()[2][len('ra-config:'):]
        self.assertEqual(self.e.cli('revoke', '0123456789abcdef').returncode, 1)  # чужая строка не считается выдачей
        self.assertEqual(self.e.cli('revoke', own).returncode, 0)
        self.assertEqual(self.e.auth.read_text(), foreign)
        print('PASS ревью: .ssh g+w → отказ; FIFO → отказ без зависания; метка в опциях и \\u2028 не путают revoke')

    def test_review_parallel_shell_append_not_lost(self):
        # Мастер дописывает ключи обычным `>>` без flock; выдача дописывает через O_APPEND и их не теряет.
        script = 'for i in $(seq 1 300); do printf "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIShell$i shell$i\\n" >> "$1"; done'
        writer = subprocess.Popen(['bash', '-c', script, 'x', str(self.e.auth)])
        for n in range(4):
            self.e.export('Параллельно ' + str(n))
        writer.wait(timeout=30)
        lines = self.lines()
        self.assertEqual(sum('shell' in x for x in lines), 300)
        self.assertEqual(sum('ra-config:' in x for x in lines), 4)

    def test_wizard_helper_append_survives_revoke(self):
        # build/server-ssh-user.sh (мастер) дописывает под тем же flock и только в текущий файл:
        # revoke (временный файл + rename под flock) не теряет ни одной его строки.
        for n in range(12):
            self.e.export('Отзыв ' + str(n))
        ids = [json.loads(x)['id'] for x in self.e.cli('list', '--json').stdout.decode().splitlines()]
        self.assertEqual(len(ids), 12)
        helper = ROOT / 'build/server-ssh-user.sh'
        script = ('for i in $(seq 1 150); do ra_user="$1" ra_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIWizard$i" '
                  'HOME="$2" bash "$3" || exit 1; done')
        writer = subprocess.Popen(['bash', '-c', script, 'x', USER, str(self.e.home), str(helper)], stdin=subprocess.DEVNULL)
        for config_id in ids:
            r = self.e.cli('revoke', config_id)
            self.assertEqual(r.returncode, 0, r.stderr.decode())
        self.assertEqual(writer.wait(timeout=60), 0)
        lines = self.lines()
        self.assertEqual(sum('AAAAIWizard' in x for x in lines), 150)
        self.assertEqual(sum('ra-config:' in x for x in lines), 0)
        self.assertEqual(self.e.auth.stat().st_mode & 0o777, 0o600)

    def test_review_failed_delivery_rolls_back_key(self):
        c = rc.settings(self.e.cfg)

        class Broken:
            def write(self, text):
                raise BrokenPipeError()

            def flush(self):
                pass
        import argparse
        import io
        args = argparse.Namespace(name='Обрыв', happier='same', folders='', master_password_stdin=False, vpn='off', output=None)
        with self.assertRaises(BrokenPipeError):
            rc.export(c, args, out=Broken(), err=io.StringIO())
        self.assertNotIn('ra-config:', self.e.auth.read_text() if self.e.auth.exists() else '')
        rows = [json.loads(x) for x in self.e.cli('list', '--json').stdout.decode().splitlines()]
        self.assertEqual([r['state'] for r in rows], ['выдача не удалась'])
        events = (Path(c['stateDir']) / 'config-events.log').read_text()
        self.assertIn('export.failed', events)
        self.assertNotIn('export.ok', events)

    def test_review_latest_login_kdf_cap_and_names(self):
        self.e.export('Вход')
        fp = json.loads(self.e.cli('list', '--json').stdout)['fingerprint']
        rotated = self.e.dir / 'auth.log.1'
        line = '%s host sshd[1]: Accepted publickey for ' + USER + ' from 192.0.2.1 port 5 ssh2: ED25519 ' + fp + '\n'
        self.e.log.write_text(line % '2026-11-12T10:00:00+00:00')
        rotated.write_text(line % '2026-11-01T10:00:00+00:00')
        self.e.c['authLog'] = [str(self.e.log), str(rotated)]  # текущий раньше ротированного
        self.e.write()
        self.assertEqual(json.loads(self.e.cli('list', '--json').stdout)['lastLogin'], '2026-11-12T10:00:00+00:00')
        section = rc.protect({'x': 'y'}, MASTER, iterations=10000)
        section['kdf']['iterations'] = 2000000000
        with self.assertRaises(rc.Error):
            rc.unprotect(section, MASTER)
        home = Path(self.tmp.name) / 'nodes-home'
        catalog = home / 'nodes'

        def record(project, host, name, control=False):
            label = 'win-' + (host + project).encode().hex()[:28].ljust(28, '0')
            data = dict(projectId=project, hostId=host, deviceLabel=label, socketPath=str(home / '.local/state/codex-remote' / (label + '.sock')),
                        serverWorkspace=str(home / 'work/projects' / project), windowsReplica='C:\\r\\' + project, allowShell=False)
            if name is not None:
                data['deviceName'] = name
            if control:
                data['controlOnly'] = True
            return data
        nodes.register(catalog, record('control', 'h1', 'Ноутбук', True), home)
        nodes.register(catalog, record('control', 'h1', None, True), home)  # регистрация без имени не сбрасывает выбранное
        nodes.register(catalog, record('site', 'h1', None), home)
        self.assertEqual({r['deviceName'] for r in nodes.records(catalog, home)}, {'Ноутбук'})
        # Параллельные регистрации одного компьютера под замком дают одно имя на всех записях.
        with concurrent.futures.ThreadPoolExecutor(6) as pool:
            list(pool.map(lambda n: nodes.register(catalog, record('p' + str(n), 'h1', 'WIN-X'), home) if n % 2 else
                          nodes.register(catalog, record('control', 'h1', 'Ноутбук ' + str(n), True), home), range(6)))
        self.assertEqual(len({r['deviceName'] for r in nodes.records(catalog, home)}), 1)

    def test_output_file_private(self):
        out = self.e.dir / 'issued.json'
        p = self.e.cli('export', '--name', 'В файл', '--output', out)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, b'')
        self.assertEqual(out.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(out.read_text())['device']['name'], 'В файл')

    def test_sync_snapshot_for_autoupdate(self):
        self.e.vpn()
        self.e.export('Первый')
        sync = Path(self.e.c['syncFile'])
        self.assertEqual(sync.stat().st_mode & 0o777, 0o600)
        data = json.loads(sync.read_text())
        self.assertEqual((data['kind'], data['schema']), ('remoteagents-config-sync', 1))
        config = data['config']
        self.assertEqual(set(config), {'kind', 'schema', 'server', 'vpn', 'secrets'})
        self.assertNotIn('key', config['server'])
        self.assertNotIn('server-key', config['secrets'])
        self.assertNotIn('enabled', config['vpn'])
        self.assertEqual(set(config['secrets']), {'vpn-channel', 'vpn-entry-entry1', 'vpn-hop-vhop'})
        stamp, revision = data['generatedUtc'], data['revision']
        time.sleep(1.1)
        self.assertEqual(self.e.cli('sync').returncode, 0)
        self.assertEqual(json.loads(sync.read_text())['generatedUtc'], stamp)  # ничего не поменялось — файл тот же
        other = keygen(self.e.dir / 'new-host')
        self.e.c.update(serverAddress='198.51.100.7', hostKeys=[self.e.host_pub, other])
        self.e.write()
        self.assertEqual(self.e.cli('sync').returncode, 0)
        changed = json.loads(sync.read_text())
        self.assertNotEqual(changed['revision'], revision)
        self.assertEqual(changed['config']['server']['address'], '198.51.100.7')
        self.assertEqual(changed['config']['server']['hostKeys'], [self.e.host_pub, other])
        print('PASS sync: снимок 0600 без ключа устройства и выбора VPN; ревизия меняется только при изменении')

    def test_devices_names_registry_and_windows_devices(self):
        home = Path(self.tmp.name) / 'nodes-home'
        catalog = home / '.local/share/remote-agents-nodes'

        def record(project, host, name, control=False):
            label = 'win-' + (host + project).encode().hex()[:28].ljust(28, '0')
            data = dict(projectId=project, hostId=host, deviceLabel=label, deviceName=name,
                        socketPath=str(home / '.local/state/codex-remote' / (label + '.sock')),
                        serverWorkspace=str(home / 'work/projects' / project), windowsReplica='C:\\replica\\' + project, allowShell=False)
            if control:
                data['controlOnly'] = True
            return data
        nodes.register(catalog, record('site', 'h1', 'WIN-ABC123'), home)
        nodes.register(catalog, record('control', 'h1', 'Ноутбук\u202e сына\r\n', True), home)
        names = {r['projectId']: r['deviceName'] for r in nodes.records(catalog, home)}
        self.assertEqual(names, {'site': 'Ноутбук сына', 'control': 'Ноутбук сына'})
        nodes.register(catalog, record('site', 'h1', 'WIN-ABC123'), home)  # передача проекта знает только MachineName
        self.assertEqual({r['deviceName'] for r in nodes.records(catalog, home)}, {'Ноутбук сына'})
        nodes.register(catalog, record('control', 'h2', '', True), home)
        self.assertEqual([r['deviceName'] for r in nodes.records(catalog, home) if r['hostId'] == 'h2'], ['h2'])
        legacy = catalog / 'h2/control.json'
        old = json.loads(legacy.read_text())
        old.pop('deviceName')
        legacy.write_text(json.dumps(old))
        spec = importlib.util.spec_from_file_location('bridge_under_test', ROOT / 'codex-windows-bridge.py')
        bridge = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(bridge)
        saved_home = os.environ['HOME']
        os.environ['HOME'] = str(home)  # мост читает реестр своего HOME
        try:
            answer = bridge.dispatch({'method': 'tools/call', 'params': {'name': 'windows_devices', 'arguments': {}}}, None, str(catalog))
        finally:
            os.environ['HOME'] = saved_home
        rows = json.loads(answer['content'][0]['text'])['devices']
        self.assertEqual(sorted((r['hostId'], r['deviceName']) for r in rows), [('h1', 'Ноутбук сына'), ('h1', 'Ноутбук сына'), ('h2', 'h2')])
        self.assertTrue(all(r['available'] is False and r['offlineReason'] for r in rows))
        self.e.c['nodeCatalog'] = str(catalog)
        self.e.write()
        # devices читает реестр рабочего пользователя; HOME реестра здесь — временный.
        c = rc.settings(self.e.cfg)
        import io
        out = io.StringIO()
        original = rc.worker_home
        rc.worker_home = lambda _: home
        try:
            rc.devices(c, out)
        finally:
            rc.worker_home = original
        listed = [json.loads(x) for x in out.getvalue().splitlines()]
        self.assertEqual({r['hostId']: r['deviceName'] for r in listed}, {'h1': 'Ноутбук сына', 'h2': 'h2'})
        print('PASS имена: deviceName из Bridge → реестр (очищен, общий для всех проектов компьютера) → windows_devices и config devices')

    def test_wrapper_and_no_invite_leftovers(self):
        p = run(['bash', ROOT / 'server/remoteagents', 'config', '--config', self.e.cfg, 'list'])
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(run(['bash', ROOT / 'server/remoteagents', 'invite', 'list']).returncode, 2)
        for name in ('invite.py', 'invite_overlay.py', 'install-invite.sh', 'invite-config.schema.json', 'invite-config.example.json'):
            self.assertFalse((ROOT / 'server' / name).exists(), name)
        found = run(['grep', '-rlE', 'ra-enroll|invite_overlay|enrollHelper|invite-settings|ra-invite:', ROOT / 'server', ROOT / 'server_node_catalog.py',
                     ROOT / 'codex-windows-bridge.py', '--exclude=test_config_export.py', '--exclude-dir=__pycache__']).stdout.decode()
        self.assertEqual(found, '')


class RealSshdTests(unittest.TestCase):
    """Вход ключом из конфига на настоящем sshd (loopback, без root), затем отзыв закрывает вход."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ra-config-sshd-')
        self.addCleanup(self.tmp.cleanup)
        with socket.socket() as s:
            s.bind(('127.0.0.1', 0))
            self.port = s.getsockname()[1]
        self.e = Env(self.tmp.name, serverPort=self.port)
        d = self.e.dir
        (d / 'sshd_config').write_text(f'''ListenAddress 127.0.0.1
Port {self.port}
HostKey {self.e.host_key}
PidFile {d}/sshd.pid
AuthorizedKeysFile {self.e.auth}
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers {USER}
LogLevel VERBOSE
SetEnv HOME={d / 'worker'}
''')
        self.log = (d / 'sshd.log').open('w')
        self.server = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(d / 'sshd_config')], stdout=self.log, stderr=self.log)
        self.addCleanup(self.stop)
        for _ in range(200):
            try:
                with socket.create_connection(('127.0.0.1', self.port), .1):
                    break
            except OSError:
                if self.server.poll() is not None:
                    self.fail((d / 'sshd.log').read_text())
                time.sleep(.02)

    def stop(self):
        self.server.terminate()
        self.server.wait(timeout=5)
        self.log.close()

    def ssh(self, key, known):
        return run(['ssh', '-F', '/dev/null', '-T', '-p', self.port, '-i', key, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
                    '-o', 'StrictHostKeyChecking=yes', '-o', 'GlobalKnownHostsFile=none', '-o', 'UserKnownHostsFile=' + str(known),
                    '-o', 'ConnectTimeout=5', USER + '@127.0.0.1', 'printf config-key-ok'], timeout=30)

    def test_export_login_then_revoke_denies(self):
        started = time.monotonic()
        config, _ = self.e.export('Стенд', password=MASTER)
        plain = rc.unprotect(config['secrets'], MASTER)
        key = self.e.dir / 'client-key'
        key.write_text(plain['server-key'])
        key.chmod(0o600)
        known = self.e.dir / 'known_hosts'
        server = config['server']
        known.write_text(''.join('[%s]:%d %s\n' % (server['address'], server['port'], k) for k in server['hostKeys']))
        ok = self.ssh(key, known)
        self.assertEqual((ok.returncode, ok.stdout), (0, b'config-key-ok'), ok.stderr)
        elapsed = time.monotonic() - started
        ident = self.e.auth.read_text().split()[2][len('ra-config:'):]
        # Журнал этого sshd (stderr без времени) с меткой времени, как в journalctl -o short-iso.
        self.e.log.write_text(''.join('2026-11-12T12:00:00+0000 host sshd[1]: ' + line + '\n'
                                      for line in (self.e.dir / 'sshd.log').read_text().splitlines()))
        rows = [json.loads(x) for x in self.e.cli('list', '--json').stdout.decode().splitlines()]
        self.assertEqual((rows[0]['id'], rows[0]['lastLogin']), (ident, '2026-11-12T12:00:00+0000'))
        self.assertEqual(self.e.cli('revoke', ident).returncode, 0)
        denied = self.ssh(key, known)
        self.assertNotEqual(denied.returncode, 0)
        self.assertIn(b'Permission denied', denied.stderr)
        print('PASS sshd: выдача+вход ключом из зашифрованного конфига за %.2f с; после revoke вход запрещён' % elapsed)


if __name__ == '__main__':
    unittest.main()
