"""TUN-адаптер ralab-tun только для сетей клиники (route_address), второй sing-box (ralab-core) -> SOCKS текущего канала.
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
        bus.subscribe('channel.up', self._on_up)
        bus.subscribe('channel.down', self._on_down)
        bus.subscribe('app.stop', lambda _: procs.kill(NAME))
        bus.subscribe('proc.exited', self._on_exit)

    def _cfg(self):
        st = getattr(self.ctx, 'settings', None)
        return (st.cfg.get('tun') if st else None) or {}

    def _on_up(self, ev):
        procs.kill(NAME)  # прежний процесс смотрел на SOCKS предыдущего канала
        self.socks = ev['socks']
        t = self._cfg()
        if t.get('enabled') is not True:
            self.last = 'выключен (tun.enabled не true)'
            return
        self._start(t)

    def _on_down(self, ev):
        procs.kill(NAME)  # без канала маршруты в никуда не нужны: адаптер снимается
        self.socks = None

    def _on_exit(self, ev):
        if ev.get('name') == NAME:
            self.last = 'процесс вышел (код %s)' % ev.get('code')

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
        try:
            procs.start(NAME, [exe, 'run', '-c', path], src='tun', cwd=d)
            self.last = 'запущен, маршруты: %s' % ', '.join(routes)
            journal.log('tun', 'start', {'routes': routes, 'socks': self.socks}, 'TUN ralab-tun запускается')
        except (OSError, ValueError) as e:
            self.last = 'не запустить: %s' % e.__class__.__name__

    def status(self):
        return {'state': self.last, 'routes': self.routes, 'skipped': self.skipped, 'running': NAME in procs.names()}
