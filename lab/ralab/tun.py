"""TUN-адаптер ralab-tun только для сетей клиники (route_address), второй sing-box (ralab-core) -> постоянный lanProxy.
По умолчанию ВЫКЛЮЧЕН: включается разделом lab-конфига tun {enabled: true, routes: [...]} (routes - для опытов, например один адрес /32).
Подсети, пересекающиеся с адресами самого ПК (домашняя сеть), не берутся - иначе TUN перехватил бы локальный трафик.
Маршруты живут, пока жив процесс (auto_route); умер Python - Job Object гасит sing-box, маршруты снимаются.
Отключение: tun.enabled=false или ra-lab exec 'Stop-Process -Name ralab-core' (только лабораторный TUN-процесс называется tun в procs).
"""
import ipaddress, json, os, re, subprocess

from . import journal, procs
from .bus import bus

NAME = 'tun'


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


class Tun:
    def __init__(self, ctx):
        self.ctx, self.socks, self.routes, self.skipped, self.last = ctx, None, [], [], 'выключен'
        self.exe = None
        bus.subscribe('settings.loaded', self._on_settings)
        bus.subscribe('app.stop', lambda _: self.stop())
        bus.subscribe('proc.exited', self._on_exit)

    def _cfg(self):
        st = getattr(self.ctx, 'settings', None)
        return (st.cfg.get('tun') if st else None) or {}

    def _on_settings(self, _):
        t = self._cfg()
        if t.get('enabled') is not True:
            self.stop()
            self.last = 'выключен (tun.enabled не true)'
            return
        if procs.get(NAME):
            return
        listener = self.ctx.forward.listeners.get('lanProxy') or {}
        if not listener.get('ok'):
            self.last = 'ожидание lanProxy'
            return
        self.socks = listener['port']
        self._start(t)

    def _on_exit(self, ev):
        if ev.get('name') == NAME:
            self.last = 'процесс вышел (код %s)' % ev.get('code')

    def stop(self):
        if not self.exe:
            return
        p = procs.get(NAME)
        procs.kill(NAME)
        try:
            if p:
                p.popen.wait(timeout=1)  # после жёсткого kill удалять устройство можно лишь по выходу процесса
            self._clean_ghosts(self.exe)  # проверяем отсутствие призрака и после штатного выхода
            self.exe, self.ctx.forward.tun_nets = None, []
        except subprocess.TimeoutExpired:
            journal.log('tun', 'ghost.skipped', {'pid': p.pid}, 'TUN ещё жив после kill: устройство не удаляем')

    def _start(self, t):
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
            return
        self.routes = routes
        self.ctx.forward.tun_nets = [{'name': 'tun', 'nets': [ipaddress.ip_network(r) for r in routes], 'domains': []}]
        cfg = {'log': {'level': 'info'},
               'inbounds': [{'type': 'tun', 'tag': 'tun-in', 'interface_name': 'ralab-tun', 'address': [t.get('address') or '172.19.0.1/30'], 'mtu': 1400,
                             'auto_route': True, 'strict_route': False, 'route_address': routes, 'stack': 'system'}],
               'outbounds': [{'type': 'socks', 'tag': 'chan', 'server': '127.0.0.1', 'server_port': self.socks, 'version': '5'}],
               'route': {'final': 'chan', 'auto_detect_interface': True}}
        d = os.path.join(self.ctx.home, 'private')
        path = os.path.join(d, 'tun.json')
        with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w') as f:
            json.dump(cfg, f)
        self.exe = exe = self.ctx.singbox._own_copy(self.ctx.settings.singbox)
        try:
            self._clean_ghosts(exe)
            procs.start(NAME, [exe, 'run', '-c', path], src='tun', cwd=d, graceful=True)
            self.last = 'запущен, маршруты: %s' % ', '.join(routes)
            journal.log('tun', 'start', {'routes': routes, 'socks': self.socks}, 'TUN ralab-tun запускается')
        except (OSError, ValueError) as e:
            self.last = 'не запустить: %s' % e.__class__.__name__

    def _clean_ghosts(self, exe):
        if not procs.WIN or (procs.get(NAME) and procs.get(NAME).alive()):
            return
        # Только свой обычный core заведомо не владеет TUN. Неизвестный core — очистку пропускаем.
        core = procs.get('singbox')
        allowed = core.pid if core and core.alive() else 0
        script = r'''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$cores = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -in @('ralab-core.exe', 'sing-box.exe', 'singbox.exe', '__EXE__') -and $_.ProcessId -ne __PID__
})
if ($cores.Count) { @{ev='ghost.skipped'; pids=@($cores.ProcessId)} | ConvertTo-Json -Compress; exit }
Get-NetAdapter -IncludeHidden | Where-Object {
    $_.InterfaceDescription -eq 'Wintun Userspace Tunnel' -and $_.Status -eq 'Disconnected' -and $_.Name -ne 'happ-tun'
} | ForEach-Object {
    $a = $_; $id = $a.PnPDeviceID
    if (-not $id -or $id -notlike 'ROOT\WINTUN\*') { return }
    $output = & pnputil.exe /remove-device $id 2>&1 | Out-String
    $code = $LASTEXITCODE
    @{ev=$(if ($code -eq 0) {'ghost.removed'} else {'ghost.failed'}); name=$a.Name; device=$id; code=$code; output=$output} | ConvertTo-Json -Compress
}
'''.replace('__EXE__', os.path.basename(exe).replace("'", "''")).replace('__PID__', str(allowed))
        try:
            p = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', script],
                               stdin=subprocess.DEVNULL, capture_output=True, timeout=15, creationflags=procs.NO_WINDOW)
            for line in p.stdout.decode('utf-8', 'replace').splitlines():
                data = json.loads(line)
                journal.log('tun', data.pop('ev'), data)
            if p.returncode:
                journal.log('tun', 'ghost.failed', {'code': p.returncode, 'error': p.stderr.decode('utf-8', 'replace')})
        except (OSError, subprocess.SubprocessError, ValueError) as e:
            journal.log('tun', 'ghost.failed', {'error': str(e)})

    def status(self):
        return {'state': self.last, 'routes': self.routes, 'skipped': self.skipped, 'running': NAME in procs.names()}
