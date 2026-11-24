"""VPN Лаборатории: весь интернет через туннель (Россия - напрямую), отдельный процесс sing-box ralab-vpn.exe с адаптером ralab-vpn.

Режим (state\\vpn.json, команда `ra-lab vpn off|auto|only`): off - выключен (по умолчанию); auto - включается сам, если нет чужого VPN,
и уступает любому чужому; only - только наш: при чужом VPN не включается и просит его отключить.
Отдельный процесс: его падение не трогает канал, Диск и сети клиники. Маршруты 0/1 + 128/1 (не 0/0): «интернет по умолчанию» для
канала (auto_detect_interface) остаётся на Wi-Fi/Ethernet. Мимо туннеля: частные сети, Tailscale, мосты и сервер, DNS-серверы ПК и
1.1.1.1 (по нему paths.vpn_iface видит чужой VPN и при включённом нашем). DNS ПК не трогаем (dns_mode disabled).
Fail-open: процесс вышел сам или 2 проверки через туннель подряд не прошли - процесс снимается, интернет идёт напрямую;
3 сбоя подряд - VPN выключен до новой команды. Выход/падение Python: Job Object гасит sing-box, адаптер исчезает вместе с ним;
при запуске оставшийся адаптер ralab-vpn* удаляется (имя - защита от чужих адаптеров).
Журнал sing-box VPN в общий журнал не пишется (там адреса сайтов): в памяти последние ошибки, они попадают в причину сбоя.
"""
import collections, copy, http.client, ipaddress, json, os, re, secrets, shutil, socket, threading, time, urllib.request

from . import journal, paths as pth, procs
from .bus import bus
from .tun import WINTUN_ID, _ps, _run

NAME, IFACE, EXE = 'vpn', 'ralab-vpn', 'ralab-vpn.exe'
MODES = {'off': 'выключен', 'auto': 'авто', 'only': 'только наш'}
CHECK_S, CHECK_FAILS, FAILS_MAX, RETRY_S, STABLE_S, START_S = 10, 2, 3, 60, 300, 25
CHECK_URL = 'http://www.gstatic.com/generate_204'
GEOIP_URL = 'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs'
ANSI = re.compile(r'\x1b\[[0-9;]*m')
# .ru .su .рф .рус .москва .дети .онлайн .сайт .орг + российские сервисы на чужих зонах; ещё - vpn.directDomains в конфиге
RU_DOMAINS = ['ru', 'su', 'xn--p1ai', 'xn--p1acf', 'xn--80adxhks', 'xn--d1acj3b', 'xn--80asehdb', 'xn--80aswg', 'xn--c1avg',
              'yandex.net', 'yandex.com', 'yastatic.net', 'yandexcloud.net', 'ya.cc', 'vk.com', 'vk.me', 'vkuser.net', 'userapi.com',
              'vk-cdn.net', 'mycdn.me', 'okcdn.ru', 'mail.ru', 'avito.st', 'wbstatic.net', 'wbbasket.ru', 'ozone.ru', 'tbank-online.com']
EXCLUDE = ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '100.64.0.0/10', '169.254.0.0/16', '127.0.0.0/8', '224.0.0.0/4',
           '255.255.255.255/32', '1.1.1.1/32', 'fc00::/7', 'fe80::/10', 'ff00::/8']


