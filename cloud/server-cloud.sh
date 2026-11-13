#!/usr/bin/env bash
# Python only orchestrates config/status/debounce; sync and watches are rclone/inotifywait.
# Embed it so deployment needs exactly this helper and filter.txt. fd 3 preserves JSON stdin.
set -euo pipefail
if ! command -v python3 >/dev/null 2>&1; then
    echo 'Для облачной службы нужен Python 3; установите пакет python3.' >&2
    exit 1
fi
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec python3 -I - "$SCRIPT_DIR/server-cloud.sh" "$@" 3<&0 <<'PY'
import contextlib
import datetime
import fcntl
import fnmatch
import hashlib
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import platform
import queue
import re
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import zipfile

SOURCE = Path(sys.argv[1]).resolve()
HOME = Path.home()
BASE = HOME / '.local/share/remoteagents-cloud'
UNIT = 'remoteagents-cloud.service'
UNIT_PATH = HOME / '.config/systemd/user' / UNIT
VERSION = '1.76.0'
# Official release SHA256SUMS; also pin the archive digest against silent replacement.
ARCHIVE_SHA256 = 'b00f00b3266c3764413afe599d3ec316f6f43b3e0ea8a0bc1d186d2133e46df7'
PROVIDERS = {'mailru': {'type': 'webdav', 'url': 'https://webdav.cloud.mail.ru', 'vendor': 'owncloud'}}
DEBOUNCE = 2.5
SENTINEL = '.remoteagents-cloud-check'
LOG = logging.getLogger('remoteagents-cloud')


class Error(Exception):
    pass


class Busy(Error):
    pass


def require(condition, message):
    if not condition:
        raise Error(message)


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')


