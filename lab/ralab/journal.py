"""Полный журнал (раздел 6 плана): JSON-строки, маскировка секретов, ротация, кольцо в памяти.

Одна функция маскировки - mask(). Секреты регистрируются через register()/collect() сразу, как найдены.
Пределы: файл 5 МБ, 4 файла, кольцо 2000 записей, строка поля 2000 знаков, запись 16000 знаков, секретов 2000.
"""
import collections, datetime, json, os, re, sys, threading

SECRET_KEYS = ('uuid', 'password', 'private_key', 'short_id', 'public_key', 'private_key_passphrase', 'path')  # как в lan_poc
FILE_MAX, FILES_MAX, RING_MAX, FIELD_MAX, REC_MAX, SECRETS_MAX = 5 * 1024 * 1024, 4, 2000, 2000, 16000, 2000

_lock = threading.RLock()
_secrets, _sorted = set(), []
_ring = collections.deque(maxlen=RING_MAX)
_dir, _fh, _size, _num = None, None, 0, 0
_last_key, _repeat, _rolled, _broken = None, 0, False, False


def _strings(o):
    if isinstance(o, str):
        yield o
    for v in (o.values() if isinstance(o, dict) else o if isinstance(o, (list, tuple)) else ()):
        yield from _strings(v)


def register(*values):
    """Запомнить секретные строки (и их отдельные строки, если многострочные)."""
    global _sorted
    with _lock:
        for v in values:
            if not isinstance(v, str):
                continue
            for p in [v] + v.splitlines():
                if len(p.strip()) >= 2 and len(_secrets) < SECRETS_MAX:
                    _secrets.add(p)
        _sorted = sorted(_secrets, key=len, reverse=True)


def collect(o):
    """Обойти объект (outbound'ы, конфиг) и зарегистрировать значения секретных полей."""
    if isinstance(o, dict):
        for k, v in o.items():
            if k in SECRET_KEYS:
                register(*_strings(v))
            else:
                collect(v)
    elif isinstance(o, (list, tuple)):
        for x in o:
            collect(x)


def redact(o):
    """Копия объекта, где значения секретных полей заменены на ***, для показа конфигов."""
    if isinstance(o, dict):
        return {k: '***' if k in SECRET_KEYS else redact(v) for k, v in o.items()}
    return [redact(x) for x in o] if isinstance(o, list) else o


def mask(x):
    """Единственная функция маскировки: строка или структура (dict/list) -> то же без секретов (логика scrub из lan_poc)."""
    if isinstance(x, str):
        for s in _sorted:
            x = x.replace(s, '***') if len(s) >= 4 else re.sub(r'(?<![\w-])%s(?![\w-])' % re.escape(s), '***', x)  # короткие - только целыми токенами
        return x
    if isinstance(x, dict):
        return {str(k): mask(v) for k, v in x.items()}
    if isinstance(x, (list, tuple)):
        return [mask(v) for v in x]
    return x


def _clip(x):
    if isinstance(x, str):
        return x if len(x) <= FIELD_MAX else x[:FIELD_MAX] + '...(+%d)' % (len(x) - FIELD_MAX)
    if isinstance(x, dict):
        return {k: _clip(v) for k, v in x.items()}
    if isinstance(x, (list, tuple)):
        return [_clip(v) for v in list(x)[:200]]
    return x


def init(directory):
    """Каталог журнала; продолжаем последний файл, если он не полон."""
    global _dir, _num, _size, _fh
    with _lock:
        os.makedirs(directory, exist_ok=True)
        _dir = directory
        nums = sorted(int(m.group(1)) for f in os.listdir(directory) for m in [re.match(r'^lab-(\d+)\.jsonl$', f)] if m)
        _num = nums[-1] if nums else 1
        _open(append=True)


def _path(n):
    return os.path.join(_dir, 'lab-%d.jsonl' % n)


def _open(append):
    global _fh, _size, _broken
    try:
        if _fh:
            _fh.close()
        _size = os.path.getsize(_path(_num)) if append and os.path.exists(_path(_num)) else 0
        if _size >= FILE_MAX:
            _roll()
            return
        _fh = open(_path(_num), 'ab')
    except OSError as e:
        _fh, _broken = None, True
        print('journal: %s' % e.__class__.__name__, file=sys.stderr)


def _roll():
    global _num, _rolled
    _num += 1
    for n in range(1, _num - FILES_MAX + 1):  # старые файлы сверх предела
        if os.path.exists(_path(n)):
            try:
                os.remove(_path(n))
            except OSError:
                pass
            if not _rolled:
                _rolled = True  # переполнение журнала записывается один раз
                _emit({'ts': _now(), 'src': 'journal', 'ev': 'journal.rollover', 'data': {'max_files': FILES_MAX, 'file_mb': FILE_MAX // 1048576}})
    _open(append=False)


def _now():
    return datetime.datetime.now().astimezone().isoformat(timespec='milliseconds')


def _emit(rec):
    global _size
    line = json.dumps(rec, ensure_ascii=False, default=str)
    if len(line) > REC_MAX:
        line = json.dumps({'ts': rec['ts'], 'src': rec['src'], 'ev': rec['ev'], 'data': {'truncated_chars': len(line)}}, ensure_ascii=False)
    _ring.append(rec)
    if _fh is None:
        return
    b = line.encode('utf-8', 'replace') + b'\n'
    try:
        _fh.write(b)
        _fh.flush()
        _size += len(b)
    except OSError:
        return
    if _size >= FILE_MAX:
        _roll()


def _flush_repeat():
    global _repeat
    if _repeat:
        n, _repeat = _repeat, 0
        _emit({'ts': _now(), 'src': _last_key[0], 'ev': _last_key[1], 'data': {'repeated': n}})


def log(src, ev, data=None, why=None):
    """Одна запись: {"ts","src","ev","data","why"}. Одинаковые подряд сворачиваются в «repeated N»."""
    global _last_key, _repeat
    rec = {'ts': _now(), 'src': src, 'ev': ev}
    if data is not None:
        rec['data'] = _clip(mask(data))
    if why:
        rec['why'] = _clip(mask(str(why)))
    key = (src, ev, json.dumps(rec.get('data'), sort_keys=True, default=str), rec.get('why'))
    with _lock:
        if key == _last_key:
            _repeat += 1
            return
        _flush_repeat()
        _last_key = key
        _emit(rec)


def tail(n=200):
    with _lock:
        _flush_repeat()
        return list(_ring)[-max(1, min(int(n), RING_MAX)):]


def flush():
    with _lock:
        _flush_repeat()
        if _fh:
            try:
                _fh.flush()
            except OSError:
                pass
