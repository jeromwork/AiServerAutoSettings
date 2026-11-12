#!/usr/bin/env python3
"""remoteagents config: выдача полного конфига компьютеру, список, отзыв, автообновление.

Доступ = ключ ed25519, выданный в конфиге: «передали конфиг — есть доступ, не передали — нет».
Своей криптографии нет: ключи делает ssh-keygen (OpenSSH), шифрование значений секретов —
PBKDF2 из hashlib и AES-CBC из пакета cryptography (python3-cryptography), HMAC из stdlib.
Все адреса, пути и имена берутся из настроек выдачи (docs/CONFIG-SERVER.md), в коде их нет.
"""
import argparse
import base64
import contextlib
import datetime as dt
import fcntl
import getpass
import hashlib
import hmac
import importlib.util
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import time

DEFAULT_CONFIG = '/etc/remoteagents/config-export.json'
USER_CONFIG = '.config/remoteagents/config-export.json'
LABEL = 'ra-config:'
CONFIG_KIND = 'remoteagents-config'
SYNC_KIND = 'remoteagents-config-sync'
ITERATIONS = 200000
CHECK_TEXT = 'remoteagents'
ID_RE = re.compile(r'[a-f0-9]{16}\Z')
USER_RE = re.compile(r'[a-z_][a-z0-9_-]{0,31}\Z')
HOST_RE = re.compile(r'[A-Za-z0-9][A-Za-z0-9.:-]{0,252}\Z')
HOST_KEY_RE = re.compile(r'(ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|ssh-rsa) [A-Za-z0-9+/]+={0,2}\Z')
ROUTE_NAME_RE = re.compile(r'[a-z0-9][a-z0-9_-]{0,31}\Z')
ROOT = Path(__file__).resolve().parents[1]


class Error(Exception):
    pass


def require(ok, message):
    if not ok:
        raise Error(message)


def now():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def load_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig').replace('\r', ''))


def clean_name(value, limit=80):
    """Человеческое название: без управляющих/невидимых символов и переводов строк."""
    require(isinstance(value, str), 'Название должно быть строкой')
    text = ' '.join(''.join(ch for ch in value if ch.isprintable()).split())
    require(0 < len(text) <= limit and text == ' '.join(value.split()), 'Название: 1–%d видимых символов без переводов строк' % limit)
    return text


# ---------- enc1 (docs/CONFIG-CONTRACT.md, раздел 1) ----------

def _aes():
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        from cryptography.hazmat.primitives import padding
    except ImportError:
        raise Error('Для мастер-пароля нужен пакет python3-cryptography (apt install python3-cryptography). '
                    'Без мастер-пароля конфиг выдаётся с секретами открытым текстом.')
    return Cipher, algorithms, modes, padding


def derive(master, salt, iterations):
    require(isinstance(master, str) and master, 'Пустой мастер-пароль')
    key = hashlib.pbkdf2_hmac('sha256', master.encode('utf-8'), salt, iterations, 64)
    return key[:32], key[32:]


def enc1(plain, keys, iv=None):
    Cipher, algorithms, modes, padding = _aes()
    iv = iv if iv is not None else os.urandom(16)
    require(len(iv) == 16, 'IV 16 байт')
    padder = padding.PKCS7(128).padder()
    data = padder.update(plain.encode('utf-8')) + padder.finalize()
    encryptor = Cipher(algorithms.AES(keys[0]), modes.CBC(iv)).encryptor()
    body = iv + encryptor.update(data) + encryptor.finalize()
    return 'enc1:' + base64.b64encode(body + hmac.new(keys[1], body, hashlib.sha256).digest()).decode('ascii')


def dec1(value, keys):
    Cipher, algorithms, modes, padding = _aes()
    require(isinstance(value, str) and value.startswith('enc1:'), 'Значение не enc1')
    try:
        raw = base64.b64decode(value[5:], validate=True)
    except ValueError:
        raise Error('Повреждено значение enc1')
    require(len(raw) >= 64 and (len(raw) - 48) % 16 == 0, 'Повреждено значение enc1')
    body, mac = raw[:-32], raw[-32:]
    require(hmac.compare_digest(mac, hmac.new(keys[1], body, hashlib.sha256).digest()), 'Неверный мастер-пароль или подмена')
    decryptor = Cipher(algorithms.AES(keys[0]), modes.CBC(body[:16])).decryptor()
    unpadder = padding.PKCS7(128).unpadder()
    data = unpadder.update(decryptor.update(body[16:]) + decryptor.finalize()) + unpadder.finalize()
    return data.decode('utf-8')


def protect(values, master, salt=None, iterations=ITERATIONS):
    """values: имя → открытый текст. Возвращает раздел secrets по соглашению."""
    salt = salt if salt is not None else os.urandom(16)
    keys = derive(master, salt, iterations)
    result = {'protected': 'master-password',
              'kdf': {'name': 'pbkdf2-sha256', 'iterations': iterations, 'salt': base64.b64encode(salt).decode('ascii')},
              'check': enc1(CHECK_TEXT, keys)}
    for name, value in values.items():
        result[name] = enc1(value, keys) if value else ''
    return result


