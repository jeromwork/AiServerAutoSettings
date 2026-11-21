#!/usr/bin/env python3
"""Приёмник журналов с компьютеров (RemoteAgents). Без службы: исходник приезжает в каждой SSH-команде
(`python3 -c 'import base64;exec(base64.b64decode("..."))' recv`), как в config.sync.

Вход: gzip из stdin. Формат пачки (UTF-8, \\n):
  RA-LOGS 1 batch=<id> device=<base64url> host=<имя> ver=<версия> sent=<UTC>
  @@ <поток> fp=<hex> from=<смещение> to=<смещение> lines=<n>
  <строки журнала>
Хранение: <корень>/<устройство>--<компьютер>/<поток>-YYYY-MM-DD.log, 30 суток и не больше 200 МБ на устройство.
Корень: ~/work/logs-in, для тестов RA_LOGS_IN_ROOT. Ответ: `OK batch=<id> stored=<строк>` либо `ERR <код> <текст>` (код выхода 2).
"""
import base64
import fcntl
import gzip
import io
import json
import os
import re
import sys
import time
import zlib
import stat
from contextlib import contextmanager
from datetime import datetime, timezone

MAX_UNPACKED = 8 * 1024 * 1024
MAX_LINE = 8 * 1024
STREAMS = ('launcher', 'transport', 'helper', 'core', 'config-window', 'bus', 'health')
MAX_DAYS = int(os.environ.get('RA_LOGS_IN_MAX_DAYS', '30'))
MAX_BYTES = int(os.environ.get('RA_LOGS_IN_MAX_BYTES', str(200 * 1024 * 1024)))


class ReceiveError(Exception):
    def __init__(self, code, text):
        Exception.__init__(self, text)
        self.code = code
        self.text = text


