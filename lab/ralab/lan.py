"""Проверка локальных сетей из lan[] через SOCKS канала (выход на сервере 109). Своё - мини-клиент SOCKS5 CONNECT.

Сроков нет: сокеты блокирующие, пока ответа нет - в отчёте «нет ответа N с» (это показание часов, не таймер). Оборвался канал -
сокеты закрываются, проверки завершаются сами. На каждую сеть событие lan.result{name, status ok|refused|error, detail, ms}.
Ответ цели: порт 22 - баннер SSH-, TLS-порты - рукопожатие TLS (ClientHello через ssl.MemoryBIO, сертификат не проверяется),
80/8080/8090 - первая строка HTTP/, остальные - успешный CONNECT.
"""
import re, socket, ssl, struct, threading, time

from . import journal
from .bus import bus

SOCKS_ERR = {1: 'сбой сервера', 2: 'запрещено', 3: 'сеть недоступна', 4: 'узел недоступен', 5: 'отказ в соединении', 6: 'TTL истёк'}
TLS_PORTS = (443, 465, 636, 993, 995, 5986, 8443)
HTTP_PORTS = (80, 8080, 8090)
READ_MAX = 4096


def recv_until(s, done):
    buf = b''
    while not done(buf) and len(buf) < READ_MAX:
        c = s.recv(1024)
        if not c:
            break
        buf += c
    return buf


def recvn(s, n):
    out = b''
    while len(out) < n:  # по байту: не съесть данные цели, идущие сразу за ответом SOCKS
        c = s.recv(n - len(out))
        if not c:
            raise EOFError()
        out += c
    return out


def tls_probe(s, host):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
    inc, out = ssl.MemoryBIO(), ssl.MemoryBIO()
    obj = ctx.wrap_bio(inc, out, server_hostname=None if re.match(r'^[\d.]+$', host) else host)
    while True:
        try:
            obj.do_handshake()
            data = out.read()
            data and s.sendall(data)
            return True, 'TLS ' + str(obj.version())
        except ssl.SSLWantReadError:
            data = out.read()
            data and s.sendall(data)
            chunk = s.recv(16384)
            if not chunk:
                return False, 'закрыто без ответа TLS'
            inc.write(chunk)
        except ssl.SSLError as e:
            return False, 'TLS: ' + str(getattr(e, 'reason', None) or e)[:40]


def check(proxy_port, host, port, reg):
    """-> (ok|refused|error, подробности, мс). reg(sock) запоминает сокет, чтобы его можно было закрыть при обрыве канала."""
    t0 = time.monotonic()
    ms = lambda: int((time.monotonic() - t0) * 1000)
    s = socket.socket()
    reg(s)
    try:
        s.connect(('127.0.0.1', proxy_port))
        s.sendall(b'\x05\x01\x00')
        if recvn(s, 2) != b'\x05\x00':
            return 'error', 'SOCKS: отказ', ms()
        a = b'\x01' + socket.inet_aton(host) if re.match(r'^\d+\.\d+\.\d+\.\d+$', host) else b'\x03' + bytes([len(host)]) + host.encode()
        s.sendall(b'\x05\x01\x00' + a + struct.pack('>H', port))
        head = recvn(s, 4)
        if head[1] != 0:
            return ('refused' if head[1] == 5 else 'error'), SOCKS_ERR.get(head[1], 'код SOCKS %d' % head[1]), ms()
        recvn(s, {1: 6, 4: 18}.get(head[3]) or recvn(s, 1)[0] + 2)  # адрес в ответе не нужен
        if port == 22:
            b = recv_until(s, lambda x: b'\n' in x)
            return ('ok', 'баннер ' + b.split(b'\n')[0].decode('ascii', 'replace').strip()[:40], ms()) if b.startswith(b'SSH-') else \
                ('error', 'нет баннера SSH-' if b else 'закрыто без ответа', ms())
        if port in HTTP_PORTS:
            s.sendall(b'GET / HTTP/1.0\r\nHost: ' + host.encode() + b'\r\n\r\n')
            b = recv_until(s, lambda x: b'\n' in x or len(x) >= 12)
            return ('ok', 'ответ ' + b.split(b'\r')[0].split(b'\n')[0].decode('ascii', 'replace')[:30], ms()) if b.startswith(b'HTTP/') else \
                ('error', 'ответ не HTTP' if b else 'закрыто без ответа', ms())
        if port in TLS_PORTS:
            ok, d = tls_probe(s, host)
            return ('ok' if ok else 'error'), d, ms()
        return 'ok', 'соединение установлено', ms()
    except (EOFError, ConnectionResetError):
        return 'error', 'соединение сброшено', ms()
    except OSError as e:
        return 'error', str(e)[:60], ms()
    finally:
        s.close()


class Lan:
    def __init__(self, ctx):
        self.ctx, self.gen, self.state, self.socks = ctx, 0, {}, set()
        self.lock = threading.Lock()
        bus.subscribe('channel.up', self._on_up)
        bus.subscribe('channel.down', self._on_down)
        bus.subscribe('lan.result', self._on_result)

    def _reg(self, s):
        with self.lock:
            self.socks.add(s)

    def _on_up(self, ev):
        self.gen += 1
        with self.lock:
            self.socks = set()  # сокеты прежних проверок уже закрыты
        gen, nets = self.gen, getattr(self.ctx, 'settings', None) and self.ctx.settings.lans or []
        self.state = {n['name']: {'name': n['name'], 'target': '%s:%d' % (n['host'], n['port']), 'status': 'checking', 'detail': '', 'ms': None, 'since': time.monotonic()} for n in nets}
        for n in nets:
            threading.Thread(target=self._run, args=(n, ev['socks'], gen), daemon=True).start()

    def _run(self, n, socks, gen):
        st, detail, ms = check(socks, n['host'], n['port'], self._reg)
        if gen == self.gen:  # канал не менялся
            bus.publish('lan.result', {'name': n['name'], 'status': st, 'detail': detail, 'ms': ms, 'gen': gen})

    def _on_result(self, ev):
        s = self.state.get(ev['name'])
        if s and ev['gen'] == self.gen:
            s.update(status=ev['status'], detail=ev['detail'], ms=ev['ms'])

    def _on_down(self, ev):
        self.gen += 1  # результаты прежних проверок отбрасываются
        with self.lock:
            socks, self.socks = list(self.socks), set()
        for s in socks:  # закрытие сокета завершает блокирующую проверку
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            s.close()
        for s in self.state.values():
            if s['status'] == 'checking':
                s['status'] = 'cancelled'

    def status(self):
        now = time.monotonic()
        out = []
        for s in self.state.values():
            d = {k: s[k] for k in ('name', 'target', 'status', 'detail', 'ms')}
            if s['status'] == 'checking':
                d['detail'] = 'нет ответа %d с' % int(now - s['since'])
            out.append(d)
        return out