def unprotect(section, master):
    """Обратная операция (для проверок и для `config sync`-клиентов на Python)."""
    if section.get('protected') is None:
        return {k: v for k, v in section.items()}
    require(section.get('protected') == 'master-password', 'Неизвестный вид защиты секретов')
    kdf = section.get('kdf') or {}
    require(kdf.get('name') == 'pbkdf2-sha256' and type(kdf.get('iterations')) is int and 10000 <= kdf['iterations'] <= 10000000, 'Неверные параметры kdf')
    keys = derive(master, base64.b64decode(kdf['salt'], validate=True), kdf['iterations'])
    require(dec1(section.get('check', ''), keys) == CHECK_TEXT, 'Неверный мастер-пароль')
    return {k: (dec1(v, keys) if v else '') for k, v in section.items() if k not in ('protected', 'kdf', 'check')}


# ---------- настройки выдачи ----------

def trusted(path, what):
    """Файл и все предки — root или текущий пользователь, без записи группе/другим (кроме /tmp-подобных sticky root)."""
    euid = os.geteuid()
    path = Path(path)
    for node in (path, *path.absolute().parents, *path.resolve().parents):
        st = node.stat()
        sticky_root = stat.S_ISDIR(st.st_mode) and st.st_mode & stat.S_ISVTX and st.st_uid == 0
        require(st.st_uid in (0, euid) and (st.st_mode & 0o022 == 0 or sticky_root),
                what + ': файл и каталоги над ним должны принадлежать root или вам и быть закрыты от записи другим')