# ---- маскирование (те же правила, что LogMask.cs / Protect-RaLogText; общий файл фикстур mask-cases.json) ----
_PRIVATE = re.compile(r'-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?(?:-----END [^-]*PRIVATE KEY-----|$)', re.I)
_PUBKEY = re.compile(r'ssh-(ed25519|rsa) AAAA[A-Za-z0-9+/=]+')
_USERINFO = re.compile(r'://[^/\s@]+@')
_BASIC = re.compile(r'(Authorization[:=]\s*)Basic\s+\S+', re.I)
_BEARER = re.compile(r'Bearer\s+[A-Za-z0-9._~+/=-]+', re.I)
_FIELD = re.compile(r'''(?<![A-Za-z0-9_.-])(["']?)([A-Za-z0-9_.-]{1,256})\1(\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s,;&"']+)''')
_UUID = re.compile(r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b')
_BLOB = re.compile(r'[A-Za-z0-9+/=_-]{41,}')
_SUBSTR = re.compile(r'token|password|passwd|passphrase|secret|authorization|cookie|uuid', re.I)
_WORDS = re.compile(r'(?:^|[_.-])(?:key|pass|auth|psk|apikey)(?:$|[_.-])', re.I)


def _secret_name(name):
    if not name or re.fullmatch(r'\w*(?:Error|Exception)', name):
        return False
    if _SUBSTR.search(name):
        return True
    return bool(_WORDS.search(re.sub(r'([a-z0-9])([A-Z])', r'\1_\2', name)))


def _blob(m):
    v = m.group(0)
    digit = any(c.isdigit() for c in v)
    upper = any('A' <= c <= 'Z' for c in v)
    lower = any('a' <= c <= 'z' for c in v)
    hexa = re.fullmatch(r'[0-9a-fA-F]+', v) is not None
    if hexa or (digit and upper and lower) or (digit and '/' not in v and (upper or lower)):
        return '[blob:%d]' % len(v)
    return v


def mask(text):
    t = _PRIVATE.sub('[private-key]', text)
    t = _PUBKEY.sub(r'ssh-\1 [pubkey]', t)
    t = _USERINFO.sub('://***@', t)
    t = _BASIC.sub(r'\1Basic ***', t)
    t = _BEARER.sub('Bearer ***', t)
    t = _FIELD.sub(lambda m: m.group(1) + m.group(2) + m.group(1) + m.group(3) + '***' if _secret_name(m.group(2)) else m.group(0), t)
    t = _UUID.sub(lambda m: 'uuid:****' + m.group(0)[-4:], t)
    return _BLOB.sub(_blob, t)


# ---- разбор ----
def safe(value):
    out = ''.join(c if (c.isalpha() or c.isdigit() or c in '-_.') else '_' for c in value).encode('utf-8')[:64].decode('utf-8', 'ignore')
    if not out.strip('.'):
        out = '_' + out.replace('.', '_')[:63]
    return out


def _b64url_decode(text):
    try:
        return base64.urlsafe_b64decode(text + '=' * (-len(text) % 4)).decode('utf-8')
    except Exception:
        raise ReceiveError('bad-device', 'device is not base64url')


def parse_batch(raw):
    """raw — байты gzip. Возвращает (header, segments).

    Сегмент содержит stream/fp/from/to, lines[(raw_bytes, source_size)]
    и bad (причина пропуска либо None).
    """
    try:
        with gzip.GzipFile(fileobj=io.BytesIO(raw)) as handle:
            data = handle.read(MAX_UNPACKED + 1)
    except (OSError, EOFError, zlib.error):
        raise ReceiveError('bad-gzip', 'not a gzip stream')
    if len(data) > MAX_UNPACKED:
        raise ReceiveError('too-big', 'batch is larger than %d bytes' % MAX_UNPACKED)
    rows = data.split(b'\n')
    head = rows[0].decode('utf-8', 'replace').split(' ')
    if len(head) < 2 or head[0] != 'RA-LOGS' or head[1] != '1':
        raise ReceiveError('bad-header', 'expected RA-LOGS 1')
    header = {}
    for part in head[2:]:
        if '=' in part:
            k, v = part.split('=', 1)
            header[k] = v
    for need in ('batch', 'device', 'host'):
        if not header.get(need):
            raise ReceiveError('bad-header', 'missing ' + need)
    if not re.fullmatch(r'[A-Za-z0-9._-]{1,64}', header['batch']):
        raise ReceiveError('bad-header', 'bad batch id')
    header['device_name'] = _b64url_decode(header['device'])
    segments = []
    current = None
    # Разбираем исходные байты: пустые строки и неверный UTF-8 тоже занимают смещения.
    segment_header = re.compile(rb'@@ ([^\s]+) fp=([0-9a-fA-F]{1,64}) from=([0-9]+) to=([0-9]+) lines=([0-9]+)')
    for index, row in enumerate(rows[1:], 1):
        if index == len(rows) - 1 and row == b'':
            break  # конечный разделитель, не дополнительная пустая строка
        m = segment_header.fullmatch(row)
        # Внутри заявленного тела строки, похожие на заголовок, остаются данными.
        # Достижение числа строк ИЛИ байтов позволяет отделить следующий сегмент,
        # даже если второе значение предыдущего сегмента повреждено.
        if m and (current is None or current['bad'] or len(current['lines']) >= current['count']
                  or current['size'] >= current['to'] - current['from']):
            stream, fp, start, end, count = m.groups()
            start, end, count = int(start), int(end), int(count)
            bad = 'bad offsets or line count' if end < start or end - start > len(data) or count > len(data) else None
            stream = stream.decode('ascii', 'replace')
            current = {'stream': stream if stream in STREAMS else 'other', 'fp': fp.decode('ascii'),
                       'from': start, 'to': end, 'count': count, 'lines': [], 'size': 0, 'bad': bad}
            segments.append(current)
        elif current is not None:
            size = len(row) + (1 if index < len(rows) - 1 else 0)
            current['lines'].append((row, size))
            current['size'] += size
    for seg in segments:
        if len(seg['lines']) != seg['count'] or seg['size'] != seg['to'] - seg['from']:
            seg['bad'] = seg['bad'] or 'body does not match offsets or line count'
    return header, segments


def _line_date(line, fallback):
    m = re.match(r'(\d{4}-\d{2}-\d{2})T', line)
    return m.group(1) if m else fallback


def _root():
    return os.environ.get('RA_LOGS_IN_ROOT') or os.path.expanduser('~/work/logs-in')


def device_dir(header, root=None):
    return os.path.join(root or _root(), safe(header['device_name']) + '--' + safe(header['host']))


_CONTROLS = re.compile(r'[\x00-\x08\x0b-\x1f\x7f]')


@contextmanager
def private_directory(path):
    """Открывает каждый компонент через dir_fd/O_NOFOLLOW, включая родителей корня."""
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for name in os.path.abspath(path).split(os.sep):
            if not name:
                continue
            try:
                os.mkdir(name, mode=0o700, dir_fd=fd)
            except FileExistsError:
                pass
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        yield fd
    finally:
        os.close(fd)


def open_private(directory_fd, name, mode):
    flags = {'a': os.O_WRONLY | os.O_CREAT | os.O_APPEND,
             'w': os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 'r': os.O_RDONLY}[mode[0]]
    fd = os.open(name, flags | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=directory_fd)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise OSError('not a regular log file')
    return os.fdopen(fd, mode, **({} if 'b' in mode else {'encoding': 'utf-8'}))


def store(header, segments, root=None):
    """Смещения относятся к исходным байтам; маскирование и обрезка выполняются после дедупликации."""
    directory = device_dir(header, root)
    today = datetime.now(timezone.utc).strftime('%Y-%m-%d')
    stored = 0
    with private_directory(directory) as dfd, open_private(dfd, '.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open_private(dfd, '.cursors.json', 'r') as handle:
                cursors = json.load(handle)
        except (OSError, ValueError):
            cursors = {}
        if not isinstance(cursors, dict):
            cursors = {}
        opened = {}
        try:
            for seg in segments:
                key = seg['stream'] + '|' + seg['fp']
                try:
                    saved = max(0, int(cursors.get(key, 0)))
                except (ValueError, TypeError, OverflowError):
                    saved = 0
                if seg.get('bad'):
                    # OK подтверждает и пропуск: ни этот сегмент, ни другие потоки не застрянут.
                    cursors[key] = max(saved, seg['to'])
                    continue
                if seg['to'] <= saved:
                    continue
                consumed = seg['from']
                for raw, size in seg['lines']:
                    offset = consumed
                    consumed += size
                    if offset < saved:
                        continue
                    # Сначала маскируем: обрезка не должна оставить часть длинного секрета.
                    line = _CONTROLS.sub('', mask(raw.decode('utf-8', 'replace')))
                    encoded = line.encode('utf-8')[:MAX_LINE].decode('utf-8', 'ignore').encode('utf-8')
                    name = '%s-%s.log' % (seg['stream'], _line_date(line, today))
                    handle = opened.get(name)
                    if handle is None:
                        handle = opened[name] = open_private(dfd, name, 'ab')
                    handle.write(encoded + b'\n')
                    stored += 1
                cursors[key] = max(saved, seg['to'])
            for handle in opened.values():
                handle.flush()
                os.fsync(handle.fileno())
        finally:
            for handle in opened.values():
                handle.close()
        with open_private(dfd, '.cursors.json.tmp', 'w') as handle:
            json.dump(cursors, handle)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace('.cursors.json.tmp', '.cursors.json', src_dir_fd=dfd, dst_dir_fd=dfd)
    return stored


def prune(directory, now=None, max_days=None, max_bytes=None):
    now = now or time.time()
    max_days = MAX_DAYS if max_days is None else max_days
    max_bytes = MAX_BYTES if max_bytes is None else max_bytes
    with private_directory(directory) as dfd:
        files = []
        for name in os.listdir(dfd):
            info = os.stat(name, dir_fd=dfd, follow_symlinks=False)
            if name.endswith('.log') and stat.S_ISREG(info.st_mode):
                files.append((info.st_mtime, info.st_size, name))
        files.sort()
        total = sum(f[1] for f in files)
        for mtime, size, name in files:
            if now - mtime > max_days * 86400 or total > max_bytes:
                try:
                    os.unlink(name, dir_fd=dfd)
                    total -= size
                except OSError:
                    pass


def _receiver_log(batch, device, stored, status, root=None):
    try:
        with private_directory(root or _root()) as dfd, open_private(dfd, '_receiver.log', 'a') as handle:
            handle.write('%s %s batch=%s device=%s stored=%s\n' % (datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), status, batch, safe(device), stored))
    except OSError:
        pass


def recv(raw, root=None):
    header, segments = parse_batch(raw)
    stored = store(header, segments, root)
    for seg in segments:
        if seg.get('bad'):
            status = 'bad-segment stream=%s fp=%s from=%d to=%d reason=%s' % (
                seg['stream'], seg['fp'], seg['from'], seg['to'], seg['bad'])
            _receiver_log(header['batch'], header['device_name'], 0, status, root)
    try:
        prune(device_dir(header, root))
    except OSError:
        pass
    _receiver_log(header['batch'], header['device_name'], stored, 'OK', root)
    return 'OK batch=%s stored=%d' % (header['batch'], stored)


def main(argv):
    os.umask(0o077)
    if not argv or argv[-1] != 'recv':
        sys.stdout.write('ERR usage use: recv\n')
        return 2
    try:
        print(recv(sys.stdin.buffer.read(16 * 1024 * 1024)))
        return 0
    except ReceiveError as error:
        _receiver_log('-', '-', 0, 'ERR ' + error.code)
        sys.stdout.write('ERR %s %s\n' % (error.code, error.text))
        return 2
    except Exception as error:  # noqa: BLE001 - любая ошибка должна дать понятный ответ
        _receiver_log('-', '-', 0, 'ERR internal')
        sys.stdout.write('ERR internal %s\n' % type(error).__name__)
        return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
