#!/usr/bin/env python3
"""Без подтверждённого пути демон проверяет живость всех кандидатов одновременно; rank (по очереди) — после.
Поддельные SSH/sing-box, только loopback API, без внешней сети. Запуск: python3 transport/test-transport-liveness.py /path/to/pwsh
Это проверка оркестрации на Linux, не приёмка настоящей Windows/SSH.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

PWSH = sys.argv[1] if len(sys.argv) > 1 else 'pwsh'
DAEMON = Path(__file__).with_name('Transport.Daemon.ps1').resolve()
TIMEOUT = 10  # probeTimeoutSec: мёртвый путь (порт 26000) молчит дольше
DELAY = 2     # живые пути отвечают через 2 с (как медленный hop), не сразу


def until(check, seconds=40):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(.05)
    raise AssertionError('Таймаут локального стенда')


def write_exe(path, text):
    path.write_text('#!' + sys.executable + '\n' + text)
    path.chmod(0o700)


with tempfile.TemporaryDirectory(prefix='transport-liveness-test-') as tmp:
    root = Path(tmp)
    (root / 'state').mkdir()
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        api_port = s.getsockname()[1]
    ssh, sb = root / 'ssh.exe', root / 'sing-box'
    write_exe(ssh, '''import json, os, sys, time
from pathlib import Path
root=Path(__file__).parent
if '-N' in sys.argv:
    while True: time.sleep(.1)
port=int(sys.argv[sys.argv.index('-p')+1]); n=int(sys.argv[-1].split()[2])
with (root/'probes.jsonl').open('a') as f: f.write(json.dumps({'port':port,'bytes':n,'start':time.time(),'pid':os.getpid()})+'\\n')
if port==26000: time.sleep(60)
time.sleep(%d)
block=b'x'*8192
while n:
    k=min(len(block),n); os.write(1,block[:k]); n-=k
''' % DELAY)
    write_exe(sb, '''import http.server, json, sys
from pathlib import Path
root=Path(__file__).parent
if sys.argv[1]=='check': sys.exit(0)
c=json.loads(Path(sys.argv[-1]).read_text())
api=c['experimental']['clash_api']; port=int(api['external_controller'].split(':')[-1])
class API(http.server.BaseHTTPRequestHandler):
    def do_PUT(self):
        data=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with (root/'switches').open('a') as f: f.write(data['name']+'\\n')
        self.send_response(204); self.end_headers()
    def log_message(self,*args): pass
class Server(http.server.HTTPServer): allow_reuse_address=True
Server(('127.0.0.1',port),API).serve_forever()
''')
    profile = dict(sshExecutable=str(ssh), serverAddress='203.0.113.10', login='alice',
                   keyPath=str(root / 'key'), knownHostsPath=str(root / 'known_hosts'), arguments=[])
    (root / 'known_hosts').write_text('203.0.113.10 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDKtkImHp4iQlyBtwBY4Vx3cBxfNF0Hdga/ucaszwI2r\n')
    (root / 'profile.json').write_text(json.dumps(profile))
    channel = dict(inbounds=[dict(tag='sync', override_port=23456)],
                   outbounds=[dict(type='vless', tag='old', server='203.0.113.10', server_port=443,
                                   uuid='00000000-0000-4000-8000-000000000001')])
    (root / 'channel.json').write_text(json.dumps(channel))
    transport = dict(profilePath=str(root / 'profile.json'), channelPath=str(root / 'channel.json'),
                     singBoxPath=str(sb), bindPhysical=False, metered='false', openSsh=True,
                     activeIntervalSec=600, rankIntervalSec=1800, stallSeconds=2,
                     probeTimeoutSec=TIMEOUT, restartDelaySec=1, apiPort=api_port)
    (root / 'config.json').write_text(json.dumps(dict(version=1, transport=transport)))
    env = dict(os.environ, LOCALAPPDATA=str(root))

    def status():
        try:
            return json.loads((root / 'status/transport.json').read_text())
        except (OSError, ValueError):
            return {}

    def probes():
        try:
            return [json.loads(x) for x in (root / 'probes.jsonl').read_text().splitlines() if x]
        except OSError:
            return []

    daemon = subprocess.Popen([PWSH, '-NoLogo', '-NoProfile', '-File', str(DAEMON), '-Home', str(root)],
                              env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        until(lambda: status().get('ok'))
        ok_at = time.time()
        # Первая проба каждого порта; после переключения активный путь может сразу получить обычную пробу 'active'.
        live = list({p['port']: p for p in reversed([p for p in probes() if p['bytes'] == 65536])}.values())
        first = min(p['start'] for p in live)
        assert sorted(p['port'] for p in live) == [26000, 26001, 26002], live
        assert max(p['start'] for p in live) - first < 1.5, 'liveness probes are started together, not one after another'
        assert ok_at - first < TIMEOUT - 2, 'a working path is confirmed before the silent path times out (%.1f s)' % (ok_at - first)
        assert status()['active'] != 'vless-direct', 'the silent remembered-first path is not the active one'
        assert not [p for p in probes() if p['bytes'] == 262144], 'speed ranking does not start before the connection works'
        # Rank (по очереди) начинается только после окончания проб живости, включая таймаут молчащего пути.
        rank = until(lambda: [p for p in probes() if p['bytes'] == 262144], seconds=TIMEOUT + 20)
        assert min(p['start'] for p in rank) >= first + TIMEOUT - .5, 'ranking waits for the liveness round'
        assert status().get('ok')
        (root / 'stop').touch()
        daemon.wait(timeout=15)
        assert daemon.returncode == 0, daemon.communicate()
        print('OK: liveness probes in parallel (%.1f s to a working path with a %d s silent one), rank afterwards (имитаторы)' % (ok_at - first, TIMEOUT))
    except Exception:
        print('STATUS', status(), file=sys.stderr)
        print('PROBES', probes(), file=sys.stderr)
        log = root / 'logs/transport.log'
        if log.exists():
            print(log.read_text(), file=sys.stderr)
        raise
    finally:
        if daemon.poll() is None:
            (root / 'stop').touch()
            try:
                daemon.wait(timeout=10)
            except subprocess.TimeoutExpired:
                daemon.kill(); daemon.wait()
        for p in probes():
            try:
                os.kill(p['pid'], 9)
            except ProcessLookupError:
                pass
