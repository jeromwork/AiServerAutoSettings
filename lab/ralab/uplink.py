"""Выбор пути для общего входа in-chan (V2: наблюдение). Параллельно мерим delay всех путей через Clash API, лучший ставим в selector chan.
Канал (rounds) пока ходит через in-<путь>, selector на поведение не влияет. Таймера bus не используем (он один и занят раундом):
проверка текущего пути - поток-демон, который ждёт Event остановки.
"""
import concurrent.futures, threading, time

from . import journal
from .bus import bus

CHECK_S, FAILS_FULL, DELAY_MS, PENALTY_S = 30, 2, 3000, 120


class Uplink:
    def __init__(self, ctx):
        self.ctx, self.current, self.results, self.last_test = ctx, None, {}, 0.0
        self._pen, self._fails, self._gen, self._need = {}, 0, 0, False
        self._lock, self._stop = threading.Lock(), threading.Event()
        bus.subscribe('singbox.started', self._on_started)
        bus.subscribe('channel.down', self._on_down)
        bus.subscribe('round.done', self._on_round_done)
        bus.subscribe('singbox.exited', self._on_exited)
        bus.subscribe('app.stop', lambda _: self._stop.set())

    def _spawn(self, fn, *a):
        threading.Thread(target=self._safe, args=(fn,) + a, daemon=True).start()

    def _safe(self, fn, *a):
        try:
            fn(*a)
        except Exception as e:
            journal.log('uplink', 'error', {'error': e.__class__.__name__, 'text': str(e)[:200]})

    def _on_started(self, _):
        self._gen += 1
        self.current, self._fails, self._need = None, 0, True  # тест - после раунда, чтобы не смещать победителя
        threading.Thread(target=self._safe, args=(self._loop, self._gen), daemon=True).start()

    def _on_down(self, ev):
        if not ev.get('restart'):  # restart=True - просто смена раунда
            self._need = True

    def _on_round_done(self, _):
        if self._need:
            self._need = False
            self._spawn(self._full)

    def _on_exited(self, _):
        self._gen += 1  # цикл проверки старого sing-box заканчивается
        self.current = None

    def penalize(self, path, seconds=PENALTY_S):
        self._pen[path] = time.monotonic() + seconds

    def _penalized(self):
        now = time.monotonic()
        return sorted(p for p, t in list(self._pen.items()) if t > now)

    def _names(self):
        return [n for n in self.ctx.singbox.ports if n != 'chan']

    def _full(self):
        if self._stop.is_set():
            return
        if not self._lock.acquire(blocking=False):
            return  # полный тест уже идёт
        try:
            sb, gen = self.ctx.singbox, self._gen
            skip = self._penalized()
            names = [n for n in self._names() if n not in skip]
            if not names:
                journal.log('uplink', 'allfail', {'tested': 0, 'penalized': skip}, 'нет путей для теста')
                return
            with concurrent.futures.ThreadPoolExecutor(max_workers=16) as ex:
                res = dict(zip(names, ex.map(lambda n: sb.delay(n, DELAY_MS)[0], names)))
            if gen != self._gen:
                return  # sing-box перезапускался за время теста
            self.results, self.last_test = res, time.time()
            ok = {n: ms for n, ms in res.items() if ms is not None}
            if not ok:
                journal.log('uplink', 'allfail', {'tested': len(res)}, 'ни один путь не прошёл проверку: selector не меняю')
                return
            best = min(ok, key=ok.get)
            if sb.select('chan', best):
                self.current, self._fails = best, 0
            bus.publish('uplink.selected', {'path': best, 'ms': ok[best], 'tested': len(res), 'ok': len(ok)})
        finally:
            self._lock.release()

    def _loop(self, gen):
        while not self._stop.wait(CHECK_S) and gen == self._gen:
            if self.current is None:
                continue
            ms = self.ctx.singbox.delay(self.current, DELAY_MS)[0]
            self._fails = 0 if ms is not None else self._fails + 1
            if ms is None:
                journal.log('uplink', 'check.failed', {'path': self.current, 'n': self._fails})
            if self._fails >= FAILS_FULL:
                self._fails = 0  # V2: канал не трогаем
                r = getattr(self.ctx.rounds, 'round', None)
                if r is None or r.finished:
                    self._full()  # раунд не идёт: перевыбор сразу
                else:
                    self._need = True  # раунд идёт: тест по round.done

    def status(self):
        top = sorted(((n, ms) for n, ms in self.results.items() if ms is not None), key=lambda kv: kv[1])[:10]
        return {'current': self.current, 'results': dict(top), 'penalized': self._penalized(), 'last_test': self.last_test}