class Vpn:
    def __init__(self, ctx):
        self.ctx, self.kick, self.lock = ctx, threading.Event(), threading.Lock()
        self.mode, self.state, self.foreign, self.closing = self._load_mode(), 'выключен', None, False
        self.up, self.started_at, self.check_fails, self.fails, self.next_try, self.gave_up = False, 0.0, 0, 0, 0.0, False
        self.crashed, self.cleaned, self.relaunch, self.bridges = None, False, False, []
        self.clash_port, self.secret, self.tail = 0, '', collections.deque(maxlen=8)
        bus.subscribe('settings.loaded', lambda _: self.kick.set())
        bus.subscribe('net.changed', lambda _: self.kick.set())
        bus.subscribe('proc.exited', self._on_exit)
        bus.subscribe('app.stop', self._on_stop)
        threading.Thread(target=self._loop, name='vpn', daemon=True).start()

    # --- режим ---
    def _mode_path(self):
        return os.path.join(self.ctx.home, 'state', 'vpn.json')

    def _load_mode(self):
        try:
            with open(self._mode_path(), encoding='utf-8') as f:
                m = json.load(f).get('mode')
            return m if m in MODES else 'off'
        except (OSError, ValueError, AttributeError):
            return 'off'

    def set_mode(self, mode):
        if mode not in MODES:
            return False
        with open(self._mode_path() + '.tmp', 'w', encoding='utf-8') as f:
            json.dump({'mode': mode}, f)
        os.replace(self._mode_path() + '.tmp', self._mode_path())
        self.mode, self.fails, self.gave_up, self.next_try = mode, 0, False, 0.0  # новая команда - новые попытки
        journal.log('vpn', 'mode', {'mode': mode}, 'VPN: режим «%s»' % MODES[mode])
        self.kick.set()
        return True

    # --- события ---
    def _on_exit(self, ev):
        if ev.get('name') == NAME and not ev.get('killed'):
            self.crashed = ev.get('code')
            self.kick.set()

    def _on_stop(self, _):
        self.closing = True  # сам процесс гасит procs.kill_all (мягко: sing-box снимает адаптер и маршруты)
        self.kick.set()

    def _loop(self):
        last = None
        while not self.closing:
            self.kick.wait(CHECK_S)
            self.kick.clear()
            if self.closing:
                return
            try:
                self._step()
            except Exception as e:  # поток VPN не должен умирать
                journal.log('vpn', 'error', {'error': repr(e)[:300]})
            if self.state != last:  # в шину - только смена состояния (каждое событие пишется в журнал)
                last = self.state
                bus.publish('vpn.state', {'state': self.state, 'mode': self.mode})

    def _running(self):
        p = procs.get(NAME)
        return bool(p and p.alive())

    def _step(self):
        st = getattr(self.ctx, 'settings', None)
        if not st:
            return
        if not self.cleaned:
            self.cleaned = True
            self._cleanup()
        if self.crashed is not None:
            code, self.crashed = self.crashed, None
            self._fail('sing-box VPN вышел сам (код %s): %s' % (code, ' | '.join(self.tail)[-300:]), stop=False)
            self._cleanup()
            return
        running, self.foreign = self._running(), self._foreign(st)
        if self.mode == 'off':
            if running:
                self._stop('режим «выключен»')
            self.state = 'выключен'
            return
        if self.foreign:
            if running:
                self._stop('появился другой VPN: %s' % self.foreign)
            self.state = ('не включён: работает %s' % self.foreign) if self.mode == 'auto' else \
                'Работает другой VPN (%s) — отключите его, чтобы работал наш' % self.foreign
            return
        if running:
            self._watch()
            return
        if self.gave_up or time.monotonic() < self.next_try:
            return
        self._start(st)

    @staticmethod
    def _foreign(st):
        """Чужой VPN: интернет (1.1.1.1 - он вне нашего туннеля) идёт через не железный интерфейс, либо открыт прокси другого VPN."""
        v = pth.vpn_iface()
        if v and not v.lower().startswith('ralab'):
            return v
        prox = pth.local_proxies(st.cfg)
        return 'прокси 127.0.0.1:%d' % prox[0] if prox else None

    # --- проверка живого VPN ---
    def _watch(self):
        now = time.monotonic()
        if self.relaunch and self.up:
            self.relaunch = False
            self._stop('добавлен список адресов России: перезапуск VPN')
            self._start(self.ctx.settings)
            return
        if not self.up:
            if now - self.started_at > START_S:
                self._fail('sing-box VPN не запустился за %d с: %s' % (START_S, ' | '.join(self.tail)[-300:]))
            return
        if self._probe():
            self.check_fails = 0
            if self.fails and now - self.started_at > STABLE_S:
                self.fails = 0
            self.state = 'работает, мост: %s' % (self._now_bridge() or '?')
            return
        self.check_fails += 1
        journal.log('vpn', 'check.failed', {'n': self.check_fails})
        if self.check_fails >= CHECK_FAILS:
            self._fail('проверка через туннель не прошла %d раза подряд' % self.check_fails)

    @staticmethod
    def _probe():
        """Настоящий запрос через наш туннель (gstatic - не Россия), системный прокси не берём."""
        try:
            with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(CHECK_URL, timeout=5) as r:
                return r.status in (200, 204)
        except (OSError, ValueError, http.client.HTTPException):
            return False

    def _now_bridge(self):
        try:
            c = http.client.HTTPConnection('127.0.0.1', self.clash_port, timeout=2)
            c.request('GET', '/proxies/vpn-out', headers={'Authorization': 'Bearer ' + self.secret})
            r = c.getresponse()
            return json.loads(r.read()).get('now') if r.status == 200 else None
        except (OSError, ValueError, http.client.HTTPException):
            return None

    def _fail(self, why, stop=True):
        self.fails += 1
        if stop:
            self._stop(why)
        if self.fails >= FAILS_MAX:
            self.gave_up = True
            self.state = 'выключен после %d сбоев подряд (%s); интернет напрямую. Включить снова: ra-lab vpn %s' % (self.fails, why[:120], self.mode)
        else:
            self.next_try = time.monotonic() + RETRY_S
            self.state = 'сбой: %s; интернет напрямую, повтор через %d с' % (why[:120], RETRY_S)
        journal.log('vpn', 'failed', {'fails': self.fails, 'gave_up': self.gave_up}, why)

    # --- запуск и остановка ---
    def _stop(self, why):
        p = procs.get(NAME)
        if p:
            journal.log('vpn', 'stop', None, why)
            procs.kill(NAME)  # мягко (CTRL_BREAK, 3 с): sing-box сам снимает адаптер и маршруты; иначе taskkill
            try:
                p.popen.wait(timeout=5)
            except Exception:
                journal.log('vpn', 'stop.slow', {'pid': p.pid})
            end = time.monotonic() + 3
            while procs.get(NAME) is p and time.monotonic() < end:  # запись о процессе снимает его поток ожидания
                time.sleep(0.1)
        self.up, self.check_fails = False, 0

    def _bridges(self, st):
        """Пути канала, пригодные для всего трафика: без ssh-звеньев, без чужого VPN/прокси. vpn.bridges в конфиге - только эти имена."""
        want = (st.cfg.get('vpn') or {}).get('bridges')
        out = []
        for p in st.paths:
            if p.get('via') or p['kind'] in ('proxy', 'ssh') or any(o.get('type') in ('ssh', 'direct') for o in p['outs']):
                continue
            if want and p['name'] not in want:
                continue
            out.append(p)
        return out

    def _system(self):
        """Один вызов PowerShell: оставшиеся адаптеры ralab-vpn* (PnP) и DNS-серверы ПК."""
        script = ("$a=@(Get-NetAdapter -IncludeHidden -Name '%s*' -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.PnPDeviceID }); "
                  "$d=@(Get-DnsClientServerAddress -ErrorAction SilentlyContinue | ForEach-Object { $_.ServerAddresses }); "
                  "@{adapters=$a; dns=$d} | ConvertTo-Json -Compress" % IFACE)
        r = _ps(script, 8) if procs.WIN else None
        try:
            d = json.loads(r[1]) if r and r[0] == 0 else {}
        except ValueError:
            d = {}
        return [x for x in (d.get('adapters') or []) if isinstance(x, str)], [x for x in (d.get('dns') or []) if isinstance(x, str)]

    def _cleanup(self):
        """Наш адаптер, оставшийся без процесса (прошлый запуск, жёсткое убийство): удалить. Чужие не трогаем - только имя ralab-vpn*."""
        if not procs.WIN or self._running():
            return
        for pnp in self._system()[0]:
            if not WINTUN_ID.fullmatch(pnp):
                journal.log('vpn', 'leftover.skipped', {'device': pnp})
                continue
            r = _run(['pnputil.exe', '/remove-device', pnp], 8)
            journal.log('vpn', 'leftover.removed' if r and r[0] in (0, 3010) else 'leftover.failed', {'device': pnp, 'code': r and r[0]},
                        'остался адаптер VPN от прошлого запуска: удаляю')

    def _excludes(self, st, outs, dns):
        hosts = {st.server} | {str(o['server']) for o in outs if o.get('server')}
        nets = list(EXCLUDE)
        for h in sorted(hosts)[:32]:
            try:
                ips = [ipaddress.ip_address(h)]
            except ValueError:
                try:
                    ips = [ipaddress.ip_address(a[4][0].split('%')[0]) for a in socket.getaddrinfo(h, 443, proto=socket.IPPROTO_TCP)]
                except OSError:
                    ips = []
            nets += ['%s/%d' % (ip, 32 if ip.version == 4 else 128) for ip in ips[:8]]
        for a in dns[:16]:
            try:
                ip = ipaddress.ip_address(a.split('%')[0])
                nets.append('%s/%d' % (ip, 32 if ip.version == 4 else 128))
            except ValueError:
                pass
        return list(dict.fromkeys(nets))

    def _geoip(self):
        return os.path.join(self.ctx.home, 'state', 'vpn-geoip-ru.srs')

    def _config(self, st, bridges, dns):
        outs, tags = [], set()
        for p in bridges:
            for o in copy.deepcopy(p['outs']):
                if o['tag'] not in tags:
                    tags.add(o['tag'])
                    if o.get('type') in pth.TCP_TYPES and not o.get('detour'):
                        o.update(pth.KEEPALIVE)
                    outs.append(o)
        rules = [{'action': 'sniff'}, {'ip_is_private': True, 'outbound': 'direct'},
                 {'domain_suffix': RU_DOMAINS + [str(d) for d in (st.cfg.get('vpn') or {}).get('directDomains') or []], 'outbound': 'direct'}]
        route = {'rules': rules, 'final': 'vpn-out', 'auto_detect_interface': True}
        if os.path.isfile(self._geoip()):
            rules.append({'rule_set': ['geoip-ru'], 'outbound': 'direct'})
            route['rule_set'] = [{'type': 'local', 'tag': 'geoip-ru', 'format': 'binary', 'path': self._geoip()}]
        tun = {'type': 'tun', 'tag': 'vpn-in', 'interface_name': IFACE, 'address': ['172.19.8.1/30', 'fdfe:dcba:9877::1/126'], 'mtu': 1400,
               'auto_route': True, 'strict_route': False, 'stack': 'mixed', 'dns_mode': 'disabled',
               'route_address': ['0.0.0.0/1', '128.0.0.0/1', '::/1', '8000::/1'], 'route_exclude_address': self._excludes(st, outs, dns)}
        outs += [{'type': 'urltest', 'tag': 'vpn-out', 'outbounds': [p['final'] for p in bridges], 'url': 'https://www.gstatic.com/generate_204',
                  'interval': '3m', 'tolerance': 100, 'interrupt_exist_connections': False}, {'type': 'direct', 'tag': 'direct'}]
        return {'log': {'level': 'info'}, 'inbounds': [tun], 'outbounds': outs, 'route': route,
                'experimental': {'clash_api': {'external_controller': '127.0.0.1:%d' % self.clash_port, 'secret': self.secret}}}

    def _own_copy(self, exe):
        """Своя копия под своим именем: Happ пускает sing-box.exe мимо туннеля, а ralab-core - процесс канала."""
        dst = os.path.join(self.ctx.home, 'runtime', EXE if os.name == 'nt' else 'ralab-vpn')
        if not os.path.isfile(dst) or os.path.getsize(dst) != os.path.getsize(exe):
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(exe, dst + '.tmp')
            os.replace(dst + '.tmp', dst)
        return dst

    def _start(self, st):
        self.bridges = self._bridges(st)
        if not self.bridges:
            self.state = 'нет мостов для VPN (пути канала без ssh и чужого VPN)'
            return
        _, dns = self._system()
        self.clash_port, self.secret = pth.free_ports(1)[0], secrets.token_urlsafe(24)
        journal.register(self.secret)
        d = os.path.join(self.ctx.home, 'private')
        path = os.path.join(d, 'vpn.json')
        with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w') as f:
            json.dump(self._config(st, self.bridges, dns), f)
        exe = self._own_copy(st.singbox)
        r = _run([exe, 'check', '-c', path], 15)  # кривой конфиг не запускаем вовсе
        if not r or r[0]:
            self._fail('конфиг VPN не прошёл sing-box check: %s' % (r and ANSI.sub('', r[1])[-300:]), stop=False)
            return
        with self.lock:
            if self.closing or self.mode == 'off':
                return
            self.tail.clear()
            self.up, self.started_at, self.check_fails = False, time.monotonic(), 0
            try:
                procs.start(NAME, [exe, 'run', '-c', path], src='vpn', cwd=d, graceful=True, quiet=True, on_err=self._line)
            except (OSError, ValueError) as e:
                self._fail('sing-box VPN не запустить: %s' % e, stop=False)
                return
        self.state = 'включается через: %s' % ', '.join(p['name'] for p in self.bridges)
        journal.log('vpn', 'start', {'bridges': [p['name'] for p in self.bridges], 'geoip': os.path.isfile(self._geoip()), 'dns': dns[:8]}, 'VPN запускается')

    def _line(self, line):
        line = ANSI.sub('', line)
        if 'sing-box started' in line:
            self.up = True
            journal.log('vpn', 'started', None, 'VPN работает')
            if not os.path.isfile(self._geoip()):
                threading.Thread(target=self._fetch_geoip, name='vpn-geoip', daemon=True).start()
            self.kick.set()
        elif 'ERROR' in line or 'FATAL' in line:
            self.tail.append(line[-200:])

    def _fetch_geoip(self):
        """Список адресов России (rule-set SagerNet) - один раз; потом VPN перезапускается с ним (на секунды)."""
        try:
            with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(GEOIP_URL, timeout=30) as r:
                data = r.read(8 << 20)
            if not data.startswith(b'SRS'):
                raise ValueError('не rule-set')
            with open(self._geoip() + '.tmp', 'wb') as f:
                f.write(data)
            os.replace(self._geoip() + '.tmp', self._geoip())
            journal.log('vpn', 'geoip.saved', {'bytes': len(data)}, 'список адресов России скачан')
            self.relaunch = True
            self.kick.set()
        except (OSError, ValueError, http.client.HTTPException) as e:
            journal.log('vpn', 'geoip.failed', {'error': e.__class__.__name__}, 'список адресов России не скачан: Россия пока по именам доменов')

    def status(self):
        return {'mode': self.mode, 'state': self.state, 'running': self._running(), 'up': self.up, 'foreign': self.foreign,
                'fails': self.fails, 'bridges': [p['name'] for p in self.bridges], 'geoip': os.path.isfile(self._geoip())}
