"""Проброс через SOCKS канала: точечные порты (forwards, Happier на 127.0.0.1:47831) и локальный прокси для сетей из lan[].
Слушатели только 127.0.0.1. Канала нет - входящее закрывается сразу. Системную сеть/прокси/реестр не трогаем: PAC лежит на
http://127.0.0.1:<lanProxy.port>/lan.pac, владелец подставляет его в браузер сам. Сокеты блокирующие, таймеров нет: оборвался
канал - сокеты закрываются, потоки завершаются сами.
Конфиг (lab config.json главнее): forwards [{listen,to:"host:port"}], lanProxy {port}. Без forwards берётся happier.localWeb установленной программы.
"""
import fnmatch, ipaddress, re, socket, struct, threading

from . import journal
from .bus import bus

CONN_MAX, BUF, HEAD_MAX, PROXY_PORT = 256, 65536, 16384, 17891


def parse_nets(cfg):
    items = cfg.get('lan')
    if items is None:
        items = (cfg.get('profile') or {}).get('lan')
    out = []
    for it in (items if isinstance(items, list) else [])[:64]:
        if not isinstance(it, dict) or not it.get('name'):
            continue
        sh = it.get('share') if isinstance(it.get('share'), dict) else {}
        if sh.get('enabled') is False:
            continue
        nets = []
        for s in sh.get('subnets') or []:
            try:
                nets.append(ipaddress.ip_network(str(s), strict=False))
            except ValueError:
                pass
        doms = [str(d).lower() for d in (sh.get('domains') or []) if isinstance(d, str) and d]
        if nets or doms:
            out.append({'name': str(it['name']), 'nets': nets, 'domains': doms})
    via = (cfg.get('happier') or {}).get('viaChannel') if isinstance(cfg.get('happier'), dict) else None
    via = [d.lower() for d in via if isinstance(d, str) and d] if isinstance(via, list) else ['api.happier.dev']
    if via:
        out.append({'name': 'happier-api', 'nets': [], 'domains': via})
    return out


def with_server(nets, server):
    """Сам сервер (109) - тоже «сеть»: его порты (админка 3081 и т.п.) с ПК напрямую режет ТСПУ, через канал открываются."""
    try:
        return nets + [{'name': 'server', 'nets': [ipaddress.ip_network(str(server) + '/32')], 'domains': []}]
    except ValueError:
        return nets


def match(nets, host):
    """-> имя сети или None. host - IPv4 или домен."""
    h = host.lower().rstrip('.')
    try:
        ip = ipaddress.ip_address(h)
        return next((n['name'] for n in nets if any(ip in x for x in n['nets'] if x.version == ip.version)), None)
    except ValueError:
        pass
    for n in nets:
        for d in n['domains']:
            if fnmatch.fnmatch(h, d) or (d.startswith('*.') and h == d[2:]):
                return n['name']
    return None


def pac_text(nets, port):
    lines = ['function FindProxyForURL(url, host) {', '  var P = "PROXY 127.0.0.1:%d";' % port, '  host = host.toLowerCase();']
    for n in nets:
        for d in n['domains']:
            lines.append('  if (shExpMatch(host, "%s")%s) return P;' % (d, (' || host == "%s"' % d[2:]) if d.startswith('*.') else ''))
    for n in nets:
        for x in n['nets']:
            if x.version == 4:
                lines.append('  if (isInNet(host, "%s", "%s")) return P;' % (x.network_address, x.netmask))
    lines += ['  return "DIRECT";', '}']
    return '\n'.join(lines) + '\n'


def recvn(s, n):
    out = b''
    while len(out) < n:
        c = s.recv(n - len(out))
        if not c:
            raise EOFError()
        out += c
    return out


def socks_connect(proxy_port, host, port):
    s = socket.socket()
    try:
        s.connect(('127.0.0.1', proxy_port))
        s.sendall(b'\x05\x01\x00')
        if recvn(s, 2) != b'\x05\x00':
            raise OSError('SOCKS канала: отказ')
        try:
            a = b'\x01' + socket.inet_aton(host) if re.match(r'^\d+\.\d+\.\d+\.\d+$', host) else b'\x03' + bytes([len(host)]) + host.encode()
        except (OSError, ValueError):
            a = b'\x03' + bytes([len(host)]) + host.encode()
        s.sendall(b'\x05\x01\x00' + a + struct.pack('>H', port))
        head = recvn(s, 4)
        if head[1] != 0:
            raise OSError('SOCKS канала: код %d' % head[1])
        recvn(s, {1: 6, 4: 18}.get(head[3]) or recvn(s, 1)[0] + 2)
        return s
    except Exception:
        s.close()
        raise


