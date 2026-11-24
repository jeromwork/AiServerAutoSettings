"""Подготовка нового Диска и регистрация его устройства без действий при импорте."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET


class JoinError(Exception):
    """Ошибка подключения Диска, которую можно показать человеку."""


def _write(path, data):
    path = Path(path)
    temporary = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=path.name + '.', suffix='.tmp')
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data.encode('utf-8') if isinstance(data, str) else data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except OSError:
        raise JoinError('Не удалось сохранить данные Диска.') from None
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)


def device_id(cert_pem_path):
    try:
        pem = Path(cert_pem_path).read_text(encoding='ascii')
        match = re.search(r'-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----', pem, re.S)
        if not match:
            raise ValueError
        der = base64.b64decode(''.join(match[1].split()), validate=True)
        if not der:
            raise ValueError
    except (OSError, ValueError, IndexError):
        raise JoinError('Не удалось прочитать личность Диска.') from None
    alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    raw = base64.b32encode(hashlib.sha256(der).digest()).decode('ascii').rstrip('=')
    checked = ''
    for offset in range(0, 52, 13):
        part = raw[offset:offset + 13]
        factor, total = 1, 0
        for char in part:
            value = factor * alphabet.index(char)
            factor = 2 if factor == 1 else 1
            total += value // 32 + value % 32
        checked += part + alphabet[(32 - total % 32) % 32]
    return '-'.join(checked[i:i + 7] for i in range(0, 56, 7))


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def prepare_config(state_dir, gui_port, listen_port):
    try:
        root = ET.parse(Path(state_dir) / 'config.xml').getroot()
        for folder in root.findall('folder'):
            root.remove(folder)
        gui, options = root.find('gui'), root.find('options')
        if gui is None or options is None:
            raise ValueError
        gui.set('tls', 'false')

        def put(parent, name, value):
            for old in parent.findall(name):
                parent.remove(old)
            ET.SubElement(parent, name).text = str(value)

        put(gui, 'address', f'127.0.0.1:{gui_port}')
        for name in ('globalAnnounceEnabled', 'localAnnounceEnabled', 'relaysEnabled', 'natEnabled',
                     'crashReportingEnabled', 'startBrowser'):
            put(options, name, 'false')
        for name, value in {'listenAddress': f'tcp://127.0.0.1:{listen_port}',
                            'autoUpgradeIntervalH': 0, 'reconnectionIntervalS': 10, 'urAccepted': -1}.items():
            put(options, name, value)
        _write(Path(state_dir) / 'config.xml', ET.tostring(root, encoding='utf-8', xml_declaration=True))
    except (OSError, ValueError, ET.ParseError):
        raise JoinError('Не удалось подготовить настройки Диска.') from None


def _needs_prepare(config_path):
    try:
        root = ET.parse(config_path).getroot()
        options = root.find('options')
        if options is None:
            return True
        for name in ('globalAnnounceEnabled', 'relaysEnabled', 'natEnabled'):
            val = (options.findtext(name) or '').strip().lower()
            if val != 'false':
                return True
        return False
    except (OSError, ET.ParseError):
        return True


def _creationflags():
    if os.name == 'nt':
        from . import procs
        return procs.NO_WINDOW
    return 0


def make_identity(exe, state_dir, log):
    state = Path(state_dir)
    config = state / 'config.xml'
    if config.exists():
        if _needs_prepare(config):
            gui_port, listen_port = free_port(), free_port()
            while listen_port == gui_port:
                listen_port = free_port()
            prepare_config(state, gui_port, listen_port)
            if log:
                log('Создана личность Диска.')
        return device_id(state / 'cert.pem')
    try:
        state.mkdir(parents=True, exist_ok=True)
        argv = [str(exe), 'syncthing', 'generate', '--home', str(state), '--no-port-probing']
        result = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True,
                                timeout=60, creationflags=_creationflags())
        if result.returncode and b'unknown flag' in (result.stdout + result.stderr).lower():
            result = subprocess.run(argv[:-1], stdin=subprocess.DEVNULL, capture_output=True,
                                    timeout=60, creationflags=_creationflags())
        if result.returncode:
            raise JoinError('Не удалось создать личность Диска.')
        gui_port, listen_port = free_port(), free_port()
        while listen_port == gui_port:
            listen_port = free_port()
        prepare_config(state, gui_port, listen_port)
        identity = device_id(state / 'cert.pem')
    except (OSError, subprocess.SubprocessError):
        raise JoinError('Не удалось создать личность Диска.') from None
    if log:
        log('Создана личность Диска.')
    return identity


def server_command(device_id, device_name):
    payload = base64.b64encode(json.dumps({'deviceId': device_id, 'deviceName': device_name},
                                        ensure_ascii=False).encode('utf-8')).decode('ascii')
    return ('bash ~/.local/share/remote-disk/server-disk.sh add-device ' + payload +
            ' >/dev/null && cat ~/.local/share/remote-disk/ports.json && echo && '
            '~/.local/share/remote-disk/bin/syncthing device-id --home ~/.local/share/remote-disk')


def parse_server_reply(stdout):
    listen, identity = None, None
    if isinstance(stdout, bytes):
        stdout = stdout.decode('utf-8', 'replace')
    for line in stdout.splitlines():
        line = line.strip()
        if line.startswith('{'):
            try:
                value = json.loads(line).get('listen')
                if type(value) is int and 1 <= value <= 65535:
                    listen = value
            except (ValueError, AttributeError):
                pass
        if re.fullmatch(r'[A-Z2-7]{7}(?:-[A-Z2-7]{7}){7}', line):
            identity = line
    if listen is None or identity is None:
        raise JoinError('Сервер не сообщил данные Диска.')
    return {'deviceId': identity, 'listen': listen}


def register(ctx, device_id, device_name, log):
    channel = ctx.rounds.channel or {}
    path = channel.get('path')
    port = ctx.singbox.ports.get(path) or ctx.singbox.ports.get('chan')
    if not channel or not port:
        raise JoinError('Нет канала к серверу.')
    s = ctx.settings
    argv = [s.ssh, '-T', '-F', 'NUL' if os.name == 'nt' else '/dev/null', '-p', str(port),
            '-i', s.key, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
            '-o', 'UserKnownHostsFile="%s"' % s.known_hosts.replace('\\', '/'),
            '-o', 'GlobalKnownHostsFile=none', '-o', 'StrictHostKeyChecking=yes',
            '-o', 'HostKeyAlias=' + s.server, '-o', 'ProxyCommand=none', '-o', 'ProxyJump=none',
            '-o', 'ConnectionAttempts=1', '-o', 'LogLevel=ERROR',
            '-o', 'ServerAliveInterval=3', '-o', 'ServerAliveCountMax=3',
            '%s@127.0.0.1' % s.login, server_command(device_id, device_name)]
    try:
        result = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True,
                                timeout=150, creationflags=_creationflags())
    except (OSError, subprocess.SubprocessError):
        raise JoinError('Не удалось зарегистрировать ПК на сервере Диска.') from None
    if result.returncode:
        lines = result.stderr.decode('utf-8', 'replace').strip().splitlines()
        raise JoinError('Сервер не принял ПК: ' + (lines[-1][:200] if lines else 'нет ответа.'))
    reply = parse_server_reply(result.stdout)
    from . import journal
    journal.log('disk', 'join-server', reply)
    if log:
        log('ПК зарегистрирован на сервере Диска.')
    return reply


def _base(base=None):
    return os.path.expandvars(os.path.expanduser(str(base or Path(os.environ.get('USERPROFILE') or Path.home()) / 'Disk')))


def save_server(disk_home, reply, base=None):
    home = Path(disk_home)
    _write(home / 'server.json', json.dumps({'deviceId': reply['deviceId'], 'listen': reply['listen']}))
    _write(home / 'server.txt', reply['deviceId'])
    saved = Path(os.environ.get('LOCALAPPDATA') or Path.home() / 'AppData' / 'Local') / 'RemoteDisk' / 'base.txt'
    if not saved.exists():
        _write(saved, _base(base))


def api_info(state_dir):
    try:
        root = ET.parse(Path(state_dir) / 'config.xml').getroot()
        address = (root.findtext('gui/address') or '').strip()
        key = (root.findtext('gui/apikey') or '').strip()
        match = re.fullmatch(r'127\.0\.0\.1:([0-9]{1,5})', address)
        if not match or not 1 <= int(match[1]) <= 65535 or not key:
            raise ValueError
        return 'http://' + address, key
    except (OSError, ValueError, ET.ParseError):
        raise JoinError('Неверные локальные настройки Диска.') from None


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def api(state_dir, method, path, body=None, timeout=10):
    try:
        base_url, key = api_info(state_dir)
        data = None if body is None else json.dumps(body, ensure_ascii=False).encode('utf-8')
        request = urllib.request.Request(base_url + '/rest/' + path.lstrip('/'), data=data,
                                         headers={'X-API-Key': key, 'Content-Type': 'application/json'}, method=method)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
        with opener.open(request, timeout=timeout) as response:
            raw = response.read()
        return json.loads(raw) if raw.strip() else None
    except urllib.error.HTTPError as error:
        raise JoinError('Диск не отвечает: ошибка HTTP %d.' % error.code) from None
    except (OSError, ValueError, TypeError, JoinError):
        # Не включаем ответ, заголовки и исключение запроса: в них может быть ключ.
        raise JoinError('Диск не отвечает: не удалось выполнить локальный запрос.') from None


def wait_api(state_dir, tries=40, pause=0.25):
    for attempt in range(tries):
        try:
            status = api(state_dir, 'GET', 'system/status')
            if isinstance(status, dict) and status.get('myID'):
                return status['myID']
        except JoinError:
            pass
        if attempt + 1 < tries:
            time.sleep(pause)
    raise JoinError('Диск не запустился.')


def set_server_device(state_dir, server_id, sync_port):
    address = 'tcp://127.0.0.1:%d' % int(sync_port)
    route = 'config/devices/' + urllib.parse.quote(server_id, safe='')
    devices = api(state_dir, 'GET', 'config/devices')
    previous = next((device for device in devices if device.get('deviceID') == server_id), None)
    if previous is None:
        device = api(state_dir, 'GET', 'config/defaults/device')
        device.update(deviceID=server_id, name='RemoteDisk Server', addresses=[address], autoAcceptFolders=False)
        api(state_dir, 'PUT', route, device)
    else:
        patch = {}
        if previous.get('addresses') != [address]:
            patch['addresses'] = [address]
        if previous.get('autoAcceptFolders'):
            patch['autoAcceptFolders'] = False
        if patch:
            api(state_dir, 'PATCH', route, patch)


def wanted_folders(cfg_disk):
    folders = cfg_disk.get('folders') if isinstance(cfg_disk, dict) else None
    if not isinstance(folders, list):
        return []
    result, seen = [], set()
    for item in folders[:256]:
        folder = {'id': item} if isinstance(item, str) else item
        identity = folder.get('id') if isinstance(folder, dict) else None
        if (not isinstance(identity, str) or not re.fullmatch(r'[A-Za-z0-9._-]+', identity)
                or identity in ('.', '..')):
            from . import journal
            journal.log('disk', 'join-folder-skip', {'reason': 'недопустимый ID папки'})
            continue
        if identity in seen:
            continue
        path = folder.get('path')
        if path is not None and not isinstance(path, str):
            from . import journal
            journal.log('disk', 'join-folder-skip', {'id': identity, 'reason': 'путь должен быть строкой'})
            continue
        value = {'id': identity}
        if path:
            value['path'] = path
        result.append(value)
        seen.add(identity)
    return result


def _offered_id(pending, identity, server_id):
    for actual, details in pending.items():
        offered = (details.get('offeredBy') or {}).get(server_id)
        if isinstance(offered, dict) and (actual == identity or offered.get('label') == identity):
            return actual
    return None


def _has_folder(folders, identity, server_id):
    return any(folder.get('id') == identity or
               (folder.get('label') == identity and
                any(device.get('deviceID') == server_id for device in folder.get('devices', [])))
               for folder in folders)


def _is_placeholder_ini(ini_path):
    try:
        path = Path(ini_path)
        if not path.is_file():
            return False
        try:
            content = path.read_text(encoding='utf-8-sig')
        except UnicodeDecodeError:
            try:
                content = path.read_text(encoding='utf-16')
            except UnicodeDecodeError:
                content = path.read_text(encoding='latin-1', errors='replace')
        section = ''
        values = {}
        for line in content.splitlines():
            line = line.strip()
            if line.startswith((';', '#')):
                continue
            if line.startswith('[') and line.endswith(']'):
                section = line[1:-1].strip()
                continue
            if section.lower() == 'remoteagents' and '=' in line:
                key, val = line.split('=', 1)
                values[key.strip().lower()] = val.strip()
        return values.get('owner') == 'RemoteAgents.Disk.v2' and values.get('placeholder') == '1'
    except OSError:
        return False


def accept_folders(state_dir, server_id, wanted, base, log, offer_timeout=30):
    result = {'accepted': [], 'waiting': [], 'skipped': []}

    def skip(identity, reason):
        result['skipped'].append({'id': identity, 'reason': reason})
        if log:
            log('Папка ' + identity + ' пропущена: ' + reason + '.')

    if not wanted:
        return result
    existing = api(state_dir, 'GET', 'config/folders')
    todo = []
    for folder in wanted:
        if _has_folder(existing, folder['id'], server_id):
            skip(folder['id'], 'уже подключена')
        else:
            todo.append(folder)
    if not todo:
        return result
    deadline, offers = time.monotonic() + offer_timeout, {}
    route = 'cluster/pending/folders?' + urllib.parse.urlencode({'device': server_id})
    while True:
        pending = api(state_dir, 'GET', route, timeout=max(0.1, min(10, deadline - time.monotonic())))
        for folder in todo:
            actual = _offered_id(pending, folder['id'], server_id)
            if actual:
                offers[folder['id']] = actual
        remaining = deadline - time.monotonic()
        if len(offers) == len(todo) or remaining <= 0:
            break
        time.sleep(min(1, remaining))
    my_id = None
    for folder in todo:
        identity = folder['id']
        actual = offers.get(identity)
        # Человек мог принять папку в трее, пока мы ждали предложения.
        existing = api(state_dir, 'GET', 'config/folders')
        if (_has_folder(existing, identity, server_id) or
                (actual and any(item.get('id') == actual for item in existing))):
            skip(identity, 'уже подключена')
            continue
        if not actual:
            result['waiting'].append(identity)
            if log:
                log('Ожидает сервер: папка ' + identity + ' пока не предложена.')
            continue
        path = Path(os.path.abspath(os.path.expandvars(os.path.expanduser(
            folder.get('path') or os.path.join(_base(base), identity)))))
        try:
            if any(part.is_symlink() or (os.name == 'nt' and part.is_junction()) for part in (path, *path.parents)):
                skip(identity, 'ссылки в пути запрещены')
                continue
            if path.exists():
                if not path.is_dir():
                    skip(identity, 'путь занят файлом')
                    continue
                with os.scandir(path) as scanner:
                    entries = list(scanner)
                if entries:
                    if (len(entries) != 1 or
                            entries[0].name.lower() != 'desktop.ini' or
                            not _is_placeholder_ini(entries[0].path)):
                        skip(identity, 'папка не пуста')
                        continue
            config = api(state_dir, 'GET', 'config/defaults/folder')
            if my_id is None:
                my_id = api(state_dir, 'GET', 'system/status').get('myID')
                if not my_id:
                    raise JoinError('Диск не сообщил ID устройства.')
            config.update(id=actual, label=identity, path=str(path), type='sendreceive',
                          fsWatcherEnabled=True, fsWatcherDelayS=2, maxConflicts=-1,
                          devices=[{'deviceID': my_id}, {'deviceID': server_id}],
                          versioning={'type': 'staggered', 'params': {'maxAge': '2592000', 'cleanInterval': '3600'}})
            path.mkdir(parents=True, exist_ok=True)
            _write(path / '.stignore-remoteagents', _IGNORE_RULES)
            _write(path / '.stignore', '#include .stignore-remoteagents\n')
            api(state_dir, 'POST', 'config/folders', config)
        except OSError:
            raise JoinError('Не удалось подготовить папку Диска: ' + identity + '.') from None
        result['accepted'].append(identity)
        if log:
            log('Папка ' + identity + ' подключена к Диску.')
    return result


def finish(disk_home, state_dir, server, sync_port, cfg_disk, base, log):
    wait_api(state_dir)
    server_id = server['deviceId']
    set_server_device(state_dir, server_id, sync_port)
    folders = accept_folders(state_dir, server_id, wanted_folders(cfg_disk), base, log)
    result = {'stage': 'folders' if folders['waiting'] else 'done', 'serverId': server_id,
              'accepted': folders['accepted'], 'waiting': folders['waiting'], 'time': int(time.time())}
    _write(Path(disk_home) / 'join.json', json.dumps(result, ensure_ascii=False))
    return result


def needs_finish(disk_home):
    path = Path(disk_home) / 'join.json'
    try:
        state = json.loads(path.read_text(encoding='utf-8-sig'))
    except FileNotFoundError:
        return False
    except (OSError, ValueError):
        return True
    return not isinstance(state, dict) or state.get('stage') != 'done'


# Те же обязательные исключения, что при установке нового Диска.
_IGNORE_RULES = """// RemoteDisk: не передаём секреты и то, что генерируется
(?i)/.stignore-remoteagents
(?i).env*
(?i).npmrc
(?i).pypirc
(?i).netrc
(?i)auth.json
(?i)credentials*
(?i)secrets*
(?i)id_rsa*
(?i)id_ed25519*
(?i)id_ecdsa*
(?i)id_dsa*
(?i)*.key
(?i)*.keystore
(?i)*.jks
(?i)*.p8
(?i)*.p12
(?i)*.pfx
(?i)local.properties
(?i).git
(?i).ssh
(?i).codex
(?i).claude
(?i).tools
(?i)node_modules
(?i)vendor
(?i).gradle
(?i).next
(?i).nuxt
(?i).output
(?i).cache
(?i).turbo
(?i).dart_tool
(?i).cxx
(?i)build
(?i)dist
(?i)target
(?i)obj
(?i)coverage
(?i).idea
(?i).vscode
(?i)android-sdk
(?i)*.log
(?i)*.sqlite*
(?i)*.db*
(?i)*.dump
(?i)*.bak
// Laravel: загруженные файлы и кэш в storage проекта не передаём
(?i)/storage/app
(?i)/storage/framework
// Оформление Проводника принадлежит этому компьютеру; вложенные desktop.ini не трогаем
(?i)/desktop.ini
// Дополнительные обязательные имена: ключи, окружения Python и локальные дампы
(?i)*.pem
(?i)*.crt
(?i)*.crt?
(?i)token*.json
(?i).venv
(?i)venv
(?i)__pycache__
(?i)*.sql
(?i)*.sql.gz
(?i)*.sql.bz2
(?i)*.sql.xz
(?i)*.sql.zst
(?i)*.sql.zip
"""
