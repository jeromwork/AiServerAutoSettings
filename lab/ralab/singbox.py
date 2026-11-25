"""sing-box: запуск, перезапуск по событию выхода, клиент Clash API (delay, выбор selector).

Родного уведомления о готовности у sing-box нет (gRPC-клиента у нас нет), поэтому событие singbox.started - это строка
журнала sing-box "sing-box started" (box.go: Start). Таймера ожидания нет: sing-box либо пишет её, либо выходит.
Конфиг с секретами лежит в <home>\\private\\ (не в state\\ и не в logs\\, их копирует СТОП.cmd).
"""
import collections, http.client, json, os, re, secrets, shutil, threading, urllib.parse

from . import journal, paths as pth, procs
from .bus import bus

ANSI = re.compile(r'\x1b\[[0-9;]*m')
RESTARTS_MAX = 5  # перезапусков подряд без "started"
BIND_RETRIES_MAX = 8
BIND_RX = re.compile(r'bind:|listen (tcp|udp)|address already in use|forbidden by its access permissions', re.I)
DELAY_URL = 'https://www.gstatic.com/generate_204'


class SingBox:
    def __init__(self, ctx):
        self.ctx, self.ports, self.clash_port, self._secret = ctx, {}, 0, ''
        self.fails, self.bind_retries, self.up, self.failed, self.stopping, self.relaunch = 0, 0, False, False, False, False
        self.tail = collections.deque(maxlen=8)
        bus.subscribe('settings.loaded', self._on_settings)
        bus.subscribe('proc.exited', self._on_proc)
        bus.subscribe('singbox.exited', self._on_exited)
        bus.subscribe('net.changed', self._on_net)
        bus.subscribe('app.stop', self._on_stop)
        bus.subscribe('singbox.started', self._on_started)
        bus.subscribe('singbox.tun', self._on_tun)
        self.with_tun = False
        self.traffic = {'up_bps': 0, 'down_bps': 0, 'active': False}

    def _on_settings(self, _):
        if procs.get('singbox'):  # пути изменились (VPN): гасим старый, новый запустится по событию выхода
            self.relaunch = True
            journal.log('singbox', 'relaunch', None, 'пути изменились: перезапуск sing-box')
            procs.kill('singbox')
            return
        self.failed, self.fails, self.bind_retries = False, 0, 0
        self._launch()

    def _on_tun(self, _):
        """TUN готов войти в общий sing-box (или должен выйти): перезапуск, если состав изменился."""
        tun = getattr(self.ctx, 'tun', None)
        if not tun or self.stopping or not procs.get('singbox') or tun.wants() == self.with_tun:
            return
        self.relaunch = True
        journal.log('singbox', 'relaunch', {'tun': tun.wants()}, 'TUN %s общего sing-box: перезапуск' % ('входит в' if tun.wants() else 'выходит из'))
        procs.kill('singbox')

    def _on_stop(self, _):
        self.stopping = True

    def _on_net(self, _):
        if self.failed:  # после 5 неудач ждём смену сети или ассистента
            self.failed, self.fails, self.bind_retries = False, 0, 0
            self._launch()

    def _launch(self):
        s = self.ctx.settings
        if not s.paths:
            bus.publish('singbox.failed', {'reason': 'нет путей: %s' % '; '.join('%s - %s' % kv for kv in s.skipped.items())[:300]})
            self.failed = True
            return
        ps = pth.free_ports(len(s.paths) + 2)
        self.ports = {p['name']: ps[i] for i, p in enumerate(s.paths)}
        if 'chan' not in self.ports:
            self.ports['chan'] = ps[-2]  # общий вход канала (selector chan); имя пути 'chan' в paths.make_config пропускается
        self.clash_port, self._secret = ps[-1], secrets.token_urlsafe(24)
        journal.register(self._secret)
        d = os.path.join(self.ctx.home, 'private')
        os.makedirs(d, exist_ok=True)
        cfg = os.path.join(d, 'singbox.json')
        conf = pth.make_config(s, self.ports, self.clash_port, self._secret)
        tun = getattr(self.ctx, 'tun', None)
        part = tun.launch_part() if tun else None
        self.with_tun = bool(part)
        if part:  # V11: TUN в том же процессе; правило TUN первым, чтобы его трафик не ушёл в пути
            conf['inbounds'].append(part[0])
            conf['outbounds'].append(part[1])
            conf['route']['rules'].insert(0, part[2])
        with os.fdopen(os.open(cfg, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w') as f:
            json.dump(conf, f)
        self.tail.clear()
        try:
            # с TUN - мягкая остановка (CTRL_BREAK): sing-box сам снимает адаптер и маршруты
            procs.start('singbox', [self._own_copy(s.singbox), 'run', '-c', cfg], on_err=self._line, cwd=d, graceful=self.with_tun)
        except (OSError, ValueError) as e:
            self.up = False
            bus.publish('singbox.exited', {'code': None, 'error': e.__class__.__name__})

    def _own_copy(self, exe):
        """Своя копия под другим именем: чужие VPN (Happ) по имени sing-box.exe считают процесс своим ядром и пускают его мимо туннеля."""
        dst = os.path.join(self.ctx.home, 'runtime', 'ralab-core.exe' if os.name == 'nt' else 'ralab-core')
        try:
            if not os.path.isfile(dst) or os.path.getsize(dst) != os.path.getsize(exe):
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copy2(exe, dst + '.tmp')
                os.replace(dst + '.tmp', dst)
            return dst
        except OSError as e:
            journal.log('singbox', 'copy.failed', {'error': e.__class__.__name__}, 'копия sing-box не сделана, запускаю как есть')
            return exe

    def _line(self, line):
        line = ANSI.sub('', line)  # sing-box красит журнал и в канал; отключить цвет в конфиге нельзя (поля нет)
        self.tail.append(line[-200:])
        if 'sing-box started' in line:
            self.fails, self.bind_retries, self.up = 0, 0, True
            bus.publish('singbox.started', {'paths': len(self.ports) - 1})

    def _on_proc(self, ev):
        if ev['name'] == 'singbox':
            self.up = False
            bus.publish('singbox.exited', {'code': ev['code']})

    def _on_exited(self, ev):
        if self.stopping:
            return
        if self.relaunch:
            self.relaunch, self.fails, self.bind_retries, self.failed = False, 0, 0, False
            self._launch()
            return
        if self.with_tun and getattr(self.ctx, 'tun', None):
            self.ctx.tun.crashed(ev.get('code'))  # следующий запуск - без TUN: канал важнее
        text = ' | '.join(self.tail)
        if BIND_RX.search(text) and self.bind_retries < BIND_RETRIES_MAX:
            self.bind_retries += 1
            journal.log('singbox', 'bind.retry', {'n': self.bind_retries}, 'sing-box: порт занят, перезапуск на новых портах (%d/%d): %s'
                        % (self.bind_retries, BIND_RETRIES_MAX, text[-200:]))
            self._launch()
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
        c = http.client.HTTPConnection('127.0.0.1', self.clash_port, timeout=8)
        try:
            c.request(method, url, body=json.dumps(body) if body is not None else None,
                      headers={'Authorization': 'Bearer ' + self._secret, 'Content-Type': 'application/json'})
            r = c.getresponse()
            return r.status, r.read()
        finally:
            c.close()

    def delay(self, path, timeout_ms=5000):
        """-> (мс|None, http-код). 503/504 - проверка не прошла."""
        try:
            st, data = self._req('GET', '/proxies/%s/delay?url=%s&timeout=%d' % (urllib.parse.quote(path, safe=''), urllib.parse.quote(DELAY_URL, safe=''), timeout_ms))
            return (json.loads(data).get('delay') if st == 200 else None), st
        except (OSError, ValueError, http.client.HTTPException):
            return None, 0

    def select(self, selector, path):
        """PUT /proxies/<selector> {"name": путь} - переключение без перезапуска (этап 3)."""
        try:
            return self._req('PUT', '/proxies/' + urllib.parse.quote(selector, safe=''), {'name': path})[0] in (200, 204)
        except (OSError, http.client.HTTPException):
            return False

    # --- индикатор передачи: потоковый GET /traffic Clash API (раз в секунду {"up","down"} байт/с, локально, без таймеров) ---
    def _on_started(self, _):
        threading.Thread(target=self._traffic_loop, args=(self.clash_port, self._secret), daemon=True).start()

    def _traffic_loop(self, port, secret):
        c = http.client.HTTPConnection('127.0.0.1', port)
        try:
            c.request('GET', '/traffic', headers={'Authorization': 'Bearer ' + secret})
            r = c.getresponse()
            while r.status == 200 and port == self.clash_port:  # новый sing-box - новый порт, старый поток завершается сам
                line = r.readline()
                if not line:
                    break
                d = json.loads(line)
                up, down = int(d.get('up', 0)), int(d.get('down', 0))
                was = self.traffic['active']
                self.traffic = {'up_bps': up, 'down_bps': down, 'active': up + down > 2048}  # выше фона keepalive (~десятки байт/с)
                if was != self.traffic['active']:
                    journal.log('singbox', 'traffic', self.traffic, 'идёт передача' if self.traffic['active'] else 'передача закончилась')
        except (OSError, ValueError, http.client.HTTPException):
            pass
        finally:
            c.close()
            if port == self.clash_port:
                self.traffic = {'up_bps': 0, 'down_bps': 0, 'active': False}

    def status(self):
        return {'up': self.up, 'failed': self.failed, 'restarts': self.fails, 'paths': len(self.ports) - 1, 'traffic': self.traffic}
