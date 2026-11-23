"""TUN-адаптер ralab-tun только для сетей клиники (route_address), второй sing-box (ralab-core) -> постоянный lanProxy.
По умолчанию ВЫКЛЮЧЕН: включается разделом lab-конфига tun {enabled: true, routes: [...]} (routes - для опытов, например один адрес /32).
Подсети, пересекающиеся с адресами самого ПК (домашняя сеть), не берутся - иначе TUN перехватил бы локальный трафик.
Маршруты живут, пока жив процесс (auto_route); умер Python - Job Object гасит sing-box, маршруты снимаются.
Отключение: tun.enabled=false или ra-lab exec 'Stop-Process -Name ralab-core' (только лабораторный TUN-процесс называется tun в procs).
"""
import ipaddress, json, os, re, subprocess, threading, time

from . import journal, procs
from .bus import bus

NAME = 'tun'
WINTUN_ID = re.compile(r'^ROOT\\WINTUN\\\d{1,4}$')
GUID = re.compile(r'^\{?[0-9A-Fa-f-]{36}\}?$')


def local_addrs():
    try:
        out = subprocess.run(['ipconfig'], capture_output=True, stdin=subprocess.DEVNULL, timeout=10).stdout.decode('cp866', 'replace')
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
GHOST_DESC = 'Wintun Userspace Tunnel'
RETRY_GAP, MAX_FAILS, STABLE = 30, 5, 60


