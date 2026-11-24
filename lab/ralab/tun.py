"""TUN-адаптер ralab-tun только для сетей клиники (route_address), второй sing-box (ralab-core) -> постоянный lanProxy.
По умолчанию ВЫКЛЮЧЕН: включается разделом lab-конфига tun {enabled: true, routes: [...]} (routes - для опытов, например один адрес /32).
Подсети, пересекающиеся с адресами самого ПК (домашняя сеть), не берутся - иначе TUN перехватил бы локальный трафик.
Маршруты (сети клиники + адреса доменов канала) живут, пока жив процесс (auto_route); DNS ПК не трогаем (dns_mode disabled); умер Python - Job Object гасит sing-box, маршруты снимаются.
Отключение: tun.enabled=false или ra-lab exec 'Stop-Process -Name ralab-core' (только лабораторный TUN-процесс называется tun в procs).
"""
import ipaddress, json, os, re, socket, subprocess, threading, time

from . import journal, procs
from .forward import parse_nets
from .bus import bus

NAME = 'tun'
# Формат PnPDeviceID не угадываем: допускаем оба известных вида, строго fullmatch; дополнительно фильтр по InterfaceDescription.
WINTUN_ID = re.compile(r'ROOT\\(?:WINTUN|NET)\\\d{1,4}|SWD\\WINTUN\\\{[0-9A-Fa-f-]{36}\}', re.IGNORECASE)
OUR_NAME = re.compile(r'ralab-tun.*')  # главная защита: чужие sing-box-адаптеры (happ-tun) имеют то же описание, но другое имя
GUID = re.compile(r'\{?[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}?')


def local_addrs(cancel):
    try:
        r = _run(['ipconfig'], 3, cancel)
        out = r[1] if r and r[0] == 0 else ''
    except (OSError, subprocess.SubprocessError):
        return []
    res = []
    for m in re.finditer(r'(\d+\.\d+\.\d+\.\d+)', out):
        try:
            res.append(ipaddress.ip_address(m.group(1)))
        except ValueError:
            pass
    return res


ADAPTER_FILE = 'tun-adapter.json'
GHOST_DESCS = ('sing-tun Tunnel', 'Wintun Userspace Tunnel')  # реальный sing-box даёт первое; у happ-tun то же описание: защищает имя ralab-tun*
RETRY_GAP, MAX_FAILS, STABLE = 30, 5, 60
DOMAIN_RECHECK = 600  # раз в 10 мин адреса доменов канала сверяются; сменились - TUN перезапускается с новыми маршрутами
# Худший stop(): процесс ~7 с (помощник 2 + ожидание 3 + taskkill 2) + 1 + поток 6 + очистка 12 = ~26 с; EXE и app.py ждут дольше (45 / 40 с).
CLEANUP_BUDGET, WORKER_WAIT = 12, 6


