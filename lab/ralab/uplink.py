"""Выбор пути для общего входа in-chan. Параллельно мерим delay всех путей через Clash API, лучший ставим в selector chan.
V3: канал (rounds) всегда ходит через in-chan; при обрыве - полный тест сразу, 2 провала проверки подряд - смена пути и сброс ssh. Таймера bus не используем (он один и занят раундом):
проверка текущего пути - поток-демон, который ждёт Event остановки.
"""
import concurrent.futures, threading, time

from . import journal
from .bus import bus

CHECK_S, FAILS_FULL, DELAY_MS, PENALTY_S, PIN_S = 30, 2, 3000, 120, 600


class Uplink:
    def __init__(self, ctx):
        self.ctx, self.current, self.results, self.last_test = ctx, None, {}, 0.0
        self._pen, self._fails, self._gen, self._need, self._pin = {}, 0, 0, False, 0.0
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
        if self._single():
            self._need = False
            self._spawn(self._full)  # V3: путь выбираем до раунда (rounds ждёт uplink.selected)
        threading.Thread(target=self._safe, args=(self._loop, self._gen), daemon=True).start()

    def _on_down(self, ev):
        if ev.get('restart'):  # restart=True - просто смена раунда
            return
        if self._single():
            if not ev.get('dropped'):  # dropped: путь уже выбран здесь (2 провала или switch)
                self._spawn(self._full)
        else:
            self._need = True

    def _on_round_done(self, _):
        if self._need:
            self._need = False
            self._spawn(self._full)

    def _on_exited(self, _):
        self._gen += 1  # цикл проверки старого sing-box заканчивается
        self.current = None

    def _single(self):
        r = getattr(self.ctx, 'rounds', None)
        return bool(r and r.single())

    def refresh(self):
        self._spawn(self._full)

    def force(self, path):
        """ra-lab switch в SINGLE: путь в selector, канал сбросить, закрепить на PIN_S (автосмены нет, кроме обрыва)."""
        if path not in self._names() or not self.ctx.singbox.select('chan', path):
            journal.log('uplink', 'force.failed', {'path': path}, 'путь неизвестен или selector не переключился')
            return False
        self.current, self._fails, self._pin = path, 0, time.monotonic() + PIN_S
        journal.log('uplink', 'force', {'path': path}, 'путь закреплён на %d мин: %s' % (PIN_S // 60, path))
        r = self.ctx.rounds
        if not r.drop_channel('команда ассистента: путь ' + path):
            r._begin('команда ассистента: путь ' + path)
        return True

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
                self._fails = 0
                if self._single():
                    old = self.current
                    if time.monotonic() < self._pin:
                        continue  # закреплён командой switch
                    self._full()  # лучший - в selector (current обновляется там)
                    if self.current and self.current != old:
                        bus.publish('rounds.drop', {'reason': 'путь %s -> %s' % (old, self.current)})  # сброс - на потоке шины
                    continue
                r = getattr(self.ctx.rounds, 'round', None)
                if r is None or r.finished:
                    self._full()  # раунд не идёт: перевыбор сразу
                else:
                    self._need = True  # раунд идёт: тест по round.done

    def status(self):
        top = sorted(((n, ms) for n, ms in self.results.items() if ms is not None), key=lambda kv: kv[1])[:10]
        return {'current': self.current, 'results': dict(top), 'penalized': self._penalized(), 'last_test': self.last_test}
