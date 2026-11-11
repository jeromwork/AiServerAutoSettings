#!/usr/bin/env python3
"""One-use OpenSSH enrollment. No SSH/crypto implementation: OpenSSH + flock.

All deployment locations/identities come from config. `sandbox` never manages
accounts or sudoers; tests run the same enrollment transaction under one UID.
"""
import argparse
import base64
import contextlib
import datetime as dt
import fcntl
import http.server
import io
import signal
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zipfile

DEFAULT_CONFIG = '/etc/remoteagents/invite/config.json'


class Error(Exception):
    pass


def require(ok, message):
    if not ok:
        raise Error(message)


def run(args, **kw):
    p = subprocess.run([str(x) for x in args], capture_output=True, timeout=60, **kw)
    require(p.returncode == 0, 'Не выполнена команда ' + Path(args[0]).name + ' (вывод скрыт)')
    return p.stdout


def save(path, value, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(value if isinstance(value, str) else json.dumps(value, ensure_ascii=False) + '\n')
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def load(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig').replace('\r', ''))


def config(path):
    c = load(path)
    require(c.get('schema') == 1 and c.get('version') == 1, 'Неизвестная схема настроек')
    require(isinstance(c.get('sandbox', False), bool), 'sandbox должен быть логическим значением')
    c['_file'] = str(Path(path).resolve())
    for field in ('workerUser', 'enrollUser'):
        require(re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', c[field]), 'Некорректное имя пользователя')
    for field in ('stateDir', 'workerAuthorizedKeys', 'enrollAuthorizedKeys', 'releaseExe', 'enrollHelper'):
        require(Path(c[field]).is_absolute() and not re.search(r'[\s"\\]', c[field]), 'Нужен абсолютный путь без пробелов: ' + field)
    require(re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9.:-]{0,252}', c['serverAddress']), 'Некорректный адрес')
    require(1 <= c['serverPort'] <= 65535, 'Некорректный порт')
    require(c.get('hostKeys'), 'Настройте pinning ключей хоста')
    for key in c['hostKeys']:
        require(re.fullmatch(r'(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/=]+', key), 'Некорректный ключ хоста')
    require(isinstance(c.get('routes'), list) and c['routes'], 'Настройте маршруты')
    if not c.get('sandbox'):
        require(c['workerUser'] != c['enrollUser'] and c['workerUser'] != 'root' and c['enrollUser'] != 'root', 'Служебный и рабочий пользователь должны быть разными, не root')
        require(os.geteuid() == 0, 'Команду выполняет администратор сервера (root)')
        # sudo helper always reads this root-owned file, never caller-controlled env.
        for p in (Path(path), *Path(path).resolve().parents):
            require(p.stat().st_uid == 0 and p.stat().st_mode & 0o022 == 0, 'Конфиг и предки должны принадлежать root без записи другим')
    return c


@contextlib.contextmanager
def locked(c):
    directory = Path(c['stateDir'])
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (directory / 'invite.lock').open('a') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        yield directory


def event(c, code):
    # Fixed codes only; no keys, URLs, passwords, labels, or SSH stderr.
    directory = Path(c['stateDir'])
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (directory / 'invite-events.log').open('a') as f:
        f.write(dt.datetime.now(dt.timezone.utc).isoformat() + ' ' + code + '\n')


def safe_id(value):
    require(bool(re.fullmatch('[a-f0-9]{32}', value)), 'Некорректный id')
    return value


def entry(c, ident):
    return Path(c['stateDir']) / (safe_id(ident) + '.json')


def remove_pass(c, ident):
    p = Path(c['enrollAuthorizedKeys'])
    lines = p.read_text().splitlines() if p.exists() else []
    save(p, ''.join(line + '\n' for line in lines if not line.endswith(' ra-invite:' + ident)), 0o644 if not c.get('sandbox') else 0o600)


def public_key(raw):
    # Permit exactly one trailing newline; a second key/blank line/options is an error.
    text = raw.decode('ascii').replace('\r\n', '\n')
    require(len(raw) <= 2048 and bool(re.fullmatch(r'ssh-ed25519 [A-Za-z0-9+/=]+(?: [^\r\n]*)?\n?', text)), 'Ожидается ровно один открытый ключ ed25519')
    fields = text.strip().split()
    blob = base64.b64decode(fields[1], validate=True)
    expected = struct.pack('>I', 11) + b'ssh-ed25519' + struct.pack('>I', 32)
    require(len(blob) == 51 and blob.startswith(expected), 'Некорректный ключ ed25519')
    return 'ssh-ed25519 ' + base64.b64encode(blob).decode()


def enroll(c, ident, raw):
    key = public_key(raw)
    with locked(c):
        p = entry(c, ident)
        require(p.exists(), 'Приглашение отозвано или не найдено')
        data = load(p)
        require(data['status'] in ('open', 'reserved'), 'Приглашение уже использовано или отозвано')
        require(data['expiresEpoch'] > time.time(), 'Срок приглашения истёк')
        require(data.get('reservedKey', key) == key, 'Приглашение уже используется другим компьютером')
        # Write-ahead reservation makes a retry after a crash authorize ONLY this key.
        data.update(status='reserved', reservedKey=key)
        save(p, data)
        auth = Path(c['workerAuthorizedKeys'])
        # Walk with openat/O_NOFOLLOW: a worker may rename .ssh while sudo runs.
        # Never follow a symlink or reopen a previously verified path as root.
        parent = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
        try:
            for component in auth.parent.parts[1:]:
                try:
                    child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
                except FileNotFoundError:
                    os.mkdir(component, mode=0o700, dir_fd=parent)
                    child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
                os.close(parent)
                parent = child
            fd = os.open(auth.name, os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=parent)
            try:
                require(os.fstat(fd).st_nlink == 1, 'authorized_keys не должен быть hardlink')
                with os.fdopen(os.dup(fd), 'r') as source:
                    old = source.read()
                line = key + ' ra-device:' + data['name']
                if line not in old.splitlines():
                    os.write(fd, (('' if not old or old.endswith('\n') else '\n') + line + '\n').encode())
                    os.fsync(fd)
                if not c.get('sandbox'):
                    user = pwd.getpwnam(c['workerUser'])
                    os.fchown(fd, user.pw_uid, user.pw_gid)
                    os.fchown(parent, user.pw_uid, user.pw_gid)
            finally:
                os.close(fd)
        finally:
            os.close(parent)
        data.update(status='used', usedUtc=dt.datetime.now(dt.timezone.utc).isoformat())
        data.pop('reservedKey', None)
        save(p, data)
        remove_pass(c, ident)
        event(c, 'enroll.ok')
    return {'ok': True, 'id': ident}


def provision(c):
    if c.get('sandbox'):
        return
    # Account has a locked password. /bin/sh is needed for sshd forced commands;
    # it has NO unrestricted authorized key. Never use nologin (it blocks enrollment).
    for source in (Path(__file__).resolve(), *Path(__file__).resolve().parents):
        require(source.stat().st_uid == 0 and source.stat().st_mode & 0o022 == 0, 'Сначала установите код в каталог root без записи другим')
    helper = Path(c['enrollHelper'])
    require(helper.parent.stat().st_uid == 0 and helper.parent.stat().st_mode & 0o022 == 0, 'Каталог helper должен быть защищён root')
    save(helper, '#!/bin/sh\n[ "$#" = 1 ] || exit 1\nexec /usr/bin/python3 -I ' + shlex.quote(str(Path(__file__).resolve())) + ' --config ' + shlex.quote(c['_file']) + ' enroll "$1"\n', 0o755)
    try:
        account = pwd.getpwnam(c['enrollUser'])
        require(account.pw_dir == c['enrollHome'] and account.pw_shell == '/bin/sh' and account.pw_uid != 0, 'Существующий enroll-пользователь имеет другую конфигурацию')
    except KeyError:
        run(['useradd', '--system', '--create-home', '--home-dir', c['enrollHome'], '--shell', '/bin/sh', '--password', '*', c['enrollUser']])
    # Do not silently reuse an ordinary account with a usable password.
    password_status = run(['passwd', '--status', c['enrollUser']]).decode().split()
    require(len(password_status) >= 2 and password_status[1] == 'L', 'Служебный пользователь должен иметь заблокированный пароль')
    require(not Path(c['enrollHome']).is_symlink(), 'Служебный HOME не должен быть symlink')
    os.chown(c['enrollHome'], 0, 0)
    os.chmod(c['enrollHome'], 0o755)
    # Public keys readable by service UID; directory is root-owned and not writable by it.
    auth = Path(c['enrollAuthorizedKeys'])
    require(auth == Path(c['enrollHome']) / '.ssh/authorized_keys', 'Используйте стандартный authorized_keys enroll-пользователя')
    require(not Path(c['enrollHome']).is_symlink() and not auth.parent.is_symlink() and not auth.is_symlink(), 'Служебные пути не должны быть symlink')
    if auth.exists():
        for line in auth.read_text().splitlines():
            require(line.startswith('restrict,expiry-time=') and 'ra-invite:' in line and c['enrollHelper'] in line, 'В служебном authorized_keys есть посторонний ключ; нужна проверка администратора')
    auth.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    os.chown(auth.parent, 0, 0)
    os.chmod(auth.parent, 0o755)
    rule = c['enrollUser'] + ' ALL=(root) NOPASSWD: ' + str(helper) + ' *\n'
    rule_path = Path(c['sudoersFile'])
    with tempfile.NamedTemporaryFile(mode='w', dir=rule_path.parent, delete=False) as f:
        f.write(rule)
        candidate = f.name
    try:
        run(['visudo', '-cf', candidate])
        save(rule_path, rule, 0o440)
    finally:
        os.unlink(candidate)


def routes(c):
    result = json.loads(json.dumps(c['routes']))
    # Settings contain paths only; credentials are read from separate private files.
    for r in result:
        require(r.get('kind') in ('direct', 'proxy', 'hop'), 'Неизвестный маршрут')
        hop = r.get('hop', {})
        require('privateKey' not in hop and 'password' not in hop, 'Секрет маршрута хранится отдельным файлом, в конфиге только путь')
        for src, dst in (('keyFile', 'privateKey'), ('passwordFile', 'password')):
            if hop.get(src):
                p = Path(hop.pop(src))
                require(p.stat().st_mode & 0o077 == 0, 'Секрет маршрута должен иметь права 0600')
                hop[dst] = p.read_text().replace('\r', '')
        require(not hop.get('ssh') or hop.get('hostKey'), 'Для промежуточного SSH-сервера нужен hostKey')
    return result


def create(c, args):
    require(0 < args.hours <= 720, 'Срок: больше нуля, максимум 720 часов')
    require(0 < len(args.name) <= 80 and not re.search(r'[\x00-\x1f\x7f]', args.name), 'Некорректное имя')
    require(args.happier == 'same' or bool(re.fullmatch(r'new:[^\x00-\x1f\x7f]{1,80}', args.happier)), 'Happier: same или new:ИМЯ')
    folders = args.folders.split(',') if args.folders else []
    require(all(re.fullmatch(r'[\w .-]+(?:/[\w .-]+)*', f) and all(x not in ('.', '..') for x in f.split('/')) for f in folders), 'Недопустимая папка')
    exe = Path(c['releaseExe'])
    require(exe.is_file() and exe.read_bytes()[:2] == b'MZ', 'Нет release/RemoteAgents.exe; сначала соберите EXE')
    resolved_routes = routes(c)
    ident = secrets.token_hex(16)
    expiry = time.time() + args.hours * 3600
    stamp = dt.datetime.fromtimestamp(expiry, dt.timezone.utc)
    invite = dict(schema=1, id=ident, name=args.name, serverAddress=c['serverAddress'], serverPort=c['serverPort'],
                  hostKeys=c['hostKeys'], workerUser=c['workerUser'], enrollUser=c['enrollUser'], routes=resolved_routes,
                  expiresUtc=stamp.isoformat(), happier=args.happier, folders=folders, happierAccount=c.get('happierAccount', ''))
    output = Path(c['outputDir'])
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(output, 0o700)
    with locked(c):
        provision(c)
        with tempfile.TemporaryDirectory(dir=c['stateDir']) as tmp:
            key = Path(tmp) / 'pass'
            run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', key])
            invite['passKey'] = key.read_text()
            pub = public_key(key.with_suffix('.pub').read_bytes())
        command = ('' if c.get('sandbox') else '/usr/bin/sudo -n ') + c['enrollHelper'] + ' ' + ident
        if c.get('sandbox'):
            command = '/usr/bin/python3 -I ' + shlex.quote(str(Path(__file__).resolve())) + ' --config ' + shlex.quote(c['_file']) + ' enroll ' + ident
        require('"' not in command and '\\' not in command and '\n' not in command, 'Неподдерживаемый путь helper')
        line = 'restrict,expiry-time="' + stamp.strftime('%Y%m%d%H%M%SZ') + '",command="' + command + '" ' + pub + ' ra-invite:' + ident + '\n'
        save(entry(c, ident), dict(id=ident, name=args.name, expiresEpoch=expiry, expiresUtc=invite['expiresUtc'], status='open'))
        auth = Path(c['enrollAuthorizedKeys'])
        save(auth, (auth.read_text() if auth.exists() else '') + line, 0o644 if not c.get('sandbox') else 0o600)
        archive = output / (ident + '.zip')
        fd = os.open(archive, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as f, zipfile.ZipFile(f, 'w', zipfile.ZIP_DEFLATED) as z:
            z.write(exe, 'RemoteAgents.exe')
            z.writestr('invite.rainvite', json.dumps(invite, ensure_ascii=False) + '\n')
    event(c, 'create.ok')
    print('ZIP секретный, как пароль. Передавайте только получателю. После регистрации удалите копии ZIP.')
    print(str(archive))
    if args.publish:
        node = c['publishNodes'][args.publish]
        payload = json.dumps({'expiresEpoch': expiry}).encode() + b'\n' + archive.read_bytes()
        if node.get('ssh'):
            url = run(['ssh', '-F', node['sshConfig'], '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', node['ssh'],
                       shlex.join(['remoteagents', 'invite', 'receive', '--node', args.publish])], input=payload).decode().strip()
        else:
            url = receive(c, args.publish, io.BytesIO(payload))
        print(url)


def receive(c, name, stream):
    node = c['publishNodes'][name]
    header = json.loads(stream.readline(1024))
    require(time.time() < header['expiresEpoch'] <= time.time() + 720 * 3600, 'Неверный срок публикации')
    root = Path(node['directory'])
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    token = secrets.token_hex(32)
    payload = stream.read(128 * 1024 * 1024 + 1)
    require(len(payload) <= 128 * 1024 * 1024 and payload.startswith(b'PK'), 'Некорректный ZIP')
    with open(root / (token + '.zip'), 'xb') as f:
        os.chmod(f.name, 0o600)
        f.write(payload)
    save(root / (token + '.json'), header)
    return node['baseUrl'].rstrip('/') + '/' + token + '.zip'


class Downloads(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # URL is a bearer secret; never log it.

    def do_GET(self):
        match = re.fullmatch(r'/([a-f0-9]{64})\.zip', self.path)
        if not match:
            self.send_error(404)
            return
        root = Path(self.server.directory)
        token = match[1]
        with (root / 'download.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            src = root / (token + '.zip')
            meta = root / (token + '.json')
            if not src.exists() or not meta.exists() or load(meta)['expiresEpoch'] <= time.time():
                src.unlink(missing_ok=True)
                meta.unlink(missing_ok=True)
                self.send_error(404)
                return
            # Consume before serving: racing downloads cannot both succeed.
            f = src.open('rb')
            src.unlink()
            meta.unlink()
        with f:
            self.send_response(200)
            self.send_header('Content-Type', 'application/zip')
            self.send_header('Content-Length', str(os.fstat(f.fileno()).st_size))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Disposition', 'attachment; filename="RemoteAgents-invite.zip"')
            self.end_headers()
            with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                shutil.copyfileobj(f, self.wfile)


def serve(c, name):
    node = c['publishNodes'][name]
    root = Path(node['directory'])
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    server = http.server.ThreadingHTTPServer((node['listenHost'], node['listenPort']), Downloads)
    server.directory = str(root)
    server.timeout = 1
    while True:
        server.handle_request()
        with (root / 'download.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            for meta in root.glob('*.json'):
                if load(meta)['expiresEpoch'] <= time.time():
                    meta.with_suffix('.zip').unlink(missing_ok=True)
                    meta.unlink(missing_ok=True)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', default=DEFAULT_CONFIG)
    sub = parser.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('create')
    p.add_argument('--name', required=True)
    p.add_argument('--hours', type=float, default=24)
    p.add_argument('--happier', default='same')
    p.add_argument('--folders', default='')
    p.add_argument('--publish')
    sub.add_parser('list')
    for verb in ('revoke', 'enroll'):
        sub.add_parser(verb).add_argument('id')
    for verb in ('serve', 'receive'):
        sub.add_parser(verb).add_argument('--node', required=True)
    a = parser.parse_args()
    c = config(a.config)
    if a.cmd == 'create':
        create(c, a)
    elif a.cmd == 'enroll':
        signal.alarm(20)
        print(json.dumps(enroll(c, a.id, sys.stdin.buffer.read(2049)), ensure_ascii=False))
    elif a.cmd == 'receive':
        print(receive(c, a.node, sys.stdin.buffer))
    elif a.cmd == 'serve':
        serve(c, a.node)
    else:
        with locked(c) as directory:
            if a.cmd == 'revoke':
                p = entry(c, a.id)
                data = load(p)
                data['status'] = 'revoked'
                save(p, data)
                remove_pass(c, a.id)
                event(c, 'revoke.ok')
                print('Отозвано: ' + a.id)
            else:
                for p in sorted(directory.glob('*.json')):
                    data = load(p)
                    if data['status'] == 'open' and data['expiresEpoch'] <= time.time():
                        data['status'] = 'expired'
                    print(json.dumps({k: data[k] for k in ('id', 'name', 'expiresUtc', 'status')}, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        # Never echo OpenSSH stderr, private paths, input key, or credentials.
        print(json.dumps({'ok': False, 'reason': str(exc) if isinstance(exc, Error) else 'Ошибка конфигурации/файла/ключа; детали скрыты'}, ensure_ascii=False))
        sys.exit(1)
