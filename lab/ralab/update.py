"""Обновление и откат EXE по команде из трея. Только стандартная библиотека.

install(send): проверить релиз, скачать, сверить SHA-256, подменить файл (прежний остаётся .prev.exe), попросить EXE перезапуститься.
rollback(send): поменять местами текущий и прежний EXE. send(obj) шлёт JSON-сообщение в EXE.
Путь к EXE и его версия приходят аргументами --exe и --exe-version (читаются из sys.argv, app.py не трогаем).
"""
import argparse, hashlib, json, os, re, sys, threading, time, urllib.request

URL = 'https://api.github.com/repos/jeromwork/AiServerAutoSettings/releases/tags/lab-latest'
RX = re.compile(r'Последняя версия: (V[0-9.]+).*?SHA-256 ([0-9a-f]{64})', re.S)
MAX_SIZE = 400 * 1024 * 1024
_busy = threading.Lock()
_swapped = False  # подмена сделана, ждём перезапуска EXE: повторные команды ничего не трогают


class FsError(Exception):
    pass


def _args():
    p = argparse.ArgumentParser(add_help=False)
    p.add_argument('--exe', default='')
    p.add_argument('--exe-version', default='')
    a = p.parse_known_args(sys.argv[1:])[0]
    a.exe = os.environ.get('RA_EXE') or a.exe  # сначала переменные окружения от EXE, аргументы - запасной вариант
    a.exe_version = os.environ.get('RA_EXE_VERSION') or a.exe_version
    return a


def _vkey(v):
    return tuple(int(x) for x in re.findall(r'\d+', v))


def check():
    """-> (версия, sha256, url, размер). Исключения: OSError (сеть), ValueError (разбор)."""
    req = urllib.request.Request(URL, headers={'User-Agent': 'ra-update', 'Accept': 'application/vnd.github+json'})
    with urllib.request.urlopen(req, timeout=30) as r:
        rel = json.loads(r.read().decode('utf-8'))
    m = RX.search(rel.get('body') or '')
    if not m:
        raise ValueError('в описании релиза нет версии и SHA-256')
    ver, sha = m.group(1), m.group(2)
    name = 'RemoteAgents-Lab-%s.exe' % ver
    asset = next((a for a in rel.get('assets') or [] if a.get('name') == name), None)
    if not asset:
        raise ValueError('в релизе нет файла ' + name)
    dg = asset.get('digest') or ''
    if dg.startswith('sha256:') and dg[7:].lower() != sha:
        raise ValueError('SHA-256 в описании и у файла не совпали')
    url, size = asset.get('browser_download_url') or '', int(asset.get('size') or 0)
    if not url.startswith('https://github.com/'):
        raise ValueError('адрес файла не с github.com')
    if size < 0 or size > MAX_SIZE:
        raise ValueError('недопустимый размер файла: %d' % size)
    return ver, sha, url, size


def _download(url, size, dest, on_bytes=None):
    """Сеть -> OSError/ValueError, запись на диск -> FsError. SHA-256 проверяет вызывающий всегда (даже при size == 0)."""
    h, n = hashlib.sha256(), 0
    req = urllib.request.Request(url, headers={'User-Agent': 'ra-update'})
    with urllib.request.urlopen(req, timeout=30) as r:
        try:
            f = open(dest, 'wb')
        except OSError as e:
            raise FsError(e)
        with f:
            while True:
                b = r.read(1 << 16)
                if not b:
                    break
                n += len(b)
                if on_bytes:
                    on_bytes(n)
                if n > MAX_SIZE:
                    raise ValueError('файл больше допустимого размера')
                try:
                    f.write(b)
                except OSError as e:
                    raise FsError(e)
                h.update(b)
    if size and n != size:
        raise ValueError('размер файла %d, ожидалось %d' % (n, size))
    return h.hexdigest()


def _paths(exe):
    base = exe[:-4] if exe.lower().endswith('.exe') else exe
    return exe, base + '.prev.exe', base + '.new'


def _rm(p):
    try:
        os.remove(p)
    except FileNotFoundError:
        pass


