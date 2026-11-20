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
from datetime import datetime, timezone

MAX_UNPACKED = 8 * 1024 * 1024
MAX_LINE = 8 * 1024
STREAMS = ('launcher', 'transport', 'helper', 'core', 'config-window')
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
_FIELD = re.compile(r'''(?<![A-Za-z0-9])(["']?)([A-Za-z0-9_.-]+)\1(\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s,;&"']+)''')
_UUID = re.compile(r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b')
_BLOB = re.compile(r'[A-Za-z0-9+/=_-]{41,}')
_SUBSTR = re.compile(r'token|password|passwd|passphrase|secret|authorization|cookie|uuid', re.I)
_WORDS = re.compile(r'(?:^|[_.-])(?:key|pass|auth|psk|private|apikey)(?:$|[_.-])', re.I)


def _secret_name(name):
    if not name:
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
    out = ''.join(c if (c.isalpha() or c.isdigit() or c in '-_.') else '_' for c in value)[:64]
    if not out.strip('.'):
        out = '_' + out.replace('.', '_')
    return out


def _b64url_decode(text):
    try:
        return base64.urlsafe_b64decode(text + '=' * (-len(text) % 4)).decode('utf-8')
    except Exception:
        raise ReceiveError('bad-device', 'device is not base64url')


def parse_batch(raw):
    """raw — байты gzip. Возвращает (header, segments); segment = dict(stream, fp, from, to, lines[list[str]])."""
    try:
        with gzip.GzipFile(fileobj=io.BytesIO(raw)) as handle:
            data = handle.read(MAX_UNPACKED + 1)
    except (OSError, EOFError):
        raise ReceiveError('bad-gzip', 'not a gzip stream')
    if len(data) > MAX_UNPACKED:
        raise ReceiveError('too-big', 'batch is larger than %d bytes' % MAX_UNPACKED)
    text = data.decode('utf-8', 'replace')
    rows = text.split('\n')
    head = rows[0].split(' ')
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
    for row in rows[1:]:
        if row.startswith('@@ '):
            fields = row[3:].split(' ')
            attrs = dict(p.split('=', 1) for p in fields[1:] if '=' in p)
            stream = fields[0] if fields and fields[0] in STREAMS else 'other'
            try:
                current = {'stream': stream, 'fp': re.sub(r'[^0-9a-fA-F]', '', attrs.get('fp', ''))[:64], 'from': int(attrs.get('from', '0')), 'to': int(attrs.get('to', '0')), 'lines': []}
            except ValueError:
                raise ReceiveError('bad-segment', 'bad offsets')
            segments.append(current)
        elif current is not None and row != '':
            current['lines'].append(row[:MAX_LINE])
    return header, segments


def _line_date(line, fallback):
    m = re.match(r'(\d{4}-\d{2}-\d{2})T', line)
    return m.group(1) if m else fallback


def _root():
    return os.environ.get('RA_LOGS_IN_ROOT') or os.path.expanduser('~/work/logs-in')


def device_dir(header, root=None):
    return os.path.join(root or _root(), safe(header['device_name']) + '--' + safe(header['host']))


def store(header, segments, root=None):
    """Дедупликация по курсорам stream+fp -> max to; запись append+fsync, затем атомарное обновление курсоров."""
    directory = device_dir(header, root)
    os.makedirs(directory, exist_ok=True)
    today = datetime.now(timezone.utc).strftime('%Y-%m-%d')
    stored = 0
    with open(os.path.join(directory, '.lock'), 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        cursor_file = os.path.join(directory, '.cursors.json')
        try:
            with open(cursor_file, encoding='utf-8') as handle:
                cursors = json.load(handle)
        except (OSError, ValueError):
            cursors = {}
        opened = {}
        try:
            for seg in segments:
                key = seg['stream'] + '|' + seg['fp']
                saved = int(cursors.get(key, 0))
                if seg['to'] <= saved:
                    continue
                lines = seg['lines']
                if seg['from'] < saved:
                    # Частичное перекрытие: отбрасываем уже принятые байты (границы смещений — концы строк).
                    skip = saved - seg['from']
                    consumed = 0
                    kept = []
                    for line in lines:
                        size = len(line.encode('utf-8')) + 1
                        if consumed >= skip:
                            kept.append(line)
                        consumed += size
                    lines = kept
                for line in lines:
                    line = mask(line)
                    name = '%s-%s.log' % (seg['stream'], _line_date(line, today))
                    handle = opened.get(name)
                    if handle is None:
                        handle = opened[name] = open(os.path.join(directory, name), 'ab')
                    handle.write(line.encode('utf-8') + b'\n')
                    stored += 1
                cursors[key] = max(saved, seg['to'])
            for handle in opened.values():
                handle.flush()
                os.fsync(handle.fileno())
        finally:
            for handle in opened.values():
                handle.close()
        tmp = cursor_file + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as handle:
            json.dump(cursors, handle)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, cursor_file)
    return stored


def prune(directory, now=None, max_days=None, max_bytes=None):
    now = now or time.time()
    max_days = MAX_DAYS if max_days is None else max_days
    max_bytes = MAX_BYTES if max_bytes is None else max_bytes
    files = []
    for name in os.listdir(directory):
        path = os.path.join(directory, name)
        if name.endswith('.log') and os.path.isfile(path):
            files.append((os.path.getmtime(path), os.path.getsize(path), path))
    files.sort()
    total = sum(f[1] for f in files)
    for mtime, size, path in files:
        if now - mtime > max_days * 86400 or total > max_bytes:
            try:
                os.remove(path)
                total -= size
            except OSError:
                pass


def _receiver_log(batch, device, stored, status, root=None):
    try:
        base = root or _root()
        os.makedirs(base, exist_ok=True)
        with open(os.path.join(base, '_receiver.log'), 'a', encoding='utf-8') as handle:
            handle.write('%s %s batch=%s device=%s stored=%s\n' % (datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), status, batch, safe(device), stored))
    except OSError:
        pass


def recv(raw, root=None):
    header, segments = parse_batch(raw)
    stored = store(header, segments, root)
    try:
        prune(device_dir(header, root))
    except OSError:
        pass
    _receiver_log(header['batch'], header['device_name'], stored, 'OK', root)
    return 'OK batch=%s stored=%d' % (header['batch'], stored)


def main(argv):
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