def _run(argv, timeout):
    """Запуск без PowerShell-обёртки; по таймауту убивается всё дерево. Возвращает (код, текст) или None (не вышло/таймаут)."""
    try:
        p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, creationflags=procs.NO_WINDOW)
    except OSError as e:
        journal.log('tun', 'ghost.failed', {'argv': argv[0], 'error': str(e)})
        return None
    try:
        out, _ = p.communicate(timeout=max(0.5, timeout))
        return p.returncode, out.decode('utf-8', 'replace')
    except subprocess.TimeoutExpired:
        subprocess.run(['taskkill', '/F', '/T', '/PID', str(p.pid)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, creationflags=procs.NO_WINDOW)
        try:
            p.kill()
            p.communicate(timeout=1)
        except (OSError, subprocess.SubprocessError):
            pass
        journal.log('tun', 'ghost.timeout', {'argv': argv[0], 'timeout': timeout}, 'команда очистки не уложилась в срок и убита')
        return None


def _ps(script, timeout):
    pre = "$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false); "
    return _run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', pre + script], timeout)


class Tun:
    def __init__(self, ctx):
        self.ctx, self.socks, self.routes, self.skipped, self.last = ctx, None, [], [], 'выключен'
        self.lock, self.busy = threading.Lock(), threading.Lock()
        self.gen, self.fails, self.last_try, self.started, self.worker, self.gave_up = 0, 0, 0.0, 0.0, None, False
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
            self.stop()
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
                self._ensure()
            except Exception as e:  # поток повтора не должен умирать
                journal.log('tun', 'retry.error', {'error': repr(e)})

    def _ensure(self):
        """Старт, если TUN включён, а процесса нет. Не чаще раза в 30 с, не больше 5 попыток подряд; живой TUN не трогаем."""
        t = self._cfg()
        if t.get('enabled') is not True:
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
        self.socks, self.last_try = listener['port'], now
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

    def stop(self):
        with self.lock:
            self.gen += 1
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
            w.join(timeout=3)
            if w.is_alive():
                return
        self.ctx.forward.tun_nets = []
        self._clean_ghost(3)

    def _start(self, t, gen):
        st = self.ctx.settings
        wanted = t.get('routes')
        if not wanted:
            wanted = [str(n) for it in (st.cfg.get('lan') or (st.cfg.get('profile') or {}).get('lan') or []) if isinstance(it, dict)
                      for n in ((it.get('share') or {}).get('subnets') or []) if (it.get('share') or {}).get('enabled') is not False]
        local, routes, self.skipped = local_addrs(), [], []
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
        if not routes:
            self.last = 'нет маршрутов'
            self.fails = 0  # это не сбой запуска
            return
        self.routes = routes
        cfg = {'log': {'level': 'info'},
               'inbounds': [{'type': 'tun', 'tag': 'tun-in', 'interface_name': 'ralab-tun', 'address': [t.get('address') or '172.19.0.1/30'], 'mtu': 1400,
                             'auto_route': True, 'strict_route': False, 'route_address': routes, 'stack': 'system'}],
               'outbounds': [{'type': 'socks', 'tag': 'chan', 'server': '127.0.0.1', 'server_port': self.socks, 'version': '5'}],
               'route': {'final': 'chan', 'auto_detect_interface': True}}
        d = os.path.join(self.ctx.home, 'private')
        path = os.path.join(d, 'tun.json')
        with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w') as f:
            json.dump(cfg, f)
        exe = self.ctx.singbox._own_copy(self.ctx.settings.singbox)
        if not self._clean_ghost(20):
            self.last = 'очистка прошлого адаптера не завершилась, повтор позже'
            return
        with self.lock:
            if gen != self.gen:
                return
            self.ctx.forward.tun_nets = [{'name': 'tun', 'nets': [ipaddress.ip_network(r) for r in routes], 'domains': []}]
            try:
                p = procs.start(NAME, [exe, 'run', '-c', path], src='tun', cwd=d, graceful=True)
            except (OSError, ValueError) as e:
                self.last = 'не запустить: %s' % e.__class__.__name__
                return
        self.started = time.monotonic()
        self.last = 'запущен, маршруты: %s' % ', '.join(routes)
        journal.log('tun', 'start', {'routes': routes, 'socks': self.socks}, 'TUN ralab-tun запускается')
        self._remember(p, gen)

    def _remember(self, p, gen):
        """Запоминаем PnPDeviceID и GUID созданного нами адаптера: потом удаляем только его."""
        if not procs.WIN:
            return
        script = ("Get-NetAdapter -Name 'ralab-tun' -IncludeHidden -ErrorAction SilentlyContinue | Where-Object "
                  "{ $_.InterfaceDescription -eq '%s' } | Select-Object -First 1 | ForEach-Object "
                  "{ @{pnp=[string]$_.PnPDeviceID; guid=[string]$_.InterfaceGuid} | ConvertTo-Json -Compress }" % GHOST_DESC)
        for _ in range(12):
            if gen != self.gen or not p.alive():
                return
            r = _ps(script, 8)
            try:
                data = json.loads(r[1]) if r and r[0] == 0 and r[1].strip() else None
            except ValueError:
                data = None
            if data and WINTUN_ID.match(data.get('pnp', '')) and GUID.match(data.get('guid', '')):
                with open(self._path(), 'w', encoding='utf-8') as f:
                    json.dump(data, f)
                journal.log('tun', 'adapter.saved', data)
                return
            time.sleep(1)
        journal.log('tun', 'adapter.unknown', {}, 'адаптер ralab-tun не найден: призрак после падения удалять нечем')

    def _clean_ghost(self, budget):
        """True - можно стартовать (чужое не трогаем). False - очистка не завершилась. Удаляется только записанный адаптер."""
        path = self._path()
        if not procs.WIN or not os.path.exists(path):
            if procs.WIN:
                journal.log('tun', 'ghost.norecord', {}, 'записи о своём адаптере нет: ничего не удаляем')
            return True
        end = time.monotonic() + budget
        p = procs.get(NAME)
        if p and p.alive():
            return True
        try:
            with open(path, encoding='utf-8') as f:
                rec = json.load(f)
            pnp, guid = rec['pnp'], rec['guid']
            if not WINTUN_ID.match(pnp) or not GUID.match(guid):
                raise ValueError('формат')
        except (OSError, ValueError, KeyError, TypeError):
            journal.log('tun', 'ghost.badrecord', {}, 'запись об адаптере испорчена: удаляю запись, адаптеры не трогаю')
            self._forget()
            return True
        r = _ps("Get-NetAdapter -IncludeHidden | Where-Object { $_.PnPDeviceID -eq '%s' -and $_.InterfaceGuid -eq '%s' } | ForEach-Object "
                "{ @{status=[string]$_.Status; desc=$_.InterfaceDescription} | ConvertTo-Json -Compress }" % (pnp, guid), min(10, end - time.monotonic()))
        if not r or r[0]:
            journal.log('tun', 'ghost.failed', {'step': 'query', 'result': r and r[1][:300]})
            return False
        if not r[1].strip():
            self._forget()  # устройства с такими PnP и GUID нет: чисто (или ID занял чужой адаптер с другим GUID)
            return True
        try:
            info = json.loads(r[1].strip().splitlines()[-1])
        except ValueError:
            return False
        if info.get('status') != 'Disconnected' or info.get('desc') != GHOST_DESC:
            journal.log('tun', 'ghost.skipped', info, 'адаптер не в состоянии призрака: не удаляем')
            return True
        r = _run(['pnputil.exe', '/remove-device', pnp], min(5, end - time.monotonic()))
        if r and r[0] in (0, 3010):
            journal.log('tun', 'ghost.removed', {'device': pnp, 'guid': guid, 'code': r[0]})
            self._forget()
            return True
        journal.log('tun', 'ghost.failed', {'step': 'remove', 'device': pnp, 'result': r and (r[0], r[1][:300])})
        return False

    def _forget(self):
        try:
            os.remove(self._path())
        except OSError:
            pass

    def status(self):
        return {'state': self.last, 'routes': self.routes, 'skipped': self.skipped, 'running': NAME in procs.names()}
