"""Диск-движок: тот же Syncthing (та же база и Device ID) под Лабораторией, пока старая Программа выгружена.
Источники (только чтение): диск - config.json disk.home или %LOCALAPPDATA%\\RemoteDisk (tray\\syncthingtray.exe, state\\config.xml);
syncPort - <установленная>\\state\\transport-ports.json:effective.syncPort, иначе config.json transport.syncPort, иначе 22001;
серверный порт - transport.channelPath (или secrets\\channel-disk-*.json) :inbounds[tag=sync].override_port (читается только он).
Состояние меняется только на потоке шины; поток-тикер раз в 10 с лишь публикует disk.tick с результатом проверки (не занят ли Диск
старой Программой; t0 - когда она началась). Запуск (и перезапуск) - только после свежей (<=15 с) проверки, начатой ПОСЛЕ выхода нашего
движка и перед тем взятого мьютекса Global\\RemoteDiskEngine-<sha256(home)> без ожидания. Выход, после которого Диск занят - уступка Программе. Падение движка: пауза 30 с, дальше вдвое (до 5 мин), после 5 подряд - ошибка до смены сети.
"""
import glob, hashlib, json, os, re, socket, subprocess, sys, threading, time

from . import bins, journal, procs
from .bus import bus

WIN = sys.platform == 'win32'
FAILS_MAX, TICK, PROBE_EVERY, STABLE, FRESH = 5, 10, 6, 120, 15
ST_TEXT = {'absent': 'не установлен', 'program': 'ведёт Программа', 'running': 'работает', 'error': 'ошибка', 'wait': 'ждёт проверки/канала'}


def _json(path):
    try:
        with open(path, encoding='utf-8-sig') as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _port(v):
    try:
        v = int(v)
    except (TypeError, ValueError):
        return 0
    return v if 1 <= v <= 65535 else 0


def find(installed, cfg):
    """-> dict(exe, state, sync, srv) или None, если Диск не установлен или нет любого из трёх."""
    home = os.path.expandvars((cfg.get('disk') or {}).get('home') or '') or os.path.join(os.environ.get('LOCALAPPDATA') or '', 'RemoteDisk')
    state = os.path.join(home, 'state')
    if bins.strict():  # только вшитая копия
        exe = bins.find('syncthingtray/syncthingtray.exe')
        if not exe:
            bins.report('syncthingtray', 'вшитый значок Диска недоступен: %s' % (bins.why('syncthingtray/syncthingtray.exe') or 'файла нет в папке программы'))
            return None
    else:
        bins.warn_old()
        exe = os.path.join(home, 'tray', 'syncthingtray.exe')
    if not os.environ.get('LOCALAPPDATA') and not (cfg.get('disk') or {}).get('home'):
        return None
    if not (os.path.isfile(exe) and os.path.isfile(os.path.join(state, 'config.xml'))):
        return None
    t = cfg.get('transport') or {}
    st = _json(os.path.join(installed, 'state', 'transport-ports.json'))
    sync = _port((st.get('effective') or {}).get('syncPort')) if st.get('schema') == 1 else 0
    sync = sync or _port(t.get('syncPort')) or 22001
    files = [t['channelPath']] if t.get('channelPath') else []
    files += sorted(glob.glob(os.path.join(installed, 'secrets', 'channel-disk-*.json')), key=lambda p: -os.path.getmtime(p))
    srv = 0
    for f in files:
        srv = next((_port(i.get('override_port')) for i in _json(f).get('inbounds') or [] if isinstance(i, dict) and i.get('tag') == 'sync'), 0)
        if srv:
            break
    return {'home': home, 'exe': exe, 'state': state, 'sync': sync, 'srv': srv} if srv else None


def listening(port):
    try:
        socket.create_connection(('127.0.0.1', port), 0.5).close()
        return True
    except OSError:
        return False


def foreign_running():
    """Есть syncthing(tray).exe (мы вызываем только когда свой движок не запущен)."""
    if not WIN:
        return False
    try:
        out = subprocess.run(['tasklist', '/FO', 'CSV', '/NH'], stdin=subprocess.DEVNULL, capture_output=True, timeout=10,
                             creationflags=procs.NO_WINDOW).stdout.decode('mbcs', 'replace').lower()
    except (OSError, subprocess.SubprocessError):
        return False
    return '"syncthingtray.exe"' in out or '"syncthing.exe"' in out


_PATH = re.compile(r'[A-Za-z]:[\\/][^\s"\']*|(?:\\\\|/)[^\s"\']+|"[^"]*"|\'[^\']*\'')


def safe_line(text):
    """Строка вывода Syncthing для журнала: только WARN/ERR, без путей и имён файлов (ПДн), не длиннее 120."""
    if not re.search(r'\b(WARN|WARNING|ERR|ERROR)\b', text):
        return None
    return _PATH.sub('<..>', text)[:120]


def engine_lock(home):
    """Мьютекс старой Программы без ожидания: -> (ok, handle). Не Windows - заглушка (True, None)."""
    if not WIN:
        return True, None
    import ctypes
    key = os.path.abspath(home).replace('/', '\\').rstrip('\\').lower()
    name = 'Global\\RemoteDiskEngine-' + hashlib.sha256(key.encode('utf-8')).hexdigest().upper()
    k = ctypes.WinDLL('kernel32', use_last_error=True)
    k.CreateMutexW.restype = ctypes.c_void_p
    k.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_wchar_p]
    k.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    k.ReleaseMutex.argtypes = k.CloseHandle.argtypes = [ctypes.c_void_p]
    h = k.CreateMutexW(None, 0, name)
    if not h:
        return False, None
    if k.WaitForSingleObject(h, 0) in (0, 0x80):  # WAIT_OBJECT_0 / WAIT_ABANDONED
        return True, (k, h)
    k.CloseHandle(h)
    return False, None