def pipe(a, b):
    def one(x, y):
        try:
            while True:
                d = x.recv(BUF)
                if not d:
                    break
                y.sendall(d)
        except OSError:
            pass
        finally:
            for z in (x, y):
                try:
                    z.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
    t = threading.Thread(target=one, args=(b, a), daemon=True)
    t.start()
    one(a, b)
    t.join()
    a.close()
    b.close()


class Forward:
    def __init__(self, ctx):
        self.ctx, self.socks, self.nets, self.listeners, self.conns = ctx, None, [], {}, set()
        self.tun_nets = []  # фактические route_address живого TUN, сохраняются при перезагрузке настроек
        self.lock, self.sem, self.refused, self.count = threading.Lock(), threading.Semaphore(CONN_MAX), [], 0
        self.started, self.fixed = False, {}
        self.tl = threading.local()  # сокеты, открытые обработчиком этого потока
        bus.subscribe('settings.loaded', self._on_settings)
        bus.subscribe('channel.up', self._on_up)
        bus.subscribe('channel.down', self._on_down)

    def _on_up(self, ev):
        self.socks = ev['socks']

    def _on_down(self, ev):
        self.socks = None
        with self.lock:
            conns, self.conns = list(self.conns), set()
        for s in conns:  # закрытие сокета завершает блокирующий pipe
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            s.close()

    def _on_settings(self, _):
        st = getattr(self.ctx, 'settings', None)
        if not st or self.started:
            if st:
                self.nets = with_server(parse_nets(st.cfg), st.server)
            return
        self.started, cfg = True, st.cfg
        self.nets = with_server(parse_nets(cfg), st.server)
        fw = cfg.get('forwards')
        if not isinstance(fw, list):
            web = ((cfg.get('profile') or {}).get('happier') or cfg.get('happier') or {}).get('localWeb') or {}
            fw = [{'listen': web.get('port'), 'to': '127.0.0.1:%s' % web.get('serverPort')}] if web.get('enabled') and web.get('port') and web.get('serverPort') else []
        for f in fw[:16]:
            try:
                host, port = str(f['to']).rsplit(':', 1)
                self._listen('forward:%d' % int(f['listen']), int(f['listen']), lambda c, h=host, p=int(port): self._forward(c, h, p))
            except (KeyError, ValueError, TypeError):
                journal.log('forward', 'bad.config', {'item': f}, 'пропущен: нужны listen и to=host:port')
        pp = (cfg.get('lanProxy') or {}).get('port') or PROXY_PORT
        self._listen('lanProxy', int(pp), lambda c: self._proxy(c, int(pp)))

    def add_forward(self, listen, host, port):
        """Фиксированный проброс 127.0.0.1:listen -> host:port через канал (Диск); повторный вызов меняет только цель.
        Слушатель эксклюзивный (SO_EXCLUSIVEADDRUSE на Windows): занятый порт честно даёт ошибку. True, если слушатель открыт."""
        key = 'forward:%d' % listen
        if key in self.fixed:
            self.fixed[key] = (host, port)
            return True
        self.fixed[key] = (host, port)
        self._listen(key, listen, lambda c: self._forward(c, *self.fixed[key]), exclusive=True)
        if not self.listeners[key]['ok']:
            del self.fixed[key]
        return self.listeners[key]['ok']

    def _listen(self, name, port, handler, exclusive=False):
        try:
            ls = socket.socket()
            if exclusive and hasattr(socket, 'SO_EXCLUSIVEADDRUSE'):
                ls.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            else:
                ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            ls.bind(('127.0.0.1', port))
            ls.listen(64)
        except OSError as e:
            self.listeners[name] = {'port': port, 'ok': False, 'error': str(e)[:60]}
            journal.log('forward', 'bind.failed', {'name': name, 'port': port}, str(e)[:80])
            return
        self.listeners[name] = {'port': port, 'ok': True}
        journal.log('forward', 'listen', {'name': name, 'port': port})
        threading.Thread(target=self._accept, args=(ls, handler), daemon=True).start()

    def _accept(self, ls, handler):
        while True:
            try:
                c, _ = ls.accept()
            except OSError:
                return
            if not self.sem.acquire(blocking=False):
                c.close()
                continue
            threading.Thread(target=self._run, args=(c, handler), daemon=True).start()

    def _run(self, c, handler):
        with self.lock:
            self.conns.add(c)
            self.count += 1
        try:
            handler(c)
        except (OSError, EOFError, ValueError) as e:
            self._refuse('соединение', str(e))
        finally:
            ups = getattr(self.tl, 'ups', [])
            self.tl.ups = []
            with self.lock:
                self.conns.discard(c)
                for u in ups:
                    self.conns.discard(u)
            for u in ups:
                u.close()
            c.close()
            self.sem.release()

    def _refuse(self, what, why):
        self.refused = (self.refused + ['%s: %s' % (what, why)])[-5:]
        journal.log('forward', 'refused', {'what': what}, why[:100])

    def _via_channel(self, host, port):
        if not self.socks:
            raise OSError('канал не работает')
        return socks_connect(self.socks, host, port)

    def _forward(self, c, host, port):
        up = self._via_channel(host, port)
        self._reg(up)
        pipe(c, up)

    def _reg(self, s):
        with self.lock:
            self.conns.add(s)
        self.tl.ups = getattr(self.tl, 'ups', []) + [s]

    def _open(self, host, port):
        net = match(self.nets + self.tun_nets, host)
        if net:
            up = self._via_channel(host, port)
            journal.log('forward', 'lan', {'net': net, 'target': '%s:%d' % (host, port)})
        else:
            up = socket.create_connection((host, port), 10)
        self._reg(up)
        return up

    def _proxy(self, c, port):
        first = c.recv(1, socket.MSG_PEEK)
        if not first:
            return
        if first == b'\x05':
            n = recvn(c, 2)[1]
            recvn(c, n)
            c.sendall(b'\x05\x00')
            h = recvn(c, 4)
            if h[1] != 1:
                c.sendall(b'\x05\x07\x00\x01\x00\x00\x00\x00\x00\x00')
                return
            host = socket.inet_ntoa(recvn(c, 4)) if h[3] == 1 else recvn(c, recvn(c, 1)[0]).decode('ascii', 'replace')
            p = struct.unpack('>H', recvn(c, 2))[0]
            try:
                up = self._open(host, p)
            except OSError as e:
                c.sendall(b'\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00')
                return self._refuse(host, str(e))
            c.sendall(b'\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00')
            return pipe(c, up)
        head = b''
        while b'\r\n\r\n' not in head and len(head) < HEAD_MAX:
            d = c.recv(4096)
            if not d:
                return
            head += d
        hdr, _, rest = head.partition(b'\r\n\r\n')
        lines = hdr.decode('latin-1').split('\r\n')
        method, target, ver = (lines[0].split(' ') + ['', '', ''])[:3]
        if method == 'GET' and target.startswith('/lan.pac'):
            body = pac_text(self.nets, port).encode()
            c.sendall(b'HTTP/1.0 200 OK\r\nContent-Type: application/x-ns-proxy-autoconfig\r\nContent-Length: %d\r\n\r\n' % len(body) + body)
            return
        if method == 'CONNECT':
            host, _, p = target.rpartition(':')
            try:
                up = self._open(host.strip('[]'), int(p))
            except (OSError, ValueError) as e:
                c.sendall(b'HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n')
                return self._refuse(target, str(e))
            c.sendall(b'HTTP/1.1 200 Connection established\r\n\r\n')
            if rest:
                up.sendall(rest)
            return pipe(c, up)
        m = re.match(r'^http://([^/:]+)(?::(\d+))?(/.*)?$', target, re.I)
        if not m:
            c.sendall(b'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n')
            return
        host, p, path = m.group(1), int(m.group(2) or 80), m.group(3) or '/'
        try:
            up = self._open(host, p)
        except OSError as e:
            c.sendall(b'HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n')
            return self._refuse(target, str(e))
        keep = [l for l in lines[1:] if not re.match(r'(?i)(proxy-connection|connection):', l)]
        up.sendall(('%s %s %s\r\n' % (method, path, ver or 'HTTP/1.1') + '\r\n'.join(keep) + '\r\nConnection: close\r\n\r\n').encode('latin-1') + rest)
        pipe(c, up)

    def status(self):
        return {'channel_socks': self.socks, 'listeners': self.listeners, 'connections': len(self.conns), 'total': self.count,
                'nets': [n['name'] for n in self.nets], 'refused': self.refused}
