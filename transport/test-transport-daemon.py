#!/usr/bin/env python3
"""Локальный стенд надзора: поддельные SSH/sing-box, только loopback API, без внешней сети.
Запуск: python3 transport/test-transport-daemon.py /path/to/pwsh
Это проверка оркестрации на Linux, не приёмка настоящей Windows/SSH.
"""
from datetime import datetime
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


def until(check, seconds=35):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(.1)
    raise AssertionError('Таймаут локального стенда')


def write_exe(path, text):
    path.write_text('#!' + sys.executable + '\n' + text)
    path.chmod(0o700)


with tempfile.TemporaryDirectory(prefix='transport-daemon-test-') as tmp:
    root = Path(tmp)
    (root / 'state').mkdir()
    # Выбираем порты без изменений сетевых настроек; стенд работает с одним экземпляром.
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        api_port = s.getsockname()[1]
    occupied_ssh = socket.socket()
    occupied_ssh.bind(('127.0.0.1', 2222)); occupied_ssh.listen()
    occupied_web = socket.socket()
    occupied_web.bind(('127.0.0.1', 0)); occupied_web.listen()
    web_port = occupied_web.getsockname()[1]
    race_socket = None
    optional = socket.socket()
    optional.bind(('127.0.0.1', 0))
    optional.listen()
    optional_port = optional.getsockname()[1]
    ssh = root / 'ssh.exe'
    sb = root / 'sing-box'
    write_exe(ssh, '''import os, sys, time
from pathlib import Path
root=Path(__file__).parent
# Туннель для теста остановки дочерних: не читает приватных данных.
if '-N' in sys.argv:
    # Real occupied optional SOCKS: the daemon must still start sing-box/VLESS.
    if (root/'optional-busy').exists():
        os.write(2,b'bind: Address already in use\\r\\n'); sys.exit(1)
    (root/'tunnel.pid').write_text(str(os.getpid()))
    while True: time.sleep(.1)
with (root/'probes.pid').open('a') as ledger: ledger.write(str(os.getpid())+'\\n')
port=int(sys.argv[sys.argv.index('-p')+1])
if (root/'fail-active').exists() and port==int((root/'fail-active').read_text()):
    os.write(1,b'x'*16384)
    time.sleep(10)
else:
    n=int(sys.argv[-1].split()[2]); block=b'x'*8192
    while n:
        k=min(len(block),n); os.write(1,block[:k]); n-=k
        time.sleep(.002 if port==26000 else (.004 if port==26001 else .008))
''')
    write_exe(sb, '''import http.server, json, os, sys
from pathlib import Path
root=Path(__file__).parent
if sys.argv[1]=='check': sys.exit(0)
n=int((root/'starts').read_text())+1 if (root/'starts').exists() else 1
(root/'starts').write_text(str(n)); (root/'engine.pid').write_text(str(os.getpid()))
if (root/'other-failure').exists():
    os.write(2,b'FATAL invalid test configuration\\r\\n'); sys.exit(1)
if (root/'bind-failure').exists():
    port=(root/'bind-failure').read_text().strip() or '2222'
    os.write(2,('FATAL start inbound/direct[ssh]: listen tcp 127.0.0.1:'+port+': bind: Only one usage of each socket address\\r\\n').encode())
    sys.exit(1)
c=json.loads(Path(sys.argv[-1]).read_text())
if (root/'race-bind').exists():
    import time
    ssh_port=next(i['listen_port'] for i in c['inbounds'] if i['tag']=='ssh')
    (root/'race-request').write_text(str(ssh_port))
    while not (root/'race-ready').exists(): time.sleep(.02)
    os.write(2,('FATAL listen tcp 127.0.0.1:'+str(ssh_port)+': bind: address already in use\\r\\n').encode())
    sys.exit(1)
api=c['experimental']['clash_api']; port=int(api['external_controller'].split(':')[-1])
class API(http.server.BaseHTTPRequestHandler):
    def do_PUT(self):
        if self.headers.get('Authorization') != 'Bearer '+api['secret']:
            self.send_response(401); self.end_headers(); return
        data=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with (root/'switches').open('a') as f: f.write(data['name']+'\\n')
        self.send_response(204); self.end_headers()
    def log_message(self,*args): pass
class Server(http.server.HTTPServer): allow_reuse_address=True
Server(('127.0.0.1',port),API).serve_forever()
''')
    profile = dict(sshExecutable=str(ssh), serverAddress='203.0.113.10', login='alice',
                   keyPath=str(root / 'key'), knownHostsPath=str(root / 'known_hosts'), arguments=[])
    # Публичный тестовый ключ. В данном стенде sing-box check заменён имитатором.
    (root / 'known_hosts').write_text('203.0.113.10 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDKtkImHp4iQlyBtwBY4Vx3cBxfNF0Hdga/ucaszwI2r\n')
    (root / 'profile.json').write_text(json.dumps(profile))
    channel = dict(inbounds=[dict(tag='sync', override_port=23456)],
                   outbounds=[dict(type='vless', tag='old', server='203.0.113.10', server_port=443,
                                   uuid='00000000-0000-4000-8000-000000000001')])
    (root / 'channel.json').write_text(json.dumps(channel))
    transport = dict(profilePath=str(root / 'profile.json'), channelPath=str(root / 'channel.json'),
                     singBoxPath=str(sb), bindPhysical=False, metered='false', openSsh=True,
                     activeIntervalSec=1, rankIntervalSec=1800, stallSeconds=2,
                     probeTimeoutSec=12, restartDelaySec=1, apiPort=api_port, socksPortBase=optional_port)
    (root / 'config.json').write_text(json.dumps(dict(version=1, transport=transport, happier=dict(localWeb=dict(enabled=True, port=web_port, serverPort=47832)))))
    env = dict(os.environ, LOCALAPPDATA=str(root))
    children = []
    daemon = None
    parent = None

    def status():
        try:
            return json.loads((root / 'status/transport.json').read_text())
        except (OSError, ValueError):
            return {}

    def retry_delay(s):
        return (datetime.fromisoformat(s['retryAt']) - datetime.fromisoformat(s['updatedAt'])).total_seconds()

    def start(parent_pid=0):
        p = subprocess.Popen([PWSH, '-NoLogo', '-NoProfile', '-File', str(DAEMON), '-Home', str(root),
                              '-ParentPid', str(parent_pid)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        children.append(p)
        return p

    def stopped(pid):
        try:
            os.kill(pid, 0)
            # Linux zombie уже завершён; его подберёт родитель процесса.
            return Path('/proc/%s/stat' % pid).read_text().split()[2] == 'Z'
        except (ProcessLookupError, FileNotFoundError):
            return True

    try:
        (root/'optional-busy').touch()
        daemon = start()
        until(lambda: status().get('ok') and any(c['tag']=='vless-direct' and c['state']=='ok' for c in status().get('candidates',[])))
        selected=json.loads((root/'state/transport-ports.json').read_text())
        assert selected['configured']['sshPort']==2222 and selected['effective']['sshPort']==2232
        assert status()['ports']['sshPort']==2232
        assert next(i for i in json.loads((root/'state/transport-sing-box.json').read_text())['inbounds'] if i['tag']=='ssh')['listen_port']==2232
        web_status = status()['localWeb']
        assert web_status['port'] == web_port and not web_status['available'] and web_status['conflict']['port'] == web_port
        assert 'Вход Happier не запущен' in status()['summary'] and status()['ok'], 'Happier conflict must not fail channel status'
        assert not any(i['tag'] == 'happier-web' for i in json.loads((root/'state/transport-sing-box.json').read_text())['inbounds'])
        assert 'happier-port-conflict' in (root/'logs/transport.log').read_text(), 'Happier conflict journal'
        occupied_web.close()
        occupied_ssh.close()
        assert int((root/'starts').read_text()) == 1, 'Занятый порт необязательного SSH заблокировал sing-box'
        optional.close()
        (root/'optional-busy').unlink()
        until(lambda: status().get('ok'))
        until(lambda: len(status().get('candidates', [])) == 3 and all(c['state']=='ok' for c in status()['candidates']))
        assert status().get('summary') and 'нет связи' not in status()['summary']
        until(lambda: (root/'tunnel.pid').exists())
        initial=status()['active']
        ports={i['tag'][6:]:i['listen_port'] for i in json.loads((root/'state/transport-sing-box.json').read_text())['inbounds'] if i['tag'].startswith('probe-')}
        first_engine = int((root / 'engine.pid').read_text())
        # Активный поток замер: переключение на ранее проверенный путь через PUT без рестарта.
        (root / 'fail-active').write_text(str(ports[initial]))
        until(lambda: status().get('ok') and status().get('active') != initial)
        assert int((root / 'engine.pid').read_text()) == first_engine
        assert status()['active'] in (root / 'switches').read_text()
        # Pin применяется CLI за <=5 секунд; мёртвый pin не сменяется при живых соседях.
        def cli(script, *args):
            subprocess.run([PWSH, '-NoLogo', '-NoProfile', '-File', str(DAEMON.with_name(script)),
                            '-Home', str(root), *args], env=env, check=True, capture_output=True)

        pinned='singbox-ssh-direct' if initial != 'singbox-ssh-direct' else 'openssh-direct'
        # Observe publication while CLI is alive: its PowerShell teardown can outlast the daemon's response.
        pin_cli = subprocess.Popen([PWSH, '-NoLogo', '-NoProfile', '-File', str(DAEMON.with_name('Set-TransportPath.ps1')),
                                    '-Home', str(root), '-Tag', pinned], env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        children.append(pin_cli)
        until(lambda: (root/'state/transport-pin.json').exists())
        started=(root/'state/transport-pin.json').stat().st_mtime
        applied=until(lambda: (s if (s:=status()).get('mode')=='pinned' and s.get('active')==pinned else None), seconds=5)
        elapsed=datetime.fromisoformat(applied['updatedAt']).timestamp()-started
        assert 0 <= elapsed <= 5, ('Pin publication delay', elapsed)
        pin_output=pin_cli.communicate(timeout=15)
        assert pin_cli.returncode == 0, pin_output
        (root/'fail-active').write_text(str(ports[pinned]))
        until(lambda: status().get('active')==pinned and not status().get('ok') and
              'Закреплённый путь не работает' in status().get('error',''))
        time.sleep(2)
        assert status()['active']==pinned and not status()['ok']
        assert status()['summary'].startswith('нет связи:')
        assert int((root/'engine.pid').read_text())==first_engine
        # Выключение tag при сохранённом pin закрывает selector, рабочие порты прежние.
        cli('Edit-Transport.ps1', '-Disable', pinned)
        until(lambda: int((root/'engine.pid').read_text()) != first_engine)
        until(lambda: any(c['tag']==pinned and not c['enabled'] for c in status().get('candidates',[])))
        assert status()['active']==pinned and not status()['ok']
        config=json.loads((root/'state/transport-sing-box.json').read_text())
        assert next(o for o in config['outbounds'] if o['tag']=='active')['default']=='unavailable'
        assert [(i['tag'],i['listen_port']) for i in config['inbounds'][:2]]==[('ssh',2222),('sync',22001)]
        starts=int((root/'starts').read_text())
        # Невалидный reload не останавливает рабочий движок.
        saved=(root/'config.json').read_text()
        broken=json.loads(saved); broken['transport']['apiPort']=65536
        (root/'config.json').write_text(json.dumps(broken))
        until(lambda: bool(status().get('configError')))
        assert int((root/'starts').read_text())==starts
        (root/'config.json').write_text(saved)
        (root/'fail-active').unlink()
        cli('Set-TransportPath.ps1', '-Auto')
        until(lambda: status().get('mode')=='auto' and status().get('ok'))
        cli('Edit-Transport.ps1', '-Enable', pinned)
        until(lambda: any(c['tag']==pinned and c['enabled'] for c in status().get('candidates',[])))
        until(lambda: status().get('ok'))
        first_engine=int((root/'engine.pid').read_text())
        # Падение движка: демон сам поднимает его снова.
        os.kill(first_engine, 9)
        until(lambda: int((root / 'engine.pid').read_text()) != first_engine)
        until(lambda: status().get('ok'))
        assert status()['localWeb']['port'] == web_port and status()['localWeb']['available'] and not status()['localWeb']['conflict']
        assert next(i for i in json.loads((root/'state/transport-sing-box.json').read_text())['inbounds'] if i['tag']=='happier-web')['listen_port'] == web_port, 'freed fixed origin restored after restart'
        # Одинаковый bind: причина видна, интервалы 5/10 с, а не быстрый рестарт без конца.
        (root/'bind-failure').touch()
        os.kill(int((root/'engine.pid').read_text()), 9)
        until(lambda: status().get('portConflict'))
        assert not status()['ok'] and 'Порт 127.0.0.1:2222 занят' in status()['summary']
        bind_starts=int((root/'starts').read_text())
        stamp=(root/'status/transport.json').stat().st_mtime_ns
        time.sleep(2)
        assert int((root/'starts').read_text()) == bind_starts
        assert (root/'status/transport.json').stat().st_mtime_ns == stamp, 'Статус долбится во время паузы bind'
        until(lambda: int((root/'starts').read_text()) > bind_starts, seconds=12)
        until(lambda: status().get('portConflict') and 'занят' in status().get('error',''))
        second_starts=int((root/'starts').read_text())
        time.sleep(6)
        assert int((root/'starts').read_text()) == second_starts, 'Пауза bind не увеличилась'
        # Другая bind-ошибка обнуляет нарастающую паузу.
        (root/'bind-failure').write_text('2223')
        changed = until(lambda: (s if ((s:=status()).get('portConflict') or {}).get('port')==2223 else None), seconds=15)
        assert 0 < retry_delay(changed) <= 5.1, 'Другой bind унаследовал паузу'
        # Любая ошибка без bind тоже сбрасывает серию.
        (root/'other-failure').touch()
        failed = until(lambda: (s if not (s:=status()).get('portConflict') and
                               any(c.get('diagnostic', {}).get('stderr')=='FATAL invalid test configuration'
                                   for c in s.get('candidates', [])) else None), seconds=10)
        assert 0 < retry_delay(failed) <= 1.1
        (root/'other-failure').unlink()
        # Process startup/readiness also takes time on a loaded host. The actual
        # reset backoff remains independently bounded by retry_delay below.
        rebound = until(lambda: (s if (s:=status()).get('portConflict') else None), seconds=15)
        assert 0 < retry_delay(rebound) <= 5.1, 'Ошибка без bind не сбросила серию'
        # Та же ошибка уже повторилась; смена конфига начинает новую серию.
        before=int((root/'starts').read_text())
        until(lambda: int((root/'starts').read_text()) > before, seconds=10)
        until(lambda: status().get('portConflict'))
        current=json.loads((root/'config.json').read_text())
        current['transport']['rankIntervalSec']+=1
        before=int((root/'starts').read_text())
        (root/'config.json').write_text(json.dumps(current))
        until(lambda: int((root/'starts').read_text()) > before, seconds=10)
        reconfigured = until(lambda: (s if (s:=status()).get('portConflict') and
                                     s.get('configRevision') != rebound.get('configRevision') else None), seconds=10)
        assert 0 < retry_delay(reconfigured) <= 5.1, 'Новый конфиг унаследовал серию bind'
        (root/'bind-failure').unlink()
        until(lambda: status().get('ok') and not status().get('portConflict'), seconds=10)
        # Успешный запуск также сбросил серию: следующий bind снова ждёт 5 с.
        (root/'bind-failure').touch()
        os.kill(int((root/'engine.pid').read_text()), 9)
        restarted = until(lambda: (s if (s:=status()).get('portConflict') else None), seconds=10)
        assert 0 < retry_delay(restarted) <= 5.1, 'Успешный запуск не сбросил серию bind'
        (root/'bind-failure').unlink()
        until(lambda: status().get('ok') and not status().get('portConflict'), seconds=10)
        # Гонка bind: порт заняли после выбора, пока запускался движок.
        (root/'race-bind').touch()
        os.kill(int((root/'engine.pid').read_text()), 9)
        until(lambda: (root/'race-request').exists())
        race_port=int((root/'race-request').read_text())
        race_socket=socket.socket(); race_socket.bind(('127.0.0.1',race_port)); race_socket.listen()
        (root/'race-bind').unlink(); (root/'race-ready').touch()
        changed=until(lambda: (s if (s:=status()).get('portConflict') and s.get('ports',{}).get('sshPort')!=race_port else None), seconds=10)
        assert 0 < retry_delay(changed) <= 1.1, 'Перевыбор после bind унаследовал растущую паузу'
        until(lambda: status().get('ok') and not status().get('portConflict'), seconds=10)
        assert status()['ports']['sshPort']==race_port+10
        assert json.loads((root/'state/transport-ports.json').read_text())['effective']['sshPort']==race_port+10
        race_socket.close(); race_socket=None
        (root / 'stop').touch()
        daemon.wait(timeout=10)
        assert daemon.returncode == 0, daemon.communicate()
        assert not status()['ok']
        assert stopped(int((root / 'engine.pid').read_text()))
        assert stopped(int((root / 'tunnel.pid').read_text()))
        assert all(stopped(int(pid)) for pid in (root/'probes.pid').read_text().splitlines()), 'SSH probe leaked after timeout/stop'
        # Родитель закрыт — компонент и его дети должны завершиться.
        (root / 'stop').unlink()
        parent = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
        daemon = start(parent.pid)
        until(lambda: status().get('ok'))
        parent.terminate(); parent.wait(timeout=5)
        daemon.wait(timeout=10)
        assert daemon.returncode == 0, daemon.communicate()
        assert not status()['ok']
        assert stopped(int((root / 'engine.pid').read_text()))
        assert stopped(int((root / 'tunnel.pid').read_text()))
        assert all(stopped(int(pid)) for pid in (root/'probes.pid').read_text().splitlines()), 'SSH probe leaked after timeout/stop'
        print('OK: failover, pin <=5с, мёртвый pin, auto, hot reload, disabled tag, invalid reload, restart, занятый SSH при старте, фиксированный Happier/конфликт/статус/восстановление, optional SSH occupied/VLESS, bind/перевыбор/backoff/reset/status, stop, ParentPid (имитаторы)')
    except Exception:
        print('STATUS', status(), file=sys.stderr)
        log=root/'logs/transport.log'
        if log.exists(): print(log.read_text(), file=sys.stderr)
        for p in children:
            if p.poll() is not None: print('EXIT', p.returncode, p.communicate(), file=sys.stderr)
        raise
    finally:
        optional.close(); occupied_ssh.close(); occupied_web.close()
        if race_socket: race_socket.close()
        for p in children:
            if p.poll() is None:
                (root / 'stop').touch()
                try: p.wait(timeout=5)
                except subprocess.TimeoutExpired: p.kill(); p.wait()
        if parent and parent.poll() is None:
            parent.terminate(); parent.wait()
        for file in ('engine.pid', 'tunnel.pid'):
            if (root / file).exists():
                try: os.kill(int((root / file).read_text()), 9)
                except ProcessLookupError: pass
