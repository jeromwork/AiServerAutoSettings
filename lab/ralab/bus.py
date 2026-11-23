"""Шина событий (раздел 2): очередь до 1000, подписки, один поток-разносчик, ОДИН таймер round.end (60 с).

publish() не блокирует: при полной очереди событие отбрасывается, переполнение пишется один раз (флаг сбрасывается при 500).
Каждое событие пишется в журнал. Каждые 1000 событий вызывается tick_hook (проверка памяти).
"""
import collections, sys, threading, time, traceback

from . import journal

QUEUE_MAX, QUEUE_RESET, TICK_EVERY = 1000, 500, 1000
LAST_TOPICS = ('agent.ready', 'singbox.started', 'channel.up')  # last() только для них
TIMER_NAME = 'round.end'


def rss_bytes():
    """Память процесса: Windows GetProcessMemoryInfo, Linux resource."""
    try:
        if sys.platform == 'win32':
            import ctypes
            from ctypes import wintypes

            class PMC(ctypes.Structure):
                _fields_ = [('cb', wintypes.DWORD), ('PageFaultCount', wintypes.DWORD)] + [(n, ctypes.c_size_t) for n in (
                    'PeakWorkingSetSize', 'WorkingSetSize', 'QuotaPeakPagedPoolUsage', 'QuotaPagedPoolUsage',
                    'QuotaPeakNonPagedPoolUsage', 'QuotaNonPagedPoolUsage', 'PagefileUsage', 'PeakPagefileUsage')]
            k32, ps = ctypes.WinDLL('kernel32'), ctypes.WinDLL('psapi')
            k32.GetCurrentProcess.restype = wintypes.HANDLE
            ps.GetProcessMemoryInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(PMC), wintypes.DWORD]
            c = PMC()
            c.cb = ctypes.sizeof(PMC)
            return int(c.WorkingSetSize) if ps.GetProcessMemoryInfo(k32.GetCurrentProcess(), ctypes.byref(c), c.cb) else 0
        import resource
        return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * 1024
    except Exception:
        return 0


class Guard:
    def __init__(self, bus, gen, name):
        self._bus, self._gen, self.name = bus, gen, name

    def cancel(self):
        self._bus._cancel(self._gen, self.name)


class Bus:
    def __init__(self):
        self._cv = threading.Condition()
        self._q = collections.deque()
        self._subs, self._last = [], {}
        self._overflow = False
        self.count = 0
        self.tick_hook = None
        self._tcv = threading.Condition()
        self._timer, self._gen = None, 0
        self._threads = False

    def subscribe(self, pattern, fn):
        """pattern: 'тема', 'префикс.*' или '*'."""
        with self._cv:
            self._subs.append((pattern, fn))

    def publish(self, topic, data=None):
        drop = False
        with self._cv:
            if topic in LAST_TOPICS:
                self._last[topic] = data
            if len(self._q) >= QUEUE_MAX:
                drop = not self._overflow
                self._overflow = True
                note = True
            else:
                self._q.append(('ev', topic, data, None))
                self._cv.notify()
                note = False
        if note and drop:
            journal.log('bus', 'queue.overflow', {'max': QUEUE_MAX, 'dropped_topic': topic}, 'очередь полна: события отбрасываются до спада до %d' % QUEUE_RESET)

    def last(self, topic):
        return self._last.get(topic) if topic in LAST_TOPICS else None

    def guard(self, name, seconds, fn):
        """Единственный таймер лаборатории (Б, конец раунда). fn вызывается в потоке-разносчике, строго по порядку с событиями."""
        if name != TIMER_NAME:
            raise ValueError('таймеры, кроме %s, запрещены' % TIMER_NAME)
        with self._tcv:
            self._gen += 1
            gen = self._gen
            self._timer = (time.monotonic() + seconds, fn, gen, name)
            self._tcv.notify()
        journal.log('bus', 'timer.armed', {'name': name, 'seconds': seconds})
        return Guard(self, gen, name)

    def _cancel(self, gen, name):
        with self._tcv:
            if self._timer and self._timer[2] == gen:
                self._timer = None
                self._tcv.notify()
                journal.log('bus', 'timer.cancelled', {'name': name})

    def start(self):
        if self._threads:
            return
        self._threads = True
        threading.Thread(target=self._run, name='bus', daemon=True).start()
        threading.Thread(target=self._timer_loop, name='bus-timer', daemon=True).start()

    def _timer_loop(self):
        while True:
            with self._tcv:
                while True:
                    t = self._timer
                    if t is None:
                        self._tcv.wait()  # таймер не взведён: ждём guard()
                    else:
                        left = t[0] - time.monotonic()
                        if left <= 0:
                            self._timer = None
                            break
                        # ЕДИНСТВЕННЫЙ таймер лаборатории (Б): у замёрзшего пути нет события «замёрз»,
                        # поэтому конец раунда измерений определяет срок; успех он никогда не объявляет.
                        self._tcv.wait(left)
            with self._cv:  # вызов таймера не теряется при полной очереди: в очереди он один
                self._q.append(('call', t[3], None, t[1]))
                self._cv.notify()

    def _run(self):
        while True:
            with self._cv:
                while not self._q:
                    self._cv.wait()
                kind, topic, data, fn = self._q.popleft()
                if self._overflow and len(self._q) <= QUEUE_RESET:
                    self._overflow = False
                subs = list(self._subs)
            if kind == 'call':
                journal.log('bus', 'timer.fired', {'name': topic}, 'срок вышел: события нет, раунд закрываем по таймеру Б')
                self._safe(fn, topic)
                continue
            journal.log(topic.split('.')[0], topic, data)
            for pattern, f in subs:
                if pattern == topic or pattern == '*' or (pattern.endswith('.*') and topic.startswith(pattern[:-1])):
                    self._safe(f, topic, data)
            self.count += 1
            if self.count % TICK_EVERY == 0 and self.tick_hook:
                self._safe(self.tick_hook, 'bus.tick')

    def _safe(self, fn, topic, *args):  # подписчик: fn(data); таймер и tick_hook: fn()
        try:
            fn(*args)
        except Exception:
            journal.log('bus', 'subscriber.error', {'topic': topic, 'fn': getattr(fn, '__qualname__', repr(fn)),
                                                    'trace': traceback.format_exc()[-1500:]})


bus = Bus()