def engine_unlock(lock):
    if lock:
        lock[0].ReleaseMutex(lock[1])
        lock[0].CloseHandle(lock[1])


class Disk:
    def __init__(self, ctx):
        self.ctx, self.info, self.state, self.busy, self.up = ctx, None, 'absent', None, False
        self.fwd, self.running, self.stopping, self.ticker = None, False, False, False  # fwd: (sync, srv) открытого проброса
        self.fails, self.next_at, self.started_at, self.n = 0, 0.0, 0.0, 0
        self.exit_at, self.pending, self.probe_t0, self.probe_done, self.last_log = 0.0, False, 0.0, 0.0, 0.0
        bus.subscribe('settings.loaded', self._on_settings)
        bus.subscribe('channel.up', self._on_up)
        bus.subscribe('channel.down', self._on_down)
        bus.subscribe('disk.tick', self._on_tick)
        bus.subscribe('proc.exited', self._on_proc)
        bus.subscribe('net.changed', self._on_net)
        bus.subscribe('app.stop', self._on_stop)

    def _refind(self):
        st = getattr(self.ctx, 'settings', None)
        self.info = find(self.ctx.installed, st.cfg) if st else None
        return self.info

    def _on_settings(self, _):
        if self._refind() and not self.ticker:
            self.ticker = True
            threading.Thread(target=self._tick_loop, daemon=True).start()
        self._eval()

    def _on_up(self, _):
        self.up = True
        self._eval()

    def _on_down(self, _):
        self.up = False
        self._eval()

    def _on_net(self, _):
        if self.state == 'error':
            self.fails, self.next_at = 0, 0.0
            self._eval()

    def _on_stop(self, _):
        self.stopping = True

    def _tick_loop(self):  # не меняет состояние: проверяет внешний мир и публикует события
        while True:
            self.n += 1
            probe, i = None, self.info
            if i and not self.running and (self.up or self.pending or self.n % PROBE_EVERY == 1):
                t0 = time.monotonic()
                fwd = self.fwd
                probe = {'t0': t0, 'busy': bool((not fwd or fwd[0] != i['sync']) and listening(i['sync']) or foreign_running())}
            bus.publish('disk.tick', {'probe': probe})
            time.sleep(TICK)

    def _on_tick(self, ev):
        p = ev.get('probe')
        if p and p['t0'] >= self.exit_at:  # проверка начата после выхода нашего движка (иначе в ней мог быть он сам)
            self.busy, self.probe_t0, self.probe_done = p['busy'], p['t0'], time.monotonic()
            if self.pending:
                self.pending = False
                if p['busy']:  # старая Программа погасила наш Syncthing: уступаем, не ошибка
                    journal.log('disk', 'yield', None, 'после выхода Диск занят Программой: уступаем')
                else:
                    self._failed('Syncthing вышел')
        if self.running and time.monotonic() - self.started_at > STABLE:
            self.fails = 0
        self._eval()

    def _failed(self, why):
        self.fails += 1
        self.next_at = time.monotonic() + min(30 * 2 ** (self.fails - 1), 300)
        journal.log('disk', 'failed', {'fails': self.fails}, why + ': пауза до перезапуска')

    def _on_proc(self, ev):
        if ev['name'] != 'syncthing':
            return
        self.running = False
        self.busy, self.exit_at = None, time.monotonic()  # неизвестно, пока нет проверки после выхода
        if not (self.stopping or ev.get('killed')):
            self.pending = True
        self._eval()

    def _line(self, text):
        t = safe_line(text)
        if t and time.monotonic() - self.last_log > 2:
            self.last_log = time.monotonic()
            journal.log('disk', 'syncthing', {'line': t})

    def _set(self, state):
        if state != self.state:
            journal.log('disk', 'state', {'state': state})
            self.state = state

    def _eval(self):
        if self.stopping:
            return
        if self.running:
            return self._set('running')
        i = self._refind()
        if not i:
            return self._set('absent')
        if self.pending or self.busy is None or time.monotonic() - self.probe_done > FRESH:
            return self._set('wait')  # неизвестно: нужна свежая проверка
        if self.busy:
            return self._set('program')
        if self.fails >= FAILS_MAX:
            return self._set('error')
        if not self.up or time.monotonic() < self.next_at:
            return self._set('wait')
        if not self.fwd or self.fwd[0] != i['sync'] or self.fwd[1] != i['srv']:
            if not self.ctx.forward.add_forward(i['sync'], '127.0.0.1', i['srv']):  # порт занят: кто-то ведёт Диск
                self.busy = True
                return self._set('program')
            self.fwd = (i['sync'], i['srv'])
        ok, lock = engine_lock(i['home'])
        if not ok:
            return self._set('wait')  # мьютекс занят старой Программой: не запускаем
        try:
            env = dict(os.environ, STMONITORED='yes')
            procs.start('syncthing', [i['exe'], 'syncthing', 'serve', '--home', i['state'], '--no-browser', '--no-restart'],
                        env=env, graceful=True, quiet=True, on_out=self._line, on_err=self._line)
        except (OSError, ValueError) as e:
            self._failed('запуск не удался (%s)' % e.__class__.__name__)
            return self._set('error' if self.fails >= FAILS_MAX else 'wait')
        finally:
            engine_unlock(lock)
        self.running, self.started_at = True, time.monotonic()
        self._set('running')

    def status(self):
        return 'Диск: %s' % ST_TEXT[self.state]