def _notice(send, text):
    send({'t': 'notice', 'text': text})


def _progress(send, text):
    send({'t': 'update-progress', 'text': text[:24]})


def _guard(fn, send):
    def run():
        global _swapped
        if not _busy.acquire(blocking=False):
            _notice(send, 'Уже обновляю')
            return
        mine = False
        try:
            if _swapped:
                return _notice(send, 'Уже обновляю')
            mine = True
            if fn(send):
                _swapped = True
        except FsError as e:
            _notice(send, 'Не удалось записать файл: %s' % str(e)[:120])
        except OSError as e:
            _notice(send, 'Нет связи с GitHub: %s' % str(e)[:120])
        except Exception as e:
            _notice(send, 'Ошибка: %s' % str(e)[:160])
        finally:
            if mine and not _swapped:
                _progress(send, '')
            _busy.release()
    if _busy.locked() or _swapped:
        _notice(send, 'Уже обновляю')
        return
    threading.Thread(target=run, name='update', daemon=True).start()


def _install(send):
    _progress(send, 'Проверяю версию…')
    a = _args()
    if not a.exe or not os.path.isfile(a.exe):
        return _notice(send, 'Ошибка: не знаю, где лежит программа')
    try:
        ver, sha, url, size = check()
    except OSError as e:
        return _notice(send, 'Нет связи с GitHub: %s' % str(e)[:120])
    cur = a.exe_version.split('-')[0]
    if cur and _vkey(ver) <= _vkey(cur):
        return _notice(send, 'Уже последняя версия ' + ver)
    _notice(send, 'Обновляю до %s…' % ver)
    last = {'t': 0.0, 'v': None}

    def on_bytes(done):
        v = (done * 100 // size) if size else done // (1 << 20)
        now = time.monotonic()
        if v != last['v'] and now - last['t'] >= 0.5:
            last['t'], last['v'] = now, v
            _progress(send, ('Скачиваю %s: %d%%' % (ver, v)) if size else ('Скачиваю %s: %d МБ' % (ver, v)))
    exe, prev, new = _paths(a.exe)
    try:
        got = _download(url, size, new, on_bytes)
    except FsError as e:
        _rm(new)
        return _notice(send, 'Не удалось записать файл: %s' % str(e)[:120])
    except OSError as e:
        _rm(new)
        return _notice(send, 'Нет связи с GitHub: %s' % str(e)[:120])
    except ValueError as e:
        _rm(new)
        return _notice(send, 'Ошибка: ' + str(e))
    _progress(send, 'Проверяю файл %s' % ver)
    if got != sha:
        _rm(new)
        return _notice(send, 'Ошибка: файл не совпал по SHA-256')
    moved = False
    _progress(send, 'Устанавливаю %s' % ver)
    try:
        _rm(prev)
        os.replace(exe, prev)
        moved = True
        os.replace(new, exe)
    except OSError as e:
        try:
            if moved and not os.path.exists(exe):
                os.replace(prev, exe)
        except OSError:
            pass
        _rm(new)
        return _notice(send, 'Не удалось записать файл: %s' % str(e)[:120])
    _progress(send, 'Перезапуск в %s…' % ver)
    send({'t': 'restart-exe'})
    return True


def _rollback(send):
    a = _args()
    if not a.exe:
        return _notice(send, 'Ошибка: не знаю, где лежит программа')
    exe, prev, _ = _paths(a.exe)
    if not os.path.isfile(prev):
        return _notice(send, 'Предыдущей версии нет')
    tmp = exe + '.tmp'
    step = 0
    try:
        _rm(tmp)
        os.replace(exe, tmp)
        step = 1
        os.replace(prev, exe)
        step = 2
        os.replace(tmp, prev)
    except OSError as e:
        try:
            if step == 2:
                os.replace(exe, prev)
                step = 1
            if step == 1:
                os.replace(tmp, exe)
        except OSError:
            pass
        return _notice(send, 'Не удалось записать файл: %s' % str(e)[:120])
    send({'t': 'restart-exe'})
    return True


def install(send):
    _guard(_install, send)


def rollback(send):
    _guard(_rollback, send)
