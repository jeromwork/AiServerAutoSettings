"""sing-box: запуск, перезапуск по событию выхода, клиент Clash API (delay, выбор selector).

Родного уведомления о готовности у sing-box нет (gRPC-клиента у нас нет), поэтому событие singbox.started - это строка
журнала sing-box "sing-box started" (box.go: Start). Таймера ожидания нет: sing-box либо пишет её, либо выходит.
Конфиг с секретами лежит в <home>\\private\\ (не в state\\ и не в logs\\, их копирует СТОП.cmd).
"""
import collections, http.client, json, os, secrets, urllib.parse

from . import journal, paths as pth, procs
from .bus import bus

RESTARTS_MAX = 5  # перезапусков подряд без "started"
DELAY_URL = 'https://www.gstatic.com/generate_204'


class SingBox:
    def __init__(self, ctx):
        self.ctx, self.ports, self.clash_port, self._secret = ctx, {}, 0, ''
        self.fails, self.up, self.failed, self.stopping = 0, False, False, False
        self.tail = collections.deque(maxlen=8)
        bus.subscribe('settings.loaded', self._on_settings)
        bus.subscribe('proc.exited', self._on_proc)
        bus.subscribe('singbox.exited', self._on_exited)
        bus.subscribe('net.changed', self._on_net)
        bus.subscribe('app.stop', self._on_stop)

    def _on_settings(self, _):
        self._launch()

    def _on_stop(self, _):
        self.stopping = True

    def _on_net(self, _):
        if self.failed:  # после 5 неудач ждём смену сети или ассистента
            self.failed, self.fails = False, 0
            self._launch()

    def _launch(self):
        s = self.ctx.settings
        if not s.paths:
            bus.publish('singbox.failed', {'reason': 'нет путей: %s' % '; '.join('%s - %s' % kv for kv in s.skipped.items())[:300]})
            self.failed = True
            return
        ps = pth.free_ports(len(s.paths) + 1)
        self.ports = {p['name']: ps[i] for i, p in enumerate(s.paths)}
        self.clash_port, self._secret = ps[-1], secrets.token_urlsafe(24)
        journal.register(self._secret)
        d = os.path.join(self.ctx.home, 'private')
        os.makedirs(d, exist_ok=True)
        cfg = os.path.join(d, 'singbox.json')
        with os.fdopen(os.open(cfg, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w') as f:
            json.dump(pth.make_config(s, self.ports, self.clash_port, self._secret), f)
        self.tail.clear()
        try:
            procs.start('singbox', [s.singbox, 'run', '-c', cfg], on_err=self._line, cwd=d)
        except (OSError, ValueError) as e:
            self.up = False
            bus.publish('singbox.exited', {'code': None, 'error': e.__class__.__name__})

    def _line(self, line):
        self.tail.append(line[-200:])
        if 'sing-box started' in line:
            self.fails, self.up = 0, True
            bus.publish('singbox.started', {'paths': len(self.ports)})

    def _on_proc(self, ev):
        if ev['name'] == 'singbox':
            self.up = False
            bus.publish('singbox.exited', {'code': ev['code']})

    def _on_exited(self, ev):
        if self.stopping:
            return
        self.fails += 1
        if self.fails >= RESTARTS_MAX:
            self.failed = True
            bus.publish('singbox.failed', {'reason': '%d запусков подряд без "started": %s' % (self.fails, ' | '.join(self.tail)[-300:])})
        else:
            journal.log('singbox', 'restart', {'n': self.fails}, 'sing-box вышел (код %s): перезапуск, попытка %d из %d' % (ev.get('code'), self.fails, RESTARTS_MAX))
            self._launch()

    # --- Clash API (127.0.0.1, secret): без таймаута на нашей стороне, срок delay задаёт сам sing-box (timeout=5000) ---
    def _req(self, method, url, body=None):
        c = http.client.HTTPConnection('127.0.0.1', self.clash_port)
        try:
            c.request(method, url, body=json.dumps(body) if body is not None else None,
                      headers={'Authorization': 'Bearer ' + self._secret, 'Content-Type': 'application/json'})
            r = c.getresponse()
            return r.status, r.read()
        finally:
            c.close()

    def delay(self, path):
        """-> (мс|None, http-код). 503/504 - проверка не прошла."""
        try:
            st, data = self._req('GET', '/proxies/%s/delay?url=%s&timeout=5000' % (urllib.parse.quote(path, safe=''), urllib.parse.quote(DELAY_URL, safe='')))
            return (json.loads(data).get('delay') if st == 200 else None), st
        except (OSError, ValueError, http.client.HTTPException):
            return None, 0

    def select(self, selector, path):
        """PUT /proxies/<selector> {"name": путь} - переключение без перезапуска (этап 3)."""
        try:
            return self._req('PUT', '/proxies/' + urllib.parse.quote(selector, safe=''), {'name': path})[0] in (200, 204)
        except (OSError, http.client.HTTPException):
            return False

    def status(self):
        return {'up': self.up, 'failed': self.failed, 'restarts': self.fails, 'paths': len(self.ports)}