def atomic(path, value, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(value)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def read_json(path, default=None):
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except FileNotFoundError:
        return default


def write_json(path, value):
    atomic(path, json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def run(args, *, input=None, check=True, timeout=180, env=None, cwd=None):
    # Never relay arbitrary subprocess output: it may contain credentials or HTTP headers.
    result = subprocess.run([str(x) for x in args], input=input, text=True,
                            capture_output=True, timeout=timeout, env=env, cwd=cwd)
    if check and result.returncode:
        raise Error('Команда ' + Path(args[0]).name + ' завершилась с кодом ' + str(result.returncode) +
                    '; проверьте доступность сервиса и зависимости.')
    return result


@contextlib.contextmanager
def lock(path, blocking=True):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a') as stream:
        try:
            # flock(2), shared by event and polling passes, including separate workers.
            fcntl.flock(stream, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        except BlockingIOError:
            raise Busy('Синхронизация уже выполняется другим процессом.') from None
        yield


@contextlib.contextmanager
def lifecycle_lock():
    # Lock an existing parent directory inode: remove leaves no lock file and cannot split the lock.
    directory = HOME / '.local/share'
    directory.mkdir(parents=True, exist_ok=True)
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def validate(data):
    require(isinstance(data, dict), 'Ожидается JSON-объект конфигурации.')
    require(data.get('vendor') in PROVIDERS, 'Неизвестный провайдер облака.')
    for key in ('login', 'password'):
        v = data.get(key)
        require(isinstance(v, str) and 0 < len(v) <= 4096 and
                not any(c in v for c in '\r\n\0'), 'Некорректный логин или пароль приложения облака.')
    root = data.get('remoteRoot', 'Disk')
    require(isinstance(root, str) and len(root) <= 1024 and bool(root.strip('/')) and
            not any(c in root for c in '\r\n\0:\\') and
            all(p not in ('', '.', '..') for p in root.strip('/').split('/')),
            'Некорректный remoteRoot.')
    local = data.get('localRoot', '~/Disk')
    require(isinstance(local, str) and local and not any(c in local for c in '\r\n\0'),
            'Некорректный localRoot.')
    require(local.startswith('/') or local.startswith('~/'), 'localRoot должен быть абсолютным или начинаться с ~/.')
    local = Path(local.replace('~/', str(HOME) + '/', 1) if local.startswith('~/') else local).resolve()
    require(local != HOME and local != Path('/') and BASE not in (local, *local.parents) and
            local not in BASE.parents, 'localRoot пересекается с домашней папкой или файлами службы.')
    poll = data.get('pollSeconds', 20)
    require(type(poll) is int and 1 <= poll <= 86400, 'pollSeconds должен быть целым числом от 1 до 86400.')
    return {'schemaVersion': 1, 'vendor': data['vendor'],
            'accountHash': hashlib.sha256((data['vendor'] + '\0' + data['login']).encode()).hexdigest(),
            'remoteRoot': root.strip('/'),
            'localRoot': str(local), 'pollSeconds': poll}


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else hashlib.sha256(stream.read()).hexdigest()


def download(url, dest):
    require(shutil.which('curl'), 'Для загрузки официального rclone нужен curl.')
    run(['curl', '--disable', '--fail', '--silent', '--show-error', '--location', '--proto', '=https',
         '--max-time', '180', '--output', dest, url], timeout=190)


def install_rclone():
    require(platform.system() == 'Linux' and platform.machine() in ('x86_64', 'amd64'),
            'Эта версия установки rclone поддерживает Linux amd64.')
    binary = BASE / 'tools/bin/rclone'
    receipt = read_json(BASE / 'tools/rclone-release.json', {})
    if binary.is_file() and receipt.get('version') == VERSION and receipt.get('archiveSha256') == ARCHIVE_SHA256:
        if receipt.get('binarySha256') == digest(binary):
            return binary
    url = 'https://downloads.rclone.org/v' + VERSION + '/'
    name = 'rclone-v' + VERSION + '-linux-amd64.zip'
    with tempfile.TemporaryDirectory(prefix='rclone-', dir=BASE) as tmp:
        tmp = Path(tmp)
        download(url + 'SHA256SUMS', tmp / 'SHA256SUMS')
        rows = [line.split() for line in (tmp / 'SHA256SUMS').read_text().splitlines()]
        expected = next((r[0] for r in rows if len(r) == 2 and r[1].lstrip('*') == name), None)
        require(expected == ARCHIVE_SHA256, 'SHA256SUMS rclone не совпадает с закреплённым релизом.')
        download(url + name, tmp / name)
        require(digest(tmp / name) == expected, 'Ошибка проверки SHA256 архива rclone.')
        binary.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(tmp / name) as archive:
            content = archive.read(name[:-4] + '/rclone')
        staged = tmp / 'rclone'
        staged.write_bytes(content)
        staged.chmod(0o755)
        require(run([staged, 'version']).stdout.splitlines()[0] == 'rclone v' + VERSION,
                'Неверная версия rclone в архиве.')
        os.replace(staged, binary)
    write_json(BASE / 'tools/rclone-release.json', {'version': VERSION, 'archiveSha256': expected,
                                                  'binarySha256': digest(binary)})
    return binary


def tool_env():
    env = os.environ.copy()
    env['LC_ALL'] = 'C'
    libs = sorted({str(p.parent) for p in (BASE / 'tools/usr').rglob('libinotifytools.so*')})
    if libs:
        env['LD_LIBRARY_PATH'] = ':'.join(libs + ([env['LD_LIBRARY_PATH']] if env.get('LD_LIBRARY_PATH') else []))
    # rclone credentials come ONLY from our file, never inherited config overrides.
    for key in list(env):
        if key.startswith('RCLONE_'):
            del env[key]
    return env


def inotify_binary():
    candidates = [shutil.which('inotifywait'), BASE / 'tools/usr/bin/inotifywait']
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            help_result = run([candidate, '--help'], check=False, env=tool_env())
            # inotify-tools 3.22 returns 1 even for --help.
            if help_result.returncode in (0, 1) and 'inotifywait' in help_result.stdout and '--no-newline' in help_result.stdout:
                return str(candidate)
    return None


def install_inotify():
    binary = inotify_binary()
    if binary:
        return binary
    message = ('Не найден inotifywait: не удалось установить inotify-tools. Нужны apt-get/dpkg и доступ '
               'к официальным репозиториям Debian/Ubuntu либо установка пакета администратором.')
    require(shutil.which('apt-get') and shutil.which('dpkg'), message)
    sudo = shutil.which('sudo')
    prefix = []
    if os.geteuid() == 0:
        prefix = ['apt-get']
    elif sudo:
        if run([sudo, '-n', 'true'], check=False).returncode == 0:
            prefix = [sudo, '-n', 'apt-get']
        elif os.environ.get('SUDO_ASKPASS'):
            if run([sudo, '-A', 'true'], check=False).returncode == 0:
                prefix = [sudo, '-A', 'apt-get']
    if prefix:
        run(prefix + ['install', '-y', 'inotify-tools'], check=False)
        if inotify_binary():
            return inotify_binary()
    # apt verifies downloads against the hashes in its signed repository indices.
    with tempfile.TemporaryDirectory(prefix='inotify-', dir=BASE) as tmp:
        for library in ('libinotifytools0', 'libinotifytools0t64'):
            result = run(['apt-get', 'download', 'inotify-tools', library], cwd=tmp, check=False)
            if result.returncode == 0:
                break
        else:
            raise Error(message)
        for package in Path(tmp).glob('*.deb'):
            if run(['dpkg', '-x', package, BASE / 'tools'], check=False).returncode:
                raise Error(message)
    require(inotify_binary(), message)
    return inotify_binary()


def systemctl(*args, check=True):
    return run(['systemctl', '--user', *args], check=check, timeout=45)


def unit_text():
    # systemd specifiers and quoted ExecStart have their own escaping rules.
    script = str(BASE / 'server-cloud.sh').replace('%', '%%').replace('\\', '\\\\').replace('"', '\\"')
    return ('[Unit]\nDescription=RemoteAgents cloud project synchronization\n'
            'After=network-online.target\nWants=network-online.target\n\n[Service]\n'
            'Type=simple\nExecStart=/bin/bash "' + script + '" _run\n'
            'Restart=on-failure\nRestartSec=5\nUMask=0077\nKillMode=control-group\nTimeoutStopSec=30\n'
            'StandardOutput=null\nStandardError=journal\n\n[Install]\nWantedBy=default.target\n')


def apply(data):
    cfg = validate(data)
    BASE.mkdir(parents=True, exist_ok=True, mode=0o700)
    BASE.chmod(0o700)
    require(systemctl('show-environment', check=False).returncode == 0,
            'Нет пользовательского systemd: администратору нужно включить user manager и linger.')
    rclone = install_rclone()
    install_inotify()
    template = SOURCE.with_name('filter.txt').read_text(encoding='utf-8-sig').replace('\r\n', '\n')
    filter_hash = hashlib.sha256(template.encode()).hexdigest()
    # Migration: renaming the retired template's comment changes no filter rule.
    # Accept only this exact old header with otherwise byte-identical contents.
    legacy_template = template.replace('# Исключения облачных проектов:',
                                       '# Исключения Диска (как disk/stignore.txt):', 1)
    legacy_filter_hash = hashlib.sha256(legacy_template.encode()).hexdigest()
    previous = read_json(BASE / 'config.json')
    if previous:
        identity = ('vendor', 'accountHash', 'remoteRoot', 'localRoot')
        require(all(previous.get(k) == cfg[k] for k in identity),
                'Изменились корни синхронизации, аккаунт или провайдер: сначала выполните remove, затем apply.')
        require(not (BASE / 'state').exists() or previous.get('filterSha256') in (filter_hash, legacy_filter_hash),
                'Изменился фильтр действующего bisync: нужна отдельная проверка и явная повторная инициализация.')
    cfg['filterSha256'] = filter_hash
    # Stop before changing config/state; no password ever enters argv, environment, or journal.
    # On the first install the unit does not exist yet (systemctl exits 5) — nothing to stop.
    systemctl('stop', UNIT, check=False)
    with lock(BASE / 'sync.lock'):
        obscured = run([rclone, 'obscure', '-'], input=data['password'] + '\n', env=tool_env()).stdout.strip()
        require(bool(obscured) and '\n' not in obscured, 'Не удалось скрыть пароль через rclone obscure.')
        provider = PROVIDERS[cfg['vendor']]
        # rclone INI values cannot contain newlines (validated above).
        config = '[cloud]\n' + ''.join(k + ' = ' + v + '\n' for k, v in provider.items())
        config += 'user = ' + data['login'] + '\npass = ' + obscured + '\n'
        atomic(BASE / 'rclone.conf', config)
        if SOURCE != BASE / 'server-cloud.sh':
            atomic(BASE / 'server-cloud.sh', SOURCE.read_text().replace('\r\n', '\n'), 0o700)
        atomic(BASE / 'filter.txt', template)
        write_json(BASE / 'config.json', cfg)
        Path(cfg['localRoot']).mkdir(parents=True, exist_ok=True)
        state = read_json(BASE / 'status.json', {'schemaVersion': 1, 'projects': {}})
        state.update(state='starting', updatedAt=now())
        state.pop('error', None)
        write_json(BASE / 'status.json', state)
        atomic(UNIT_PATH, unit_text(), 0o600)
    systemctl('daemon-reload')
    systemctl('enable', UNIT)
    systemctl('restart', UNIT)
    require(systemctl('is-active', '--quiet', UNIT, check=False).returncode == 0,
            'Служба облака не запустилась; проверьте журнал и status.json.')
    return {'ok': True, 'serviceActive': True, 'state': 'starting', 'statusFile': str(BASE / 'status.json'),
            'rcloneVersion': VERSION}


def status():
    result = read_json(BASE / 'status.json', {'schemaVersion': 1, 'state': 'not-configured', 'projects': {}})
    result['serviceActive'] = systemctl('is-active', '--quiet', UNIT, check=False).returncode == 0
    return result


def remove():
    # An absent unit is harmless; failure to stop an installed one must not remove its files.
    if UNIT_PATH.exists():
        systemctl('stop', UNIT)
        systemctl('disable', UNIT)
    with lock(BASE / 'sync.lock', blocking=False):
        if UNIT_PATH.exists():
            UNIT_PATH.unlink()
        if BASE.exists():
            shutil.rmtree(BASE)
    systemctl('daemon-reload')
    return {'ok': True, 'removed': True}


def setup_log():
    folder = BASE / 'logs'
    folder.mkdir(exist_ok=True)
    handler = RotatingFileHandler(folder / 'cloud.log', maxBytes=2 * 1024 * 1024, backupCount=3, encoding='utf-8')
    handler.setFormatter(logging.Formatter('%(asctime)s %(levelname)s %(message)s'))
    LOG.handlers[:] = [handler]
    LOG.setLevel(logging.INFO)


def safe_error(message):
    # DAV responses can echo arbitrary secrets. Publish only recognized error categories.
    message = message.lower()
    categories = [('401', 'Облако отклонило логин или пароль (HTTP 401).'),
                  ('403', 'Облако запретило доступ (HTTP 403).'),
                  ('timeout', 'Истекло время ожидания облака.'),
                  ('connection refused', 'Облако недоступно: соединение отклонено.'),
                  ('filter', 'Изменился или некорректен фильтр bisync.'),
                  ('lock', 'Состояние bisync заблокировано.'),
                  ('listing', 'Ошибка чтения списка файлов bisync.'),
                  ('resync', 'rclone требует проверки состояния и повторной инициализации bisync.')]
    return next((text for pattern, text in categories if pattern in message),
                'Ошибка rclone при синхронизации; содержимое ответа облака скрыто.')


class Worker:
    def __init__(self):
        self.cfg = read_json(BASE / 'config.json')
        require(self.cfg is not None, 'Облако не настроено; выполните apply.')
        self.local = Path(self.cfg['localRoot'])
        self.remote = 'cloud:' + self.cfg['remoteRoot']
        self.rclone = BASE / 'tools/bin/rclone'
        self.env = tool_env()
        self.stop = threading.Event()
        self.events = queue.Queue(maxsize=65536)
        self.overflow = threading.Event()
        self.watch_error = threading.Event()
        self.pending = {}
        self.watcher = None
        self.child = None
        self.current = read_json(BASE / 'status.json', {'schemaVersion': 1, 'projects': {}})
        self.current['state'] = 'starting'
        self.current.pop('error', None)
        # Filter files are applied relative to EACH project, including storage/app.
        self.directory_excludes = []
        self.name_excludes = []
        for line in (BASE / 'filter.txt').read_text().splitlines():
            if line.startswith('- ') and '/' not in line[2:]:
                self.name_excludes.append(line[2:])
            if line.startswith('- ') and line.endswith('/**') and '/' not in line[2:-3]:
                self.directory_excludes.append(line[2:-3])

    def save(self):
        self.current['updatedAt'] = now()
        write_json(BASE / 'status.json', self.current)

    def command(self, args):
        return [str(self.rclone), *args, '--config', str(BASE / 'rclone.conf'), '--contimeout', '10s',
                '--timeout', '30s', '--retries', '1', '--low-level-retries', '2']

    def control(self, args):
        return run(self.command(args), env=self.env, timeout=120)

    def excluded_project(self, name):
        return any(fnmatch.fnmatchcase(name.lower(), p.lower()) for p in self.directory_excludes + self.name_excludes)

    def projects(self):
        require(self.local.is_dir(), 'Исчез localRoot; восстановите доступ к папке и перезапустите службу.')
        names = {p.name for p in self.local.iterdir() if p.is_dir() and not p.is_symlink()}
        remote = self.control(['lsf', self.remote, '--dirs-only', '--max-depth', '1'])
        names.update(line.rstrip('/') for line in remote.stdout.splitlines() if line.endswith('/'))
        names.update(self.current['projects'])
        return sorted(n for n in names if n not in ('', '.', '..') and '/' not in n and
                      '\\' not in n and not any(ord(c) < 32 for c in n) and not self.excluded_project(n))

    def sync(self, project, reason):
        started = now()
        try:
            self._sync(project, reason)
        except (Error, OSError, subprocess.TimeoutExpired) as exc:
            message = str(exc) if isinstance(exc, Error) else 'Ошибка подготовки проекта: ' + type(exc).__name__
            self.current['projects'][project] = {'startedAt': started, 'finishedAt': now(), 'result': 'error',
                'reason': reason, 'transferred': 0, 'bytes': 0, 'deleted': 0, 'firstError': message}
            LOG.error('Проект %s: %s', json.dumps(project, ensure_ascii=True), message)
            self.save()

    def _sync(self, project, reason):
        if self.stop.is_set():
            return
        require(self.local.is_dir(), 'Исчез localRoot; синхронизация остановлена.')
        local = self.local / project
        require(not local.is_symlink(), 'Папка проекта стала символьной ссылкой; синхронизация остановлена.')
        key = hashlib.sha256(project.encode()).hexdigest()
        state = BASE / 'state' / key
        state.mkdir(parents=True, exist_ok=True)
        local.mkdir(exist_ok=True)
        # rclone 1.76 refuses ANY empty current listing, even with --force (bisync/listing.go).
        # A persistent empty directory + --create-empty-src-dirs is the native workaround:
        # bisync itself still propagates every user-file deletion; never resync to bypass this guard.
        sentinel = local / SENTINEL
        require(not sentinel.is_symlink(), 'Служебная папка проекта не должна быть символьной ссылкой.')
        sentinel.mkdir(exist_ok=True)
        self.control(['mkdir', self.remote + '/' + project + '/' + SENTINEL])
        initialized = state / 'initialized'
        args = ['bisync', str(local), self.remote + '/' + project, '--workdir', str(state),
                '--resilient', '--recover', '--max-lock', '2m', '--conflict-resolve', 'newer',
                '--conflict-loser', 'num', '--compare', 'size,modtime', '--max-delete', '100', '--force',
                '--filters-file', str(BASE / 'filter.txt'), '--ignore-case', '--create-empty-src-dirs',
                '--use-json-log', '--stats', '1h', '--stats-log-level', 'NOTICE', '--transfers', '16', '--checkers', '16']
        if not initialized.exists():
            # Keep the same comparison/listing format on initialization and every later pass.
            # A size-only resync omits mtimes; switching back then breaks bisync's listing checks.
            args.append('--resync')
        entry = {'startedAt': now(), 'result': 'running', 'reason': reason,
                 'transferred': 0, 'bytes': 0, 'deleted': 0, 'firstError': None}
        self.current['projects'][project] = entry
        self.current['state'] = 'syncing'
        self.save()
        LOG.info('Проект %s: начало (%s)', json.dumps(project, ensure_ascii=True), reason)
        stats, first_error = {}, None
        # Stream JSON diagnostics: no unbounded capture, no raw rclone output in the journal.
        with subprocess.Popen(self.command(args), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                              text=True, env=self.env) as child:
            self.child = child
            try:
                for line in child.stderr:
                    try:
                        record = json.loads(line)
                    except ValueError:
                        continue
                    if 'stats' in record:
                        stats = record['stats']
                    if record.get('level') in ('error', 'critical') and first_error is None:
                        first_error = safe_error(str(record.get('msg', 'Ошибка rclone')))
                code = child.wait()
            finally:
                self.child = None
        result = 'ok' if code == 0 else ('interrupted' if self.stop.is_set() else 'error')
        entry.update(finishedAt=now(), result=result, transferred=stats.get('transfers', 0),
                     bytes=stats.get('bytes', 0), deleted=stats.get('deletes', 0),
                     firstError=first_error if code else None)
        if code and not entry['firstError']:
            entry['firstError'] = 'rclone завершился с кодом ' + str(code)
        if code == 0 and not initialized.exists():
            atomic(initialized, now() + '\n')
        LOG.info('Проект %s: %s; передано=%s удалено=%s; %s', json.dumps(project, ensure_ascii=True),
                 result, entry['transferred'], entry['deleted'], entry['firstError'] or '')
        self.save()

    def watch(self):
        binary = inotify_binary()
        require(binary, 'Не найден inotifywait; повторите apply для установки inotify-tools.')
        args = [binary, '-m', '-r', '-P', '--format', '%w%f%0%e%0', '--no-newline',
                '-e', 'close_write,create,delete,moved_to,moved_from,attrib,delete_self,move_self,unmount', str(self.local)]
        args[1:1] = ['--excludei', '(^|/)(' + '|'.join(re.escape(p) for p in self.directory_excludes + [SENTINEL]) + ')(/|$)']
        self.watcher = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env, bufsize=0)
        # Wait for the utility to establish all recursive watches BEFORE initial sync.
        with selectors.DefaultSelector() as selector:
            selector.register(self.watcher.stderr, selectors.EVENT_READ)
            ready = False
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline and not ready:
                if selector.select(timeout=1):
                    line = self.watcher.stderr.readline()
                    require(bool(line), 'inotifywait не смог установить наблюдение: проверьте лимит inotify и права.')
                    ready = b'Watches established.' in line
            require(ready, 'inotifywait не подтвердил готовность наблюдения за 60 секунд.')

        def reader():
            buffer, path = b'', None
            while True:
                chunk = os.read(self.watcher.stdout.fileno(), 65536)
                if not chunk:
                    break
                buffer += chunk
                while b'\0' in buffer:
                    item, buffer = buffer.split(b'\0', 1)
                    if path is None:
                        path = os.fsdecode(item)
                    else:
                        try:
                            self.events.put_nowait((path, item.decode(), time.monotonic()))
                        except queue.Full:
                            self.overflow.set()
                        path = None

        threading.Thread(target=reader, daemon=True).start()

        def diagnostics():
            # A lost recursive watch must trigger restart/full discovery, never silent polling-only operation.
            for line in self.watcher.stderr:
                if line.strip():
                    self.watch_error.set()
        threading.Thread(target=diagnostics, daemon=True).start()

    def request_stop(self, *_):
        self.stop.set()
        if self.child and self.child.poll() is None:
            self.child.terminate()

    def loop(self):
        with lock(BASE / 'sync.lock', blocking=False):
            signal.signal(signal.SIGTERM, self.request_stop)
            signal.signal(signal.SIGINT, self.request_stop)
            try:
                self.watch()
                self.control(['mkdir', self.remote])
                next_poll = 0
                while not self.stop.is_set():
                    require(self.watcher.poll() is None, 'inotifywait остановился; служба будет перезапущена.')
                    require(not self.watch_error.is_set(), 'inotifywait сообщил об ошибке наблюдения; нужен перезапуск.')
                    require(not self.overflow.is_set(), 'Переполнена очередь событий; служба будет перезапущена с полным проходом.')
                    while True:
                        try:
                            path, event, at = self.events.get_nowait()
                        except queue.Empty:
                            break
                        require('Q_OVERFLOW' not in event and 'UNMOUNT' not in event, 'inotify потерял события; нужен перезапуск.')
                        relative = Path(path).relative_to(self.local)
                        if relative.parts:
                            project = relative.parts[0]
                            if not self.excluded_project(project):
                                self.pending[project] = max(at, self.pending.get(project, 0))
                        elif 'DELETE_SELF' in event or 'MOVE_SELF' in event:
                            raise Error('Корень наблюдения перемещён или удалён.')
                    at = time.monotonic()
                    for project in list(self.pending):
                        if at - self.pending[project] >= DEBOUNCE:
                            del self.pending[project]
                            if (self.local / project).is_dir() or project in self.current['projects']:
                                self.sync(project, 'event')
                    if time.monotonic() >= next_poll:
                        for project in self.projects():
                            self.sync(project, 'poll')
                        next_poll = time.monotonic() + self.cfg['pollSeconds']
                    state = 'error' if any(p['result'] != 'ok' for p in self.current['projects'].values()) else 'watching'
                    if self.current['state'] != state:
                        self.current['state'] = state
                        self.save()
                    self.stop.wait(0.2)
            finally:
                if self.watcher:
                    self.watcher.terminate()
                    self.watcher.wait(timeout=10)
                if self.stop.is_set():
                    self.current['state'] = 'stopped'
                    self.save()


def main():
    os.umask(0o077)
    command = sys.argv[2] if len(sys.argv) == 3 else ''
    require(command in ('apply', 'status', 'remove', '_run'), 'Использование: server-cloud.sh apply|status|remove')
    if command == '_run':
        setup_log()
        try:
            Worker().loop()
        except Busy:
            # A contender must not overwrite the active worker's status.
            raise
        except Exception as exc:
            # Errors outside bisync do not expose arbitrary subprocess diagnostics.
            message = str(exc) if isinstance(exc, Error) else 'Внутренняя ошибка службы: ' + type(exc).__name__
            LOG.error('%s', message)
            value = read_json(BASE / 'status.json', {'schemaVersion': 1, 'projects': {}})
            value.update(state='error', error=message, updatedAt=now())
            write_json(BASE / 'status.json', value)
            raise Error(message) from None
        return
    with lifecycle_lock():
        if command == 'apply':
            with os.fdopen(3, encoding='utf-8-sig') as stream:
                try:
                    data = json.load(stream)
                except ValueError:
                    raise Error('Некорректный JSON конфигурации облака.') from None
            result = apply(data)
        elif command == 'status':
            result = status()
        else:
            result = remove()
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(str(exc) if isinstance(exc, Error) else 'Ошибка облачного сервиса: ' + type(exc).__name__, file=sys.stderr)
        sys.exit(1)
PY