def read_trusted(path, what, private=False):
    """Проверка и чтение одного и того же объекта: путь разрешается, каталоги над ним проверяются
    (никто чужой не может подменить), файл открывается O_NOFOLLOW|O_NONBLOCK и проверяется через fstat."""
    path = Path(path)
    require(path.is_absolute(), what + ': нужен абсолютный путь')
    try:
        real = path.resolve(strict=True)
    except OSError:
        raise Error(what + ': нет файла ' + str(path))
    for node in (real.parent, *real.parent.parents):
        st = node.stat()
        sticky_root = st.st_mode & stat.S_ISVTX and st.st_uid == 0
        require(st.st_uid in (0, os.geteuid()) and (st.st_mode & 0o022 == 0 or sticky_root),
                what + ': каталоги над файлом должны принадлежать root или вам и быть закрыты от записи другим')
    try:
        fd = os.open(real, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        raise Error(what + ': файл недоступен ' + str(path))
    try:
        st = os.fstat(fd)
        require(stat.S_ISREG(st.st_mode) and st.st_uid in (0, os.geteuid()) and st.st_mode & 0o022 == 0,
                what + ': файл должен принадлежать root или вам и быть закрыт от записи другим')
        require(not private or st.st_mode & 0o077 == 0, what + ': нужен файл с правами 0600')
        with os.fdopen(os.dup(fd), 'rb') as stream:
            raw = stream.read(4 * 1024 * 1024 + 1)
        require(len(raw) <= 4 * 1024 * 1024, what + ': файл больше 4 МиБ')
        return raw.decode('utf-8-sig').replace('\r', '')
    finally:
        os.close(fd)


def private_file(path, what):
    return read_trusted(path, what, private=True)


def worker_home(c):
    try:
        return Path(pwd.getpwnam(c['workerUser']).pw_dir)
    except KeyError:
        raise Error('Нет пользователя ' + c['workerUser'] + ' (workerUser в настройках выдачи)')


def settings(path=None):
    if path is None:
        path = DEFAULT_CONFIG
        user_path = Path.home() / USER_CONFIG
        if not Path(path).exists() and user_path.exists():
            path = user_path
    path = Path(path)
    require(path.exists(), 'Нет настроек выдачи ' + str(path) + ' (пример: server/config-export.example.json)')
    trusted(path, 'Настройки выдачи')
    try:
        c = json.loads(read_trusted(path.absolute(), 'Настройки выдачи'))
    except ValueError:
        raise Error('Настройки выдачи: повреждён JSON')
    require(isinstance(c, dict) and c.get('schema') == 1 and c.get('version') == 1, 'Неизвестная схема настроек выдачи')
    allowed = {'schema', 'version', '$schema', 'serverAddress', 'serverPort', 'hostKeys', 'hostKeyFiles', 'workerUser',
               'workerAuthorizedKeys', 'stateDir', 'syncFile', 'nodeCatalog', 'routes', 'catalogFile', 'vpnBootstrap',
               'happier', 'authLog'}
    unknown = set(c) - allowed
    require(not unknown, 'Неизвестные поля в настройках выдачи: ' + ', '.join(sorted(unknown)))
    require(isinstance(c.get('workerUser'), str) and USER_RE.fullmatch(c['workerUser']) and c['workerUser'] != 'root', 'workerUser: рабочий пользователь (не root)')
    require(isinstance(c.get('serverAddress'), str) and HOST_RE.fullmatch(c['serverAddress']), 'serverAddress: адрес сервера')
    require(type(c.get('serverPort')) is int and 1 <= c['serverPort'] <= 65535, 'serverPort: 1–65535')
    home = worker_home(c)
    c.setdefault('workerAuthorizedKeys', str(home / '.ssh/authorized_keys'))
    c.setdefault('syncFile', str(home / '.config/remoteagents/config-sync.json'))
    c.setdefault('nodeCatalog', str(home / '.local/share/remote-agents-nodes'))
    default_state = '/var/lib/remoteagents/config-export' if os.geteuid() == 0 else str(Path.home() / '.local/state/remoteagents/config-export')
    c.setdefault('stateDir', default_state)
    for field in ('workerAuthorizedKeys', 'syncFile', 'nodeCatalog', 'stateDir'):
        require(isinstance(c[field], str) and Path(c[field]).is_absolute() and '\n' not in c[field], field + ': нужен абсолютный путь')
    c['_file'] = str(path)
    return c


def host_keys(c):
    keys = c.get('hostKeys')
    if not keys:
        files = c.get('hostKeyFiles') or ['/etc/ssh/ssh_host_ed25519_key.pub', '/etc/ssh/ssh_host_ecdsa_key.pub', '/etc/ssh/ssh_host_rsa_key.pub']
        keys = [' '.join(Path(f).read_text().split()[:2]) for f in files if Path(f).is_file()]
    require(isinstance(keys, list) and keys, 'Нет ключей хоста: задайте hostKeys или hostKeyFiles')
    for key in keys:
        require(isinstance(key, str) and HOST_KEY_RE.fullmatch(key), 'Некорректный ключ хоста (нужно «тип base64»)')
    return keys


def server_routes(c, values):
    """Маршруты из настроек → раздел server.routes соглашения; секреты переходов — в values."""
    result = []
    hop_index = 0
    for route in c.get('routes') or [{'kind': 'direct'}]:
        require(isinstance(route, dict) and route.get('kind') in ('direct', 'proxy', 'hop'), 'Маршрут: direct, proxy или hop')
        if route['kind'] == 'direct':
            require(set(route) == {'kind'}, 'Лишние поля маршрута direct')
            result.append({'kind': 'direct'})
        elif route['kind'] == 'proxy':
            proxy = route.get('proxy') or {}
            require(set(route) == {'kind', 'proxy'} and set(proxy) <= {'type', 'server', 'port'}, 'Маршрут proxy: type, server, port')
            require(proxy.get('type') in ('socks', 'http') and isinstance(proxy.get('server'), str) and HOST_RE.fullmatch(proxy['server'])
                    and type(proxy.get('port')) is int and 1 <= proxy['port'] <= 65535, 'Маршрут proxy: type socks/http, server, port')
            result.append({'kind': 'proxy', 'proxy': dict(proxy)})
        else:
            hop_index += 1
            hop = route.get('hop') or {}
            require(set(route) == {'kind', 'hop'} and set(hop) <= {'name', 'host', 'port', 'user', 'hostKey', 'keyFile', 'passwordFile'},
                    'Маршрут hop: name, host, port, user, hostKey, keyFile/passwordFile (секреты только файлами)')
            require(isinstance(hop.get('host'), str) and HOST_RE.fullmatch(hop['host']) and type(hop.get('port', 22)) is int
                    and 1 <= hop.get('port', 22) <= 65535 and isinstance(hop.get('user'), str) and USER_RE.fullmatch(hop['user']),
                    'Маршрут hop: host, port, user')
            require(isinstance(hop.get('hostKey'), str) and HOST_KEY_RE.fullmatch(hop['hostKey']), 'Маршрут hop: нужен hostKey промежуточного сервера')
            require(hop.get('keyFile') or hop.get('passwordFile'), 'Маршрут hop: нужен keyFile или passwordFile')
            name = hop.get('name') or str(hop_index)
            require(isinstance(name, str) and ROUTE_NAME_RE.fullmatch(name), 'Маршрут hop: name — строчные латинские буквы, цифры, _ и -')
            out = {'host': hop['host'], 'port': hop.get('port', 22), 'user': hop['user'], 'hostKey': hop['hostKey']}
            if hop.get('keyFile'):
                values['hop-' + name + '-key'] = private_file(hop['keyFile'], 'Ключ SSH-перехода')
                out['key'] = {'secret': 'hop-' + name + '-key'}
            if hop.get('passwordFile'):
                values['hop-' + name + '-password'] = private_file(hop['passwordFile'], 'Пароль SSH-перехода').rstrip('\n')
                out['password'] = {'secret': 'hop-' + name + '-password'}
            result.append({'kind': 'hop', 'hop': out})
    require(result, 'Нужен хотя бы один маршрут')
    return result


def catalog_validator():
    helper = ROOT / 'transport/server-transport-catalog.py'
    if not helper.exists():
        helper = Path(__file__).with_name('server-transport-catalog.py')
    spec = importlib.util.spec_from_file_location('ra_transport_catalog', helper)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.validate


def vpn_section(c, values, vpn_on):
    """VPN первым: публичный каталог + секреты канала/узлов/переходов."""
    explicit = c.get('catalogFile')
    source = Path(explicit or worker_home(c) / '.config/remoteagents/transport-catalog.json')
    bootstrap = {}
    if source.exists() or explicit:
        try:
            bootstrap['catalog'] = catalog_validator()(json.loads(read_worker(c, source.absolute()).lstrip('\ufeff').replace('\r', '')))
        except (ValueError, KeyError):
            raise Error('Каталог связи не прошёл проверку схемы: ' + str(source))
    settings_ = c.get('vpnBootstrap')
    if not settings_:
        require(not vpn_on, 'Для --vpn on нужен раздел vpnBootstrap в настройках выдачи (или выдайте с --vpn off)')
        return {'enabled': False, 'bootstrap': bootstrap} if bootstrap else None
    require(set(settings_) <= {'channelFile', 'entryFiles', 'hops', 'vpn'}, 'vpnBootstrap: channelFile, entryFiles, hops, vpn')
    vpn = settings_.get('vpn') or {}
    from urllib.parse import urlsplit
    import ipaddress
    url = urlsplit(vpn.get('checkUrl', ''))
    require(url.scheme == 'https' and url.hostname and not url.username, 'vpnBootstrap.vpn.checkUrl: свой HTTPS-адрес проверки')
    try:
        ipaddress.ip_address(vpn.get('dnsServer', ''))
    except ValueError:
        raise Error('vpnBootstrap.vpn.dnsServer: IP-адрес DNS')
    section = {'enabled': bool(vpn_on), 'checkUrl': vpn['checkUrl'], 'dnsServer': vpn['dnsServer']}
    if vpn_on:
        channel = private_file(settings_['channelFile'], 'Канал VPN')
        json.loads(channel)
        values['vpn-channel'] = channel.strip()
        bootstrap['channel'] = {'secret': 'vpn-channel'}
        catalog = bootstrap.get('catalog') or {'entries': [], 'hops': []}
        entries, hops = {}, {}
        for row in catalog['entries']:
            if row.get('enabled', True):
                path = (settings_.get('entryFiles') or {}).get(row['name'])
                require(path, 'vpnBootstrap.entryFiles: нет файла узла ' + row['name'])
                text = private_file(path, 'Кэш узла VPN')
                json.loads(text)
                name = 'vpn-entry-' + row['name'].lower()
                values[name] = text.strip()
                entries[row['name']] = {'secret': name}
        for row in catalog['hops']:
            if row.get('enabled', True):
                hop = dict((settings_.get('hops') or {}).get(row['name']) or {})
                require(set(hop) == {'host', 'port', 'user', 'keyFile'} and isinstance(hop['host'], str) and HOST_RE.fullmatch(hop['host'])
                        and type(hop['port']) is int and 1 <= hop['port'] <= 65535 and isinstance(hop['user'], str)
                        and USER_RE.fullmatch(hop['user']) and row.get('hostKey'), 'vpnBootstrap.hops.' + row['name'] + ': host, port, user, keyFile и hostKey в каталоге')
                name = 'vpn-hop-' + row['name'].lower()
                values[name] = private_file(hop.pop('keyFile'), 'Ключ SSH-перехода VPN')
                hops[row['name']] = dict(hop, key={'secret': name})
        bootstrap.update(entries=entries, hops=hops)
    if bootstrap:
        section['bootstrap'] = bootstrap
    return section


def common_sections(c, values, vpn_on):
    server = {'address': c['serverAddress'], 'port': c['serverPort'], 'login': c['workerUser'],
              'hostKeys': host_keys(c), 'routes': server_routes(c, values)}
    vpn = vpn_section(c, values, vpn_on)
    return server, vpn


# ---------- authorized_keys и файлы рабочего пользователя ----------

def safe_dir_stat(st, owner):
    """Каталог на пути: владелец root, рабочий пользователь или запускающий; без записи группе/другим
    (кроме sticky-каталогов root вроде /tmp). Иначе sshd (StrictModes) не примет ключ, а чужой мог бы подменить файл."""
    allowed = {0, os.geteuid()} | ({owner[0]} if owner else set())
    sticky_root = st.st_mode & stat.S_ISVTX and st.st_uid == 0
    return st.st_uid in allowed and (st.st_mode & 0o022 == 0 or sticky_root)


@contextlib.contextmanager
def directory(path, owner):
    """Каталог открывается по цепочке O_NOFOLLOW от корня: подмена symlink по пути не сработает."""
    parent = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in Path(path).parts[1:]:
            try:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            except FileNotFoundError:
                os.mkdir(part, 0o700, dir_fd=parent)
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
                if owner:
                    os.fchown(child, *owner)
            except OSError:
                raise Error('Путь ' + str(path) + ' недоступен или содержит symlink')
            os.close(parent)
            parent = child
            if not safe_dir_stat(os.fstat(parent), owner):
                raise Error('Каталог ' + str(path) + ' (или выше) принадлежит чужому пользователю или открыт для записи другим')
        yield parent
    finally:
        os.close(parent)


def owner_of(c):
    if os.geteuid() != 0:
        return None
    worker_home(c)  # понятная ошибка, если пользователя нет
    user = pwd.getpwnam(c['workerUser'])
    return user.pw_uid, user.pw_gid


def open_regular(name, parent, path, flags=os.O_RDONLY):
    """O_NONBLOCK: FIFO вместо файла не подвесит команду; тип проверяется до чтения."""
    fd = os.open(name, flags | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
        os.close(fd)
        raise Error(str(path) + ': не обычный файл или hardlink')
    os.set_blocking(fd, True)
    return fd, st


def read_fd(fd):
    # newline='' и surrogateescape: чужие строки (CRLF, не UTF-8) сохраняются байт в байт.
    with os.fdopen(os.dup(fd), 'r', encoding='utf-8', errors='surrogateescape', newline='') as stream:
        stream.seek(0)
        return stream.read()


def write_all(fd, text):
    data = memoryview(text.encode('utf-8', 'surrogateescape'))
    while data:
        data = data[os.write(fd, data):]


def read_worker(c, path):
    path = Path(path)
    with directory(path.parent, owner_of(c)) as parent:
        try:
            fd, _ = open_regular(path.name, parent, path)
        except FileNotFoundError:
            return ''
        except OSError:
            raise Error(str(path) + ': не обычный файл (symlink?)')
        try:
            return read_fd(fd)
        finally:
            os.close(fd)


def append_worker(c, path, line):
    """Дописывание строки через O_APPEND проверенного файла: параллельный `>>` другого процесса не теряется."""
    path = Path(path)
    owner = owner_of(c)
    with directory(path.parent, owner) as parent:
        try:
            fd, st = open_regular(path.name, parent, path, os.O_RDWR | os.O_APPEND)
        except FileNotFoundError:
            fd = os.open(path.name, os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
            st = os.fstat(fd)
        except OSError:
            raise Error(str(path) + ': не обычный файл (symlink?)')
        try:
            require(st.st_uid in ({owner[0], 0} if owner else {os.geteuid()}), str(path) + ': файл принадлежит чужому пользователю')
            fcntl.flock(fd, fcntl.LOCK_EX)
            old = read_fd(fd)
            write_all(fd, ('' if not old or old.endswith('\n') else '\n') + line + '\n')
            os.fchmod(fd, 0o600)
            if owner:
                os.fchown(fd, *owner)
            os.fsync(fd)
        finally:
            os.close(fd)


def replace_worker(c, path, transform):
    """Атомарная замена файла рабочего пользователя: 0600, владелец — рабочий пользователь,
    flock, без symlink/hardlink/FIFO; если файл поменял кто-то ещё, пересчитать.
    Остаточное окно: `>>` без flock между последней проверкой и rename (микросекунды) — см. отчёт."""
    path = Path(path)
    owner = owner_of(c)
    with directory(path.parent, owner) as parent:
        for _ in range(5):
            old_fd, before, old = None, None, ''
            try:
                old_fd, before = open_regular(path.name, parent, path)
            except FileNotFoundError:
                pass
            except OSError:
                raise Error(str(path) + ': не обычный файл (symlink?)')
            tmp = '.' + path.name + '.ra-' + secrets.token_hex(6)
            try:
                if old_fd is not None:
                    fcntl.flock(old_fd, fcntl.LOCK_EX)
                    old = read_fd(old_fd)
                new = transform(old)
                if before is None and not new:
                    return old, new
                if new == old and before is not None and before.st_mode & 0o777 == 0o600 and (not owner or before.st_uid == owner[0]):
                    return old, new
                fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
                try:
                    write_all(fd, new)
                    os.fchmod(fd, 0o600)
                    if owner:
                        os.fchown(fd, *owner)
                    os.fsync(fd)
                finally:
                    os.close(fd)
                try:
                    current = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
                except FileNotFoundError:
                    current = None
                same = (current is None and before is None) or (current is not None and before is not None and
                        (current.st_ino, current.st_size, current.st_mtime_ns) == (before.st_ino, before.st_size, before.st_mtime_ns))
                if not same:
                    continue
                os.rename(tmp, path.name, src_dir_fd=parent, dst_dir_fd=parent)
                os.fsync(parent)
                return old, new
            finally:
                if old_fd is not None:
                    os.close(old_fd)
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(tmp, dir_fd=parent)
        raise Error(str(path) + ' всё время меняется другим процессом; повторите позже')


def split_lines(text):
    """Строки по LF с окончаниями; Unicode-разделители внутри строк не считаются переводом строки."""
    parts = text.split('\n')
    return [x + '\n' for x in parts[:-1]] + ([parts[-1]] if parts[-1] else [])


KEY_TYPE_RE = re.compile(r'(ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\Z')


def parse_key_line(line):
    """→ (тип, base64, комментарий) или None — по формату sshd(8): [опции] тип base64 [комментарий].
    Опции разбираются с учётом кавычек и \\-экранирования, метка ищется только в настоящем комментарии."""
    text = line.strip()
    if not text or text.startswith('#'):
        return None
    head = text.split(None, 1)
    if not KEY_TYPE_RE.fullmatch(head[0]):
        quoted, i = False, 0
        while i < len(text) and (quoted or text[i] not in ' \t'):
            if text[i] == '\\' and quoted:
                i += 1
            elif text[i] == '"':
                quoted = not quoted
            i += 1
        if quoted:
            return None
        text = text[i:].strip()
    parts = text.split(None, 2)
    if len(parts) < 2 or not KEY_TYPE_RE.fullmatch(parts[0]) or not re.fullmatch(r'[A-Za-z0-9+/]+={0,2}', parts[1]):
        return None
    return parts[0], parts[1], (parts[2].strip() if len(parts) > 2 else '')


def config_label(comment):
    match = re.match(re.escape(LABEL) + r'([a-f0-9]{16})(?: (.*))?\Z', comment)
    return (match.group(1), match.group(2) or '') if match else None


def fingerprint(blob):
    return 'SHA256:' + base64.b64encode(hashlib.sha256(base64.b64decode(blob)).digest()).decode().rstrip('=')


# ---------- состояние и журнал ----------

@contextlib.contextmanager
def locked(c):
    root = Path(c['stateDir'])
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    require(not root.is_symlink(), 'stateDir не должен быть symlink')
    trusted(root, 'stateDir')  # состояние не под управлением рабочего пользователя, если запускает root
    with (root / 'config.lock').open('a') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield root


def event(c, code, ident=''):
    # Только фиксированные коды и id: без названий, ключей, паролей, путей.
    with (Path(c['stateDir']) / 'config-events.log').open('a') as stream:
        stream.write(now() + ' ' + code + (' ' + ident if ident else '') + '\n')


def save_record(c, record):
    path = Path(c['stateDir']) / (record['id'] + '.json')
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            json.dump(record, stream, ensure_ascii=False)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp)


def records(c):
    root = Path(c['stateDir'])
    result = {}
    for path in sorted(root.glob('*.json')) if root.exists() else []:
        if ID_RE.fullmatch(path.stem):
            result[path.stem] = load_json(path)
    return result


# ---------- последний вход ----------

ACCEPTED = re.compile(r'Accepted publickey for (\S+) from \S+ port \d+ \S+: \S+ (SHA256:[A-Za-z0-9+/]+)')


def login_times(c, wanted):
    """Последний вход по отпечатку из журнала sshd. None — журнал недоступен (честно «неизвестно»)."""
    found = {}
    sources = c.get('authLog')
    lines = []
    if sources:
        readable = False
        for name in sources:
            try:
                lines.extend(Path(name).read_text(errors='replace').splitlines())
                readable = True
            except OSError:
                pass
        if not readable:
            return None
    else:
        import grp
        groups = {grp.getgrgid(g).gr_name for g in os.getgroups() if g >= 0}
        if os.geteuid() != 0 and not groups & {'adm', 'systemd-journal', 'wheel'}:
            return None
        try:
            p = subprocess.run(['journalctl', '--no-pager', '-q', '-o', 'short-iso', '-t', 'sshd', '-t', 'sshd-session'],
                               capture_output=True, text=True, timeout=20)
            if p.returncode != 0:
                return None
            lines = p.stdout.splitlines()
        except (OSError, subprocess.TimeoutExpired):
            return None
    latest = {}
    for line in lines:
        match = ACCEPTED.search(line)
        if match and match.group(1) == c['workerUser'] and match.group(2) in wanted:
            tokens = line.split()
            stamp = tokens[0] if tokens and tokens[0][:1].isdigit() else ' '.join(tokens[:3])
            moment = stamp_time(stamp)
            previous = latest.get(match.group(2))
            # Самый поздний вход, а не последний прочитанный (журналы могут идти не по порядку).
            if previous is None or (moment is not None and (previous[0] is None or moment >= previous[0])):
                latest[match.group(2)] = (moment, stamp)
    return {fp: value[1] for fp, value in latest.items()}


def stamp_time(stamp):
    try:
        moment = dt.datetime.fromisoformat(stamp)
        return moment if moment.tzinfo else moment.astimezone()
    except ValueError:
        pass
    try:  # syslog «Nov 12 11:00:00» — без года и пояса: местное время, текущий год (или прошлый, если в будущем)
        current = dt.datetime.now().astimezone()
        moment = dt.datetime.strptime('%d %s' % (current.year, stamp), '%Y %b %d %H:%M:%S').astimezone()
        return moment.replace(year=current.year - 1) if moment > current + dt.timedelta(days=1) else moment
    except ValueError:
        return None


# ---------- команды ----------

def master_password(args):
    if not args.master_password_stdin:
        return None
    if sys.stdin.isatty():
        first = getpass.getpass('Мастер-пароль: ')
        require(first == getpass.getpass('Ещё раз: '), 'Пароли не совпали')
        value = first
    else:
        value = sys.stdin.readline()
        value = value.lstrip('﻿').rstrip('\n').rstrip('\r')
    require(value, 'Пустой мастер-пароль')
    _aes()
    return value


def keypair(c, ident):
    root = Path(c['stateDir'])
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    require(not root.is_symlink(), 'stateDir не должен быть symlink')
    trusted(root, 'stateDir')
    with tempfile.TemporaryDirectory(dir=root) as tmp:
        key = Path(tmp) / 'key'
        p = subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', LABEL + ident, '-f', str(key)],
                           capture_output=True, timeout=30)
        require(p.returncode == 0, 'ssh-keygen не создал ключ (вывод скрыт)')
        private = key.read_text()
        kind, blob = key.with_suffix('.pub').read_text().split()[:2]
    require(kind == 'ssh-ed25519', 'ssh-keygen вернул не ed25519')
    return private, kind + ' ' + blob


def folders_list(text):
    folders = [f for f in (text.split(',') if text else []) if f]
    for f in folders:
        require(re.fullmatch(r'[\w .-]+(?:/[\w .-]+)*', f) and all(x.strip() not in ('', '.', '..') for x in f.split('/')), 'Недопустимая папка: ' + f)
    return folders


def export(c, args, out=sys.stdout, err=sys.stderr):
    name = clean_name(args.name)
    require(args.happier == 'same' or re.fullmatch(r'new:.+', args.happier or ''), '--happier: same или new:Название')
    folders = folders_list(args.folders)
    master = master_password(args)
    values = {}
    server, vpn = common_sections(c, values, args.vpn == 'on')
    ident = secrets.token_hex(8)
    private, public = keypair(c, ident)
    values = {'server-key': private, **values}
    server['key'] = {'secret': 'server-key'}
    config = {'kind': CONFIG_KIND, 'schema': 1, 'device': {'name': name}, 'server': server}
    if vpn:
        config['vpn'] = vpn
    happier = {key: value for key, value in (c.get('happier') or {}).items() if key in ('serverUrl', 'webappUrl')}
    if args.happier == 'same':
        happier['mode'] = 'same'
        if (c.get('happier') or {}).get('account'):
            happier['label'] = clean_name(c['happier']['account'])
    else:
        happier.update(mode='new', label=clean_name(args.happier[4:]))
    config['happier'] = happier
    config['bridge'] = {'enabled': True, 'allowShell': False}
    if folders:
        config['disk'] = {'folders': folders}
    config['secrets'] = protect(values, master) if master else values
    text = json.dumps(config, ensure_ascii=False, indent=2) + '\n'
    target = folder = None
    if args.output:
        output = Path(args.output).absolute()
        folder = os.open(output.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            target = os.open(output.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=folder)
        except BaseException:
            os.close(folder)
            raise
    record = {'id': ident, 'name': name, 'createdUtc': now(), 'createdNs': time.time_ns(),
              'fingerprint': fingerprint(public.split()[1]), 'publicKey': public}
    added = False
    try:
        with locked(c):
            save_record(c, record)
            append_worker(c, c['workerAuthorizedKeys'], public + ' ' + LABEL + ident + ' ' + name)
            added = True
        if target is not None:
            with os.fdopen(os.dup(target), 'wb') as stream:
                stream.write(text.encode('utf-8'))
            os.fsync(target)
        else:
            out.write(text)
            out.flush()
        with locked(c):
            event(c, 'export.ok', ident)
    except BaseException:
        # Конфиг не дошёл до получателя — его ключ не должен оставаться действующим.
        try:
            with locked(c):
                if added:
                    remove_label(c, ident)
                record['failedUtc'] = now()
                save_record(c, record)
                event(c, 'export.failed', ident)
        except Exception:
            err.write('ВНИМАНИЕ: выдача ' + ident + ' не удалась, а ключ убрать не получилось: «remoteagents config revoke ' + ident + '».\n')
        if target is not None:
            with contextlib.suppress(OSError):
                mine, current = os.fstat(target), os.stat(output.name, dir_fd=folder, follow_symlinks=False)
                if (mine.st_dev, mine.st_ino) == (current.st_dev, current.st_ino):
                    os.unlink(output.name, dir_fd=folder)
        raise
    finally:
        if target is not None:
            os.close(target)
            os.close(folder)
    try:
        publish_sync(c)
    except Exception:
        err.write('Предупреждение: снимок автообновления не обновлён; выполните «remoteagents config sync».\n')
    err.write('Выдан конфиг ' + ident + ' «' + name + '». Ключ записан в authorized_keys с меткой ' + LABEL + ident + '.\n')
    if master:
        err.write('Секреты закрыты мастер-паролем. Пароль передавайте другим путём, не вместе с конфигом.\n')
    else:
        err.write('ВНИМАНИЕ: секреты (ключ доступа) в конфиге открытым текстом. Передавайте конфиг как пароль.\n')
    if args.output:
        err.write('Файл: ' + args.output + '\n')
    return ident


def list_rows(c):
    with locked(c):
        saved = records(c)
        text = read_worker(c, c['workerAuthorizedKeys'])
    active = {}
    for line in split_lines(text):
        parsed = parse_key_line(line)
        label = parsed and config_label(parsed[2])
        if label:
            active.setdefault(label[0], {'name': label[1], 'fingerprint': fingerprint(parsed[1]), 'order': len(active)})
    rows = []
    for ident in sorted(set(saved) | set(active), key=lambda i: (saved.get(i, {}).get('createdNs', 0), active.get(i, {}).get('order', 1 << 30), i)):
        record, line = saved.get(ident, {}), active.get(ident)
        state = 'действует' if line else ('отозван' if record.get('revokedUtc') else
                                          'выдача не удалась' if record.get('failedUtc') else 'ключа нет в authorized_keys')
        rows.append({'id': ident, 'name': record.get('name') or (line or {}).get('name', ''),
                     'createdUtc': record.get('createdUtc'), 'state': state,
                     'fingerprint': (line or record).get('fingerprint', '')})
    logins = login_times(c, {r['fingerprint'] for r in rows})
    for row in rows:
        row['lastLogin'] = None if logins is None else logins.get(row['fingerprint'], '')
    return rows, logins is not None


def show_list(c, as_json, out=sys.stdout):
    rows, journal = list_rows(c)
    if as_json:
        for row in rows:
            out.write(json.dumps(row, ensure_ascii=False) + '\n')
        return
    if not rows:
        out.write('Выданных конфигов нет.\n')
    for row in rows:
        login = 'неизвестно (журнал sshd недоступен)' if row['lastLogin'] is None else (row['lastLogin'] or 'нет в журнале')
        out.write('%s  %s\n    создан: %s; состояние: %s; последний вход: %s\n' % (
            row['id'], row['name'], row['createdUtc'] or 'неизвестно', row['state'], login))


def remove_label(c, ident):
    """Убрать из authorized_keys только строки с меткой ra-config:<id>; → (ключи удалённых строк, новый текст)."""
    result = {}

    def drop(old):
        kept, removed = [], []  # заново на каждую попытку replace_worker
        for line in split_lines(old):  # остальные строки — байт в байт
            parsed = parse_key_line(line)
            label = parsed and config_label(parsed[2])
            if label and label[0] == ident:
                removed.append(parsed[0] + ' ' + parsed[1])
            else:
                kept.append(line)
        result['removed'] = removed
        return ''.join(kept) if removed else old

    _, new = replace_worker(c, c['workerAuthorizedKeys'], drop)
    return result.get('removed', []), new


def revoke(c, ident, out=sys.stdout, err=sys.stderr):
    require(isinstance(ident, str) and ID_RE.fullmatch(ident), 'id — 16 шестнадцатеричных символов из «config list»')
    with locked(c):
        saved = records(c).get(ident)
        removed, new = remove_label(c, ident)
        require(removed or saved, 'Конфиг ' + ident + ' не найден')
        if saved and not saved.get('revokedUtc'):
            saved['revokedUtc'] = now()
            save_record(c, saved)
        event(c, 'revoke.ok' if removed else 'revoke.absent', ident)
    others = []
    for line in split_lines(new):
        parsed = parse_key_line(line)
        if parsed and parsed[0] + ' ' + parsed[1] in removed:
            others.append(parsed[2] or 'без метки')
    if removed:
        out.write('Отозван ' + ident + ': ключ удалён из authorized_keys. Новые входы этим ключом запрещены.\n')
    else:
        out.write('Строки ' + LABEL + ident + ' в authorized_keys уже нет; запись отмечена отозванной.\n')
    out.write('Честно: уже открытые SSH-сессии этим ключом не обрываются, пока компьютер сам не отключится '
              '(закрыть их можно только завершив сессии рабочего пользователя целиком).\n')
    if others:
        err.write('ВНИМАНИЕ: этот же ключ записан ещё под меткой: ' + '; '.join(others) + '. По этим строкам доступ сохраняется.\n')


def sync_document(c):
    values = {}
    server, vpn = common_sections(c, values, bool(c.get('vpnBootstrap')))
    config = {'kind': CONFIG_KIND, 'schema': 1, 'server': server}
    if vpn:
        vpn.pop('enabled', None)  # включать ли VPN — выбор самого компьютера
        config['vpn'] = vpn
    config['secrets'] = values
    return {'kind': SYNC_KIND, 'schema': 1, 'generatedUtc': now(), 'config': config}


def publish_sync(c):
    document = sync_document(c)
    body = json.dumps(document['config'], ensure_ascii=False, sort_keys=True)
    document['revision'] = hashlib.sha256(body.encode('utf-8')).hexdigest()
    raw = json.dumps(document, ensure_ascii=False) + '\n'
    require(len(raw.encode('utf-8')) <= 1024 * 1024, 'Снимок автообновления больше 1 МиБ')

    def update(old):
        try:
            if json.loads(old).get('revision') == document['revision']:
                return old  # ничего не поменялось: generatedUtc не трогаем
        except ValueError:
            pass
        return raw
    with locked(c):
        replace_worker(c, c['syncFile'], update)
        event(c, 'sync.ok')


def devices(c, out=sys.stdout):
    spec = importlib.util.spec_from_file_location('ra_node_catalog', ROOT / 'server_node_catalog.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    hosts = {}
    for record in module.records(c['nodeCatalog'], worker_home(c)):
        row = hosts.setdefault(record['hostId'], {'hostId': record['hostId'], 'deviceName': '', 'projects': []})
        name = module.device_name(record.get('deviceName'), '')
        # Имя из записи управления (Bridge) главнее; затем любое содержательное; hostId — последним.
        if name and (record.get('controlOnly') is True or not row['deviceName']):
            row['deviceName'] = name
        row['projects'].append(record['projectId'])
    for row in hosts.values():
        row['deviceName'] = row['deviceName'] or row['hostId']
    if not hosts:
        out.write('Зарегистрированных компьютеров нет (мост ещё ни разу не подключался).\n')
    for row in hosts.values():
        out.write(json.dumps(row, ensure_ascii=False) + '\n')


def main(argv=None):
    os.umask(0o077)
    parser = argparse.ArgumentParser(prog='remoteagents config')
    parser.add_argument('--config', help='настройки выдачи (по умолчанию ' + DEFAULT_CONFIG + ' или ~/' + USER_CONFIG + ')')
    sub = parser.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('export', help='выдать полный конфиг для ещё одного компьютера')
    p.add_argument('--name', required=True)
    p.add_argument('--master-password-stdin', action='store_true')
    p.add_argument('--vpn', choices=('on', 'off'))
    p.add_argument('--happier', default='same')
    p.add_argument('--folders', default='')
    p.add_argument('--output')
    p = sub.add_parser('list', help='выданные конфиги и последний вход')
    p.add_argument('--json', action='store_true')
    sub.add_parser('revoke', help='отозвать ключ выданного конфига').add_argument('id')
    sub.add_parser('sync', help='опубликовать снимок автообновления')
    sub.add_parser('devices', help='компьютеры с названиями из реестра моста')
    args = parser.parse_args(argv)
    c = settings(args.config)
    if args.cmd == 'export':
        if args.vpn is None:
            args.vpn = 'on' if c.get('vpnBootstrap') else 'off'
        export(c, args)
    elif args.cmd == 'list':
        show_list(c, args.json)
    elif args.cmd == 'revoke':
        revoke(c, args.id)
    elif args.cmd == 'sync':
        publish_sync(c)
        print('Снимок автообновления опубликован: ' + c['syncFile'])
    elif args.cmd == 'devices':
        devices(c)


if __name__ == '__main__':
    try:
        main()
    except Error as exc:
        print('Ошибка: ' + str(exc), file=sys.stderr)
        sys.exit(1)
    except KeyError as exc:
        print('Ошибка: в настройках нет поля ' + str(exc), file=sys.stderr)
        sys.exit(1)
    except OSError as exc:
        print('Ошибка: файл недоступен: ' + str(exc.filename or ''), file=sys.stderr)
        sys.exit(1)
    except Exception as exc:
        # Детали скрыты: в них могли бы оказаться фрагменты секретов.
        print('Ошибка: ' + type(exc).__name__ + ' (детали скрыты)', file=sys.stderr)
        sys.exit(1)