def _run(argv, timeout, cancel=None):
    """Запуск без PowerShell-обёртки; по таймауту убивается всё дерево. Возвращает (код, текст) или None (не вышло/таймаут)."""
    if timeout <= 0 or (cancel and cancel.is_set()):
        return None
    try:
        p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, creationflags=procs.NO_WINDOW)
    except OSError as e:
        journal.log('tun', 'ghost.failed', {'argv': argv[0], 'error': str(e)})
        return None
    end = time.monotonic() + timeout
    while time.monotonic() < end and not (cancel and cancel.is_set()):
        try:
            out, _ = p.communicate(timeout=min(0.2, max(0.001, end - time.monotonic())))
            return p.returncode, out.decode('utf-8', 'replace')
        except subprocess.TimeoutExpired:
            pass
    try:
        if procs.WIN:
            subprocess.run(['taskkill', '/F', '/T', '/PID', str(p.pid)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, creationflags=procs.NO_WINDOW, timeout=1)
    except (OSError, subprocess.SubprocessError):
        pass
    finally:
        try:
            p.kill()
            p.communicate(timeout=1)
        except (OSError, subprocess.SubprocessError):
            pass
    journal.log('tun', 'ghost.cancelled' if cancel and cancel.is_set() else 'ghost.timeout', {'argv': argv[0], 'timeout': timeout})
    return None


def _ps(script, timeout, cancel=None):
    pre = "$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false); "
    return _run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', pre + script], timeout, cancel)


class Tun:
    def __init__(self, ctx):
        self.ctx, self.socks, self.routes, self.skipped, self.last = ctx, None, [], [], 'выключен'
        self.lock, self.busy = threading.Lock(), threading.Lock()
        self.gen, self.fails, self.last_try, self.started, self.worker, self.gave_up = 0, 0, 0.0, 0.0, None, False
        self.closing, self.stopping, self.stopper = False, False, None
        self.cancel, self.before, self.owned = threading.Event(), None, {}
        self.dom_ips, self.dom_check = [], 0.0
        bus.subscribe('settings.loaded', self._on_settings)
        bus.subscribe('channel.up', lambda _: self._ensure())
        bus.subscribe('app.stop', lambda _: self.stop())
        bus.subscribe('proc.exited', self._on_exit)
        threading.Thread(target=self._loop, name='tun-retry', daemon=True).start()

    def _cfg(self):
        st = getattr(self.ctx, 'settings', None)
        return (st.cfg.get('tun') if st else None) or {}

    def _path(self):
        return os.path.join(self.ctx.home, 'private', ADAPTER_FILE)

    def _on_settings(self, _):
        if self._cfg().get('enabled') is not True:
            self.stop(closing=False)
            self.last = 'выключен (tun.enabled не true)'
            return
        self._ensure()

    def _on_exit(self, ev):
        if ev.get('name') == NAME:
            self.last = 'процесс вышел (код %s)' % ev.get('code')

    def _loop(self):
        while True:
            time.sleep(10)
            try:
                self._recheck_domains()
                self._ensure()
            except Exception as e:  # поток повтора не должен умирать
                journal.log('tun', 'retry.error', {'error': repr(e)})

    def _recheck_domains(self):
        p = procs.get(NAME)
        if not (p and p.alive()) or time.monotonic() - self.dom_check < DOMAIN_RECHECK:
            return
        self.dom_check = time.monotonic()
        ips = self._domain_ips(self.ctx.settings.cfg)
        if ips and set(ips) != set(self.dom_ips):
            journal.log('tun', 'domains.changed', {'old': self.dom_ips, 'new': ips}, 'адреса доменов канала сменились: TUN перезапускается')
            self.stop(closing=False).join(40)
            self.last_try = 0.0

    @staticmethod
    def _domain_ips(cfg):
        """Домены канала (lan[].share.domains, happier.viaChannel) -> их IPv4 /32 для route_address. DNS ПК не трогаем:
        имя разрешает обычный резолвер Windows, в TUN идут только эти адреса. '*.x' -> адреса самого x."""
        hosts = []
        for n in parse_nets(cfg):
            for d in n['domains']:
                h = d[2:] if d.startswith('*.') else d
                if h and '*' not in h and '?' not in h and h not in hosts:
                    hosts.append(h)
        res = {}
        def one(h):
            try:
                res[h] = sorted({a[4][0] for a in socket.getaddrinfo(h, 443, socket.AF_INET, socket.SOCK_STREAM)})
            except OSError:
                res[h] = []
        ts = [threading.Thread(target=one, args=(h,), daemon=True) for h in hosts[:16]]
        for th in ts:
            th.start()
        end = time.monotonic() + 5
        for th in ts:
            th.join(max(0, end - time.monotonic()))
        return sorted({ip + '/32' for h in list(res) for ip in res[h][:8]})

    def _ensure(self):
        with self.lock:
            self._ensure_locked()

    def _ensure_locked(self):
        """Старт, если TUN включён, а процесса нет. Не чаще раза в 30 с, не больше 5 попыток подряд; живой TUN не трогаем."""
        t = self._cfg()
        if self.closing or self.stopping or t.get('enabled') is not True:
            return
        p, now = procs.get(NAME), time.monotonic()
        if p and p.alive():
            if self.fails and now - self.started >= STABLE:
                self.fails, self.gave_up = 0, False
            return
        if self.fails >= MAX_FAILS:
            if not self.gave_up:
                self.gave_up = True
                self.last = 'не запускается: %d попыток подряд' % self.fails
                journal.log('tun', 'retry.giveup', {'fails': self.fails}, 'TUN не поднялся за %d попыток, повторы прекращены' % self.fails)
            return
        if now - self.last_try < RETRY_GAP:
            return
        listener = self.ctx.forward.listeners.get('lanProxy') or {}
        if not listener.get('ok'):
            self.last = 'ожидание lanProxy'
            return
        if not self.busy.acquire(False):
            return
        # Forward открывает lanProxy только один раз (started): порт фиксируется до перезапуска Python,
        # поэтому перезагрузка lanProxy.port в настройках не требует перезапуска TUN.
        self.socks, self.last_try = listener['port'], now
        self.cancel = threading.Event()
        self.fails += 1
        self.worker = threading.Thread(target=self._launch, args=(t, self.gen), name='tun-start', daemon=True)
        self.worker.start()

    def _launch(self, t, gen):
        try:
            self._start(t, gen)
        except Exception as e:
            self.last = 'не запустить: %s' % e.__class__.__name__
            journal.log('tun', 'start.error', {'error': repr(e)})
        finally:
            self.busy.release()

    def stop(self, closing=True):
        """Быстрый запрос из шины; вызывающий main ждёт возвращённый поток перед kill_all/выходом."""
        with self.lock:
            self.closing |= closing
            self.cancel.set()
            self.gen += 1
            if self.stopping:
                return self.stopper
            self.stopping = True
            self.stopper = threading.Thread(target=self._stop, name='tun-stop', daemon=True)
            self.stopper.start()
            return self.stopper

    def _stop(self):
        try:
            self._stop_and_clean()
        except Exception as e:
            journal.log('tun', 'stop.error', {'error': repr(e)})
        finally:
            with self.lock:
                self.stopping = False

    def _stop_and_clean(self):
        self.ctx.forward.tun_nets = []
        p = procs.get(NAME)
        if p:
            procs.kill(NAME)
            try:
                p.popen.wait(timeout=1)  # после жёсткого kill удалять устройство можно лишь по выходу процесса
            except subprocess.TimeoutExpired:
                journal.log('tun', 'ghost.skipped', {'pid': p.pid}, 'TUN ещё жив после kill: устройство не удаляем')
                return
        w = self.worker
        if w and w.is_alive():
            w.join(timeout=WORKER_WAIT)
            if w.is_alive():
                journal.log('tun', 'stop.worker_busy', {}, 'поток старта ещё занят; очистку всё равно выполняем, новый старт отменён')
        self.ctx.forward.tun_nets = []
        self._clean_ghost(CLEANUP_BUDGET)

    def _start(self, t, gen):
        st = self.ctx.settings
        wanted = t.get('routes')
        if not wanted:
            wanted = [str(n) for it in (st.cfg.get('lan') or (st.cfg.get('profile') or {}).get('lan') or []) if isinstance(it, dict)
                      for n in ((it.get('share') or {}).get('subnets') or []) if (it.get('share') or {}).get('enabled') is not False]
        local, routes, self.skipped = local_addrs(self.cancel), [], []
        for r in wanted[:128]:
            try:
                net = ipaddress.ip_network(str(r), strict=False)
            except ValueError:
                continue
            if net.version != 4 or any(a in net for a in local if a.version == 4):
                self.skipped.append(str(net))
                continue
            routes.append(str(net))
        if self.skipped:
            journal.log('tun', 'overlap', {'skipped': self.skipped}, 'подсети пересекаются с адресами самого ПК: в TUN не берём')
        self.dom_ips, self.dom_check = (self._domain_ips(st.cfg) if t.get('domains') is not False else []), time.monotonic()
        for r in self.dom_ips:
            if r not in routes and not any(a in ipaddress.ip_network(r) for a in local if a.version == 4):
                routes.append(r)
        if not routes:
            self.last = 'нет маршрутов'
            self.fails = 0  # это не сбой запуска
            return
        self.routes = routes
        cfg = {'log': {'level': 'info'},
               'inbounds': [{'type': 'tun', 'tag': 'tun-in', 'interface_name': 'ralab-tun', 'address': [t.get('address') or '172.19.0.1/30'], 'mtu': 1400,
                             'auto_route': True, 'strict_route': False, 'route_address': routes, 'stack': 'system',
                             'dns_mode': 'disabled'}],  # без DNS-адреса на адаптере: иначе Windows ждёт 12 с ответа с .2 (при Happ ответ теряется)
               'outbounds': [{'type': 'socks', 'tag': 'chan', 'server': '127.0.0.1', 'server_port': self.socks, 'version': '5'}],
               'route': {'final': 'chan', 'auto_detect_interface': True}}
        d = os.path.join(self.ctx.home, 'private')
        path = os.path.join(d, 'tun.json')
        with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w') as f:
            json.dump(cfg, f)
        exe = self.ctx.singbox._own_copy(self.ctx.settings.singbox)
        if not self._clean_ghost(20, self.cancel):
            self.last = 'очистка прошлого адаптера не завершилась, повтор позже'
            return
        before = self._snapshot(3, self.cancel)
        if before is None:  # без снимка нельзя доказать, какие устройства появились при нашем запуске
            self.last = 'не удалось получить снимок адаптеров до запуска'
            return
        with self.lock:
            if gen != self.gen or self.closing or self.cancel.is_set():
                return
            self.before = before
            self.ctx.forward.tun_nets = [{'name': 'tun', 'nets': [ipaddress.ip_network(r) for r in routes], 'domains': []}]
            try:
                p = procs.start(NAME, [exe, 'run', '-c', path], src='tun', cwd=d, graceful=True)
            except (OSError, ValueError) as e:
                self.last = 'не запустить: %s' % e.__class__.__name__
                return
        self.started = time.monotonic()
        self.last = 'запущен, маршруты: %s' % ', '.join(routes)
        journal.log('tun', 'start', {'routes': routes, 'socks': self.socks, 'domain_ips': self.dom_ips}, 'TUN ralab-tun запускается')
        self._remember(p, gen)

    def _snapshot(self, timeout, cancel=None):
        """Wintun-адаптеры (включая скрытые): {pnp: {pnp, guid, status}} или None, если спросить не удалось."""
        if not procs.WIN:
            return {}
        script = ("@(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -in @(%s) -and $_.Name -like 'ralab-tun*' } | "
                  "ForEach-Object { @{pnp=[string]$_.PnPDeviceID; guid=[string]$_.InterfaceGuid; status=[string]$_.Status; name=[string]$_.Name} }) | ConvertTo-Json -Compress" % ', '.join("'%s'" % d for d in GHOST_DESCS))
        r = _ps(script, timeout, cancel)
        if not r or r[0]:
            return None
        txt = r[1].strip()
        try:
            data = json.loads(txt) if txt else []
        except ValueError:
            return None
        if isinstance(data, dict):
            data = [data]
        res = {}
        for d in data if isinstance(data, list) else []:
            if isinstance(d, dict) and WINTUN_ID.fullmatch(str(d.get('pnp', ''))) and GUID.fullmatch(str(d.get('guid', ''))) \
                    and OUR_NAME.fullmatch(str(d.get('name', ''))):
                res[d['pnp']] = {'pnp': d['pnp'], 'guid': d['guid'], 'status': str(d.get('status', '')), 'name': d['name']}
        return res

    def _remember(self, p, gen):
        """Запоминаем адаптер, появившийся при нашем запуске (разница снимков, не Disconnected): потом удаляем только его."""
        if not procs.WIN:
            return
        before = dict(self.before or {})
        for _ in range(12):
            if gen != self.gen or self.cancel.is_set() or not p.alive():
                return
            now = self._snapshot(4, self.cancel)
            new = [a for k, a in (now or {}).items() if k not in before and a['status'] != 'Disconnected']
            if len(new) == 1:
                data = {'pnp': new[0]['pnp'], 'guid': new[0]['guid']}
                with open(self._path(), 'w', encoding='utf-8') as f:
                    json.dump(data, f)
                journal.log('tun', 'adapter.saved', data)
                return
            if self.cancel.wait(1):
                return
        journal.log('tun', 'adapter.unknown', {}, 'новый адаптер не найден: после падения чистим по разнице снимков')

    def _targets(self, cancel, deadline):
        """Что удалять: записанный адаптер + все Wintun-призраки, которых не было в снимке до запуска. Чужие (в снимке до) не трогаем."""
        targets = {}
        rec = None
        path = self._path()
        if os.path.exists(path):
            try:
                with open(path, encoding='utf-8') as f:
                    rec = json.load(f)
                if not WINTUN_ID.fullmatch(rec['pnp']) or not GUID.fullmatch(rec['guid']):
                    raise ValueError('формат')
            except (OSError, ValueError, KeyError, TypeError):
                journal.log('tun', 'ghost.badrecord', {}, 'запись об адаптере испорчена: удаляю запись, адаптеры не трогаю')
                self._forget()
                rec = None
        if rec is None and self.before is None:
            journal.log('tun', 'ghost.norecord', {}, 'записи и снимка нет: ничего не удаляем')
            return targets
        now = self._snapshot(max(0.5, min(10, deadline - time.monotonic())), cancel)
        if now is None:
            return None
        for k, a in now.items():
            if (rec and k == rec['pnp'] and a['guid'].strip('{}').lower() == rec['guid'].strip('{}').lower()) or \
                    (self.before is not None and k not in self.before):
                targets[k] = a
        return targets

    def _clean_ghost(self, budget, cancel=None):
        """True - можно стартовать (чужое не трогаем). False - очистка не завершилась. Удаляются только записанный адаптер и новые по разнице снимков."""
        if not procs.WIN:
            return True
        end = time.monotonic() + budget
        p = procs.get(NAME)
        if p and p.alive():
            return True
        targets = self._targets(cancel, end)
        if targets is None:
            journal.log('tun', 'ghost.failed', {'step': 'query'})
            return False
        ok = True
        for k, a in targets.items():
            if a['status'] == 'Up':
                journal.log('tun', 'ghost.skipped', a, 'ВНИМАНИЕ: наш адаптер ещё Up, не удалён; запись сохранена')
                ok = False
                continue
            r = _run(['pnputil.exe', '/remove-device', k], min(5, end - time.monotonic()), cancel)
            if r and r[0] in (0, 3010):
                journal.log('tun', 'ghost.removed', {'device': k, 'guid': a['guid'], 'code': r[0]})
            else:
                journal.log('tun', 'ghost.failed', {'step': 'remove', 'device': k, 'result': r and (r[0], r[1][:300])})
                ok = False
        if ok:
            self._forget()
            self.before = None
        return ok

    def _forget(self):
        try:
            os.remove(self._path())
        except OSError:
            pass

    def status(self):
        return {'state': self.last, 'routes': self.routes, 'skipped': self.skipped, 'running': NAME in procs.names()}
