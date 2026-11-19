#!/usr/bin/env bash
# SOCKS5 + TCP DNS client of the LAN hosts block against real servers on 127.0.0.1 (Linux only).
# Usage: timeout 60 bash lan-hosts-socks-test.sh      (needs python3 and dotnet; ~20 s with a cold build)
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
dotnet=${DOTNET:-$HOME/.dotnet/dotnet}
work=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$work"' EXIT
export DOTNET_CLI_TELEMETRY_OPTOUT=1
"$dotnet" build "$here/PortableTests.csproj" -c Release --nologo -v q >"$work/build.log" 2>&1 || { cat "$work/build.log"; exit 1; }
cat >"$work/servers.py" <<'PY'
import socket, struct, sys, threading

USER, PASSWORD = b'ra-helper', b'synthetic-password'
ANSWERS = {  # name -> list of (type, value); everything else is NXDOMAIN
    'portal.eastclinic.ru': [('A', '192.168.88.167')],
    'alias.eastclinic.ru': [('CNAME', 'portal.eastclinic.ru'), ('A', '192.168.88.167')],
    'hop1.eastclinic.ru': [('CNAME', 'hop2.eastclinic.ru')],
    'hop2.eastclinic.ru': [('CNAME', 'portal.eastclinic.ru')],
    'public.eastclinic.ru': [('A', '212.41.27.201')],
    'nodata.eastclinic.ru': [],
}
NAMES = set(ANSWERS)

def recv(conn, n):
    data = b''
    while len(data) < n:
        chunk = conn.recv(n - len(data))
        if not chunk:
            raise EOFError
        data += chunk
    return data

def name_wire(name):
    return b''.join(bytes([len(p)]) + p.encode() for p in name.split('.')) + b'\0'

def dns(conn):
    try:
        size, = struct.unpack('>H', recv(conn, 2)); msg = recv(conn, size)
        qid = msg[:2]; i = 12; labels = []
        while msg[i]:
            labels.append(msg[i + 1:i + 1 + msg[i]].decode()); i += 1 + msg[i]
        name = '.'.join(labels); question = msg[12:i + 5]
        if name not in ANSWERS:
            body = qid + b'\x81\x83' + b'\0\x01\0\0\0\0\0\0' + question
        else:
            recs = b''; n = 0
            for kind, value in ANSWERS[name]:
                if kind == 'CNAME':
                    data = name_wire(value); recs += b'\xc0\x0c' + struct.pack('>HHIH', 5, 1, 30, len(data)) + data
                else:
                    recs += b'\xc0\x0c' + struct.pack('>HHIH', 1, 1, 30, 4) + socket.inet_aton(value)
                n += 1
            body = qid + b'\x81\x80' + struct.pack('>HHHH', 1, n, 0, 0) + question + recs
        conn.sendall(struct.pack('>H', len(body)) + body)
    except Exception:
        pass
    finally:
        conn.close()

def relay(a, b):
    try:
        while True:
            d = a.recv(4096)
            if not d: break
            b.sendall(d)
    except Exception:
        pass
    finally:
        for s in (a, b):
            try: s.shutdown(socket.SHUT_RDWR)
            except Exception: pass

def socks(conn, dns_port):
    try:
        ver, n = recv(conn, 2); methods = recv(conn, n)
        if 2 not in methods:
            conn.sendall(b'\x05\xff'); return
        conn.sendall(b'\x05\x02')
        recv(conn, 1); u = recv(conn, recv(conn, 1)[0]); p = recv(conn, recv(conn, 1)[0])
        if u != USER or p != PASSWORD:
            conn.sendall(b'\x01\x01'); return
        conn.sendall(b'\x01\x00')
        v, cmd, _, atyp = recv(conn, 4)
        host = socket.inet_ntoa(recv(conn, 4)); port, = struct.unpack('>H', recv(conn, 2))
        if (host, port) != ('192.168.88.11', 53):  # only the LAN DNS is reachable
            conn.sendall(b'\x05\x05\x00\x01\0\0\0\0\0\0'); return
        upstream = socket.create_connection(('127.0.0.1', dns_port))
        conn.sendall(b'\x05\x00\x00\x01\0\0\0\0\0\0')
        threading.Thread(target=relay, args=(upstream, conn), daemon=True).start()
        relay(conn, upstream)
    except Exception:
        pass
    finally:
        conn.close()

def serve(sock, handler, *extra):
    while True:
        conn, _ = sock.accept()
        threading.Thread(target=handler, args=(conn,) + extra, daemon=True).start()

d = socket.socket(); d.bind(('127.0.0.1', 0)); d.listen(16)
s = socket.socket(); s.bind(('127.0.0.1', 0)); s.listen(16)
open(sys.argv[1], 'w').write('%d\n' % s.getsockname()[1])
threading.Thread(target=serve, args=(d, dns), daemon=True).start()
serve(s, socks, d.getsockname()[1])
PY
python3 "$work/servers.py" "$work/port" & 
for _ in $(seq 50); do [[ -s $work/port ]] && break; sleep 0.1; done
port=$(cat "$work/port")
fail=0
run() { timeout 20 "$dotnet" run --no-build --project "$here/PortableTests.csproj" -c Release -- --lan-hosts-resolve "$port" "$@" 2>&1 | tail -1 || true; }
expect() { local want=$1; shift; local got; got=$(run "$@"); if [[ $got == $want* ]]; then echo "ok   $* -> $got"; else echo "FAIL $* -> $got (want $want)"; fail=1; fi; }
good=(ra-helper synthetic-password 192.168.88.11)
expect 'OK 192.168.88.167' "${good[@]}" portal.eastclinic.ru
expect 'OK 192.168.88.167' "${good[@]}" alias.eastclinic.ru
expect 'OK 192.168.88.167' "${good[@]}" hop1.eastclinic.ru
expect 'OK 212.41.27.201'  "${good[@]}" public.eastclinic.ru
expect 'OK ' "${good[@]}" missing.eastclinic.ru
expect 'OK ' "${good[@]}" nodata.eastclinic.ru
expect 'ERR SOCKS: неверный логин или пароль' ra-helper wrong-password 192.168.88.11 portal.eastclinic.ru
expect 'ERR SOCKS: сервер отказал' "${good[0]}" "${good[1]}" 192.168.88.99 portal.eastclinic.ru
[[ $fail == 0 ]] && echo 'PASS: lan-hosts socks/dns' || { echo 'FAIL: lan-hosts socks/dns'; exit 1; }
