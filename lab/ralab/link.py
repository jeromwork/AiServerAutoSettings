"""Связь с EXE: Python -> EXE JSON-строки в stdout, EXE -> Python JSON-строки в stdin (EOF stdin = остановка).

stdout: {"t":"state","color":"grey|yellow|green|red","tip":"<=63","lines":[<=50 строк по <=300]},
        {"t":"good","version":"..."} (один раз, на первый channel.up), {"t":"report","text":"..."} (<=64 КБ, ответ на запрос отчёта).
stdin:  {"t":"exit"}, {"t":"report"}.
В stdout пишет только этот модуль (sys.stdout после старта указывает на stderr). Секретов нет: всё проходит journal.mask().
"""
import json, sys, threading

from . import journal
from .bus import bus

LINES_MAX, LINE_MAX, TIP_MAX, REPORT_MAX = 50, 300, 63, 64000


class Link:
    def __init__(self, ctx):
        self.ctx, self.out, self.lock = ctx, sys.stdout, threading.Lock()
        sys.stdout = sys.stderr  # случайный print не должен портить поток протокола
        self.color, self.tip, self.note, self.last, self.good_sent = 'grey', 'Запуск', 'запуск', None, False
        attach(self)
        bus.subscribe('app.start', self._on_start)
        bus.subscribe('link.report_request', self._on_report)

    def _send(self, obj):
        line = json.dumps(obj, ensure_ascii=True, separators=(',', ':'))
        with self.lock:
            try:
                self.out.write(line + '\n')
                self.out.flush()
            except (OSError, ValueError):
                pass

    def _on_start(self, _):
        threading.Thread(target=self._read, name='link-in', daemon=True).start()
        self._refresh()

    def _read(self):
        try:
            for raw in sys.stdin:
                try:
                    t = json.loads(raw).get('t')
                except (ValueError, AttributeError):
                    continue
                if t == 'exit':
                    bus.publish('app.stop', {'reason': 'команда exit от EXE'})
                elif t == 'report':
                    bus.publish('link.report_request')
        except (OSError, ValueError):
            pass
        bus.publish('app.stop', {'reason': 'EOF stdin: EXE закрыл связь'})

    def _on_report(self, _):
        self._send({'t': 'report', 'text': journal.mask(self.ctx.report())[:REPORT_MAX]})

    def _refresh(self):
        ctx, r = self.ctx, self.ctx.rounds.status() if getattr(self.ctx, 'rounds', None) else {}
        ch = r.get('channel')
        lines = ['Код: %s, EXE: %s' % (ctx.version, ctx.exe_version or '-')]
        if ctx.rollback:
            lines.append('Откат версии: ' + ctx.rollback)
        lines.append(self.note)
        if ch:
            lines.append('Канал: %s (порт сервера %s)' % (ch['path'], ch['rport']))
        for x in (r.get('ranking') or [])[:12]:
            lines.append('%s: %s %s' % (x['path'], x['outcome'], '%d КиБ/с' % (x['down_bps'] // 1024) if x.get('down_bps') else (x.get('reason') or '')[:80]))
        lan = getattr(ctx, 'lan', None)
        for s in (lan.status() if lan else [])[:20]:
            lines.append('Сеть %s: %s %s' % (s['name'], s['status'], s['detail']))
        lines = [journal.mask(l)[:LINE_MAX] for l in lines][:LINES_MAX]
        msg = {'t': 'state', 'color': self.color, 'tip': self.tip[:TIP_MAX], 'lines': lines}
        key = json.dumps(msg, sort_keys=True)
        if key != self.last:
            self.last = key
            self._send(msg)

    def set(self, color, tip, note=None):
        self.color, self.tip, self.note = color, tip, note or tip

    def handle(self, topic, ev):
        s = self.ctx.settings if getattr(self.ctx, 'settings', None) else None
        if topic == 'settings.failed':
            self.set('red', 'Настройки: ' + ev['reason'], 'Настройки не прочитаны: ' + ev['reason'])
        elif topic == 'settings.loaded':
            self.set('grey', 'Запуск sing-box', 'Настройки прочитаны: путей %d, сетей %d' % (len(ev['paths']), len(ev['lans'])))
        elif topic in ('singbox.started', 'channel.down') or (topic == 'round.done' and not ev.get('winner') and not self.ctx.rounds.channel):
            self.set('yellow', 'Ищу путь', 'Ищу путь к серверу (раунд %d)' % self.ctx.rounds.rn if self.ctx.rounds.rn else 'Ищу путь')
        elif topic == 'singbox.failed':
            self.set('red', 'sing-box: ' + ev['reason'], 'sing-box не запускается: ' + ev['reason'])
        elif topic == 'channel.up':
            self.set('green', 'Канал: ' + ev['path'], 'Канал ассистента работает через ' + ev['path'])
            if not self.good_sent:
                self.good_sent = True
                self._send({'t': 'good', 'version': self.ctx.version})
        self._refresh()


def attach(link):
    """Подписки с темой: bus передаёт подписчику только данные, поэтому по одной функции на тему."""
    for t in ('settings.loaded', 'settings.failed', 'singbox.started', 'singbox.failed', 'channel.up', 'channel.down', 'round.done',
              'lan.result', 'path.ok', 'path.failed', 'agent.ready', 'singbox.exited'):
        bus.subscribe(t, lambda ev, t=t: link.handle(t, ev or {}))
