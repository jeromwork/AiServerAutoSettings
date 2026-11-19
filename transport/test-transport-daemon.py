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
import threading
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
    # Exercise the real acknowledgement adapter with the pure reducer and a deterministic clock.
    helper_checks = root/'helper-checks.ps1'
    helper_checks.write_text(r"""param([string]$Scripts)
$ErrorActionPreference='Stop'
. (Join-Path $Scripts 'Transport.Decide.ps1')
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Scripts 'Transport.Daemon.ps1'),[ref]$null,[ref]$null)
$definition=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Confirm-DaemonSelection'},$true)
. ([scriptblock]::Create($definition.Extent.Text))
$simNow=1000
function Get-DaemonTime { $script:simNow }
function Start-DaemonDirect { throw 'Unexpected direct I/O during acknowledgement' }
function Start-DaemonPath { throw 'Unexpected path I/O during acknowledgement' }
$rows=@([pscustomobject]@{tag='a';state='ok'},[pscustomobject]@{tag='b';state='fail'})
$paths=@{Candidates=$rows};$pin=@{mode='pinned';tag='b'}
$decision=(Invoke-TransportDecision -State (New-TransportDecisionState 0 'a') -Candidates $rows -CurrentTag 'a' -Now 0).state
$decision.paths.b.step=1;$decision.paths.b.until=5000;$decision.paths.b.failed=$true;$decision.paths.b.reason='path-dial-failed'
Confirm-DaemonSelection 'b'
if($decision.currentTag -ne 'b' -or $decision.lastSwitchAt -ne 1000 -or -not $decision.paths.b.failed -or $decision.paths.b.step -ne 1){throw 'Pin erased a known failure or failed to acknowledge the selector'}
$next=Invoke-TransportDecision -State $decision -Candidates @($rows[1]) -CurrentTag 'b' -Now 11000
if($next.verdict.action -ne 'check-path' -or $next.verdict.tag -ne 'b'){throw 'Pinned paused path never recovers after expiry/cooldown'}
$pin=@{mode='auto';tag=$null};$rows[1].state='ok';$simNow=20000
$decision=(Invoke-TransportDecision -State (New-TransportDecisionState 0 'a') -Candidates $rows -CurrentTag 'a' -Now 0).state
Confirm-DaemonSelection 'b'
if($decision.lastSwitchAt -ne 20000 -or $decision.switches.Count -ne 1 -or $decision.switches[0].from -ne 'a' -or $decision.switches[0].to -ne 'b'){throw 'New engine/default selector was not recorded immediately'}
$next=Invoke-TransportDecision -State $decision -Candidates $rows -CurrentTag 'b' -Now 20001 -Events @(@{at=20001;kind='engine-exit';tag='b';code='process-exited';local=$false})
if($next.verdict.action -ne 'searching' -or 'switch-rate-limited' -notin $next.verdict.notes){throw 'Selector acknowledgement did not start the ten-second cooldown'}
'PASS: daemon selector acknowledgement, pinned penalty expiry, restart/network cooldown; no I/O'
""", encoding='utf-8-sig')
    subprocess.run([PWSH,'-NoLogo','-NoProfile','-NonInteractive','-File',str(helper_checks),'-Scripts',str(DAEMON.parent)],
                   env=dict(os.environ, LOCALAPPDATA=str(root)), stdin=subprocess.DEVNULL, check=True, timeout=25)
    if '--decision-only' in sys.argv:
        sys.exit(0)
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
    write_exe(ssh, '''import json, os, socket, sys, time
from pathlib import Path
root=Path(__file__).parent
# Туннель для теста остановки дочерних: не читает приватных данных.
if '-N' in sys.argv:
    # Real occupied optional SOCKS: the daemon must still start sing-box/VLESS.
    if (root/'optional-busy').exists():
        os.write(2,b'bind: Address already in use\\r\\n'); sys.exit(1)
    listener=socket.socket(); listener.bind(('127.0.0.1',int(sys.argv[sys.argv.index('-D')+1].split(':')[-1]))); listener.listen()
    (root/'tunnel.pid').write_text(str(os.getpid()))
    while True: time.sleep(.1)
with (root/'probes.pid').open('a') as ledger: ledger.write(str(os.getpid())+'\\n')
with (root/'probe-calls.jsonl').open('a') as ledger: ledger.write(json.dumps(dict(at=time.time(),bytes=int(sys.argv[-1].split()[2]),port=int(sys.argv[sys.argv.index('-p')+1])))+'\\n')
port=int(sys.argv[sys.argv.index('-p')+1])
if (root/'fail-all').exists() or ((root/'fail-active').exists() and port==int((root/'fail-active').read_text())):
    os.write(1,b'x'*16384)
    time.sleep(10)
else:
    if (root/'recovery-delay').exists(): time.sleep(1)
    n=int(sys.argv[-1].split()[2]); block=b'x'*8192
    if n==262144 and (root/'slow-rank').exists():
        while True:
            os.write(1,b'x'*1024); time.sleep(.3)
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
                     activeIntervalSec=1, allLivenessIntervalSec=1, rankIntervalSec=1,
                     stallSeconds=2, switch=dict(stallSeconds=1, stallConns=2),
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

    direct_listener = socket.socket()
    direct_listener.bind(('127.0.0.1', 0)); direct_listener.listen()
    direct_port = direct_listener.getsockname()[1]
    direct_connections = []
    def accept_direct():
        while True:
            try:
                conn, _ = direct_listener.accept()
                direct_connections.append(time.monotonic()); conn.close()
            except OSError:
                return
    threading.Thread(target=accept_direct, daemon=True).start()
    source = DAEMON.read_text(encoding='utf-8-sig')
    for name in ('Common', 'Decide', 'Events'):
        target = str(DAEMON.with_name('Transport.'+name+'.ps1')).replace("'", "''")
        source = source.replace("(Join-Path $PSScriptRoot 'Transport."+name+".ps1')", "'"+target+"'")
    scripts_dir = "'"+str(DAEMON.parent).replace("'", "''")+"'"
    source = source.replace('-ArgumentList $PSScriptRoot,$root,$secret,',
                            '-ArgumentList '+scripts_dir+',$root,$secret,')
    shims = r"""
$realReceiveEvents=${function:Receive-TransportEvents}
$realReceivePath=${function:Receive-TransportPathCheck}
function Receive-TransportEvents($Reader) {
    & $realReceiveEvents $Reader
    $f=Join-Path $root 'test-events.json'
    if([IO.File]::Exists($f)){$batch=Read-TransportJson $f;[IO.File]::Delete($f);$batch}
}
function Start-TransportDirectCheck($Network) {
    $port=DIRECT_PORT
    if([IO.File]::Exists((Join-Path $root 'direct-down'))){$port=1}
    $targets=[Net.IPEndPoint[]]@((New-Object Net.IPEndPoint ([Net.IPAddress]::Loopback),$port))
    [RemoteAgents.TransportCheck]::new('',0,$targets,3000)
}
function Receive-TransportDirectCheck($Check) {
    if([IO.File]::Exists((Join-Path $root 'direct-throws'))){throw 'fixture'}
    if(-not [IO.File]::Exists((Join-Path $root 'direct-lost'))){$Check.Result}
}
function Receive-TransportPathCheck($Check) {
    if([IO.File]::Exists((Join-Path $root 'path-throws'))){throw 'fixture'}
    if(-not [IO.File]::Exists((Join-Path $root 'path-lost'))){& $realReceivePath $Check}
}
""".replace('DIRECT_PORT', str(direct_port))
    source=source.replace('$metered=$null\ntry{', shims+'\n$metered=$null\ntry{')
    fixture_daemon=root/'daemon.ps1'; fixture_daemon.write_text(source, encoding='utf-8-sig')

    def emit(kind, tag='', code='timeout', local=False):
        until(lambda: not (root/'test-events.json').exists())
        staged=root/'test-events.tmp'
        staged.write_text(json.dumps([dict(at=int(time.time()*1000),kind=kind,tag=tag,code=code,local=local,detail='')]))
        staged.replace(root/'test-events.json')

    def probe_calls():
        return [json.loads(line) for line in (root/'probe-calls.jsonl').read_text().splitlines()]

    def start(parent_pid=0):
        with (root/'daemon.stdout').open('ab') as out, (root/'daemon.stderr').open('ab') as err:
            p = subprocess.Popen([PWSH, '-NoLogo', '-NoProfile', '-File', str(fixture_daemon), '-Home', str(root),
                                  '-ParentPid', str(parent_pid)], env=env, stdin=subprocess.DEVNULL, stdout=out, stderr=err)
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
        optional.close()  # The optional tunnel starts normally; occupied SSH/Happier still exercise port handling.
        daemon = start()
        first = until(lambda: status() or None, seconds=15)
        assert first.get('phase') in ('checking', 'ok') and (first.get('ok') or first.get('checkingSince')), first
        until(lambda: status().get('ok') and len(status().get('candidates', []))==3 and all(c['state']=='ok' for c in status()['candidates']))
        assert status()['phase']=='ok' and status().get('checkingSince') is None
        assert status()['reason']['code']=='ok' and status()['localNet']=='ok'
        assert all(c['penaltyStep']==0 and c['penaltyUntil'] is None for c in status()['candidates'])
        selected=json.loads((root/'state/transport-ports.json').read_text())
        assert selected['configured']['sshPort']==2222 and selected['effective']['sshPort']==2232
        assert status()['ports']['sshPort']==2232
        assert status()['localWeb']['port']==web_port and status()['localWeb']['conflict']
        assert 'Вход Happier не запущен' in status()['summary'] and status()['ok']
        occupied_web.close(); occupied_ssh.close()
        assert int((root/'starts').read_text())==1
        config=json.loads((root/'state/transport-sing-box.json').read_text())
        assert config['log']['level']=='warn'
        ports={i['tag'][6:]:i['listen_port'] for i in config['inbounds'] if i['tag'].startswith('probe-')}
        # No periodic probes: counters include processes, requested payload and direct TCP connections.
        before=probe_calls(); direct_before=len(direct_connections)
        time.sleep(5)
        assert probe_calls()==before and len(direct_connections)==direct_before, 'traffic without an event'
        assert len(before)==3 and all(c['bytes']==65536 for c in before), before
        initial=status()['active']; first_engine=int((root/'engine.pid').read_text())
        if '--lifecycle-only' not in sys.argv:
            # Local loss and four consecutive process failures must not penalize paths.
            emit('dial-fail',initial,local=True)
            until(lambda: status().get('localNet')=='down')
            assert status()['phase']=='searching' and status()['reason']['code']=='local-network-down'
            (root/'direct-down').touch()
            for _ in range(4):
                emit('engine-exit',initial,'process-exited'); time.sleep(.5)
            time.sleep(1.5)
            assert status()['active']==initial and all(c['penaltyStep']==0 for c in status()['candidates']), status()
            (root/'direct-down').unlink()
            emit('path-check',initial,'ok')
            until(lambda: status().get('ok'))
            # A stall suspicion alone cannot switch. Its real 64 KiB confirmation freezes at 16 KiB.
            (root/'fail-active').write_text(str(ports[initial]))
            calls=len(probe_calls()); emit('stall-suspect',initial,'upload-without-download')
            until(lambda: len(probe_calls())>calls)
            assert status()['active']==initial, 'switched before confirmation'
            assert probe_calls()[calls]['bytes']==65536 and probe_calls()[calls]['port']==ports[initial]
            switched=until(lambda: (s if (s:=status()).get('ok') and s.get('active')!=initial else None), seconds=25)
            assert int((root/'engine.pid').read_text())==first_engine
            first_switch=switched['switches'][-1]
            assert first_switch['from']==initial and first_switch['why']=='path-stalled', first_switch
            assert next(c for c in switched['candidates'] if c['tag']==initial)['penaltyStep']==1
            # Untagged closes after a selector change may be old connections: ignore them.
            current=switched['active']; before_steps={c['tag']:c['penaltyStep'] for c in switched['candidates']}
            emit('conn-closed-error'); time.sleep(1.4)
            assert {c['tag']:c['penaltyStep'] for c in status()['candidates']}==before_steps
            # A second confirmed failure cannot cause a second switch within ten seconds.
            emit('dial-fail',current)
            limited=until(lambda: (s if (s:=status()).get('phase')=='searching' else None), seconds=5)
            assert limited['active']==current
            switched2=until(lambda: (s if (s:=status()).get('ok') and s.get('active')!=current else None), seconds=20)
            times=[datetime.fromisoformat(x['at']).timestamp() for x in switched2['switches']]
            assert all(b-a>=10 for a,b in zip(times,times[1:])), switched2['switches']
            (root/'fail-active').unlink()
            # Lost direct reply must yield net-down/timeout instead of hanging in pending forever.
            (root/'direct-lost').touch(); stamp=time.monotonic()
            emit('dial-fail',status()['active'])
            until(lambda: status().get('localNet')=='down', seconds=6)
            assert time.monotonic()-stamp<6
            assert all(c['penaltyStep']==0 for c in status()['candidates']), 'recent penalties rolled back'
            (root/'direct-lost').unlink(); emit('path-check',status()['active'],'ok')
            until(lambda: status().get('ok'))
            # Lost path-check reply reaches its own deadline, then direct proof releases the reducer.
            old=status()['active']; (root/'path-lost').touch(); stamp=time.monotonic()
            emit('stall-suspect',old)
            until(lambda: status().get('active')!=old and status().get('ok'), seconds=20)
            assert time.monotonic()-stamp<20
            assert status()['switches'][-1]['why']=='path-stalled'
            (root/'path-lost').unlink()
            # Exception paths also release both kinds of waiter.
            (root/'direct-throws').touch(); emit('dial-fail',status()['active'])
            until(lambda: status().get('localNet')=='down', seconds=5)
            (root/'direct-throws').unlink(); emit('path-check',status()['active'],'ok')
            until(lambda: status().get('ok'))
            # Pin, disabled pin, invalid reload and auto remain supported.
            def cli(script, *args):
                subprocess.run([PWSH,'-NoLogo','-NoProfile','-NonInteractive','-File',str(DAEMON.with_name(script)),
                                '-Home',str(root),*args],env=env,check=True,capture_output=True,stdin=subprocess.DEVNULL)
            pinned=status()['active']
            cli('Set-TransportPath.ps1','-Tag',pinned)
            until(lambda: status().get('mode')=='pinned' and status().get('active')==pinned)
            (root/'fail-active').write_text(str(ports[pinned])); emit('dial-fail',pinned)
            until(lambda: status().get('phase')=='searching')
            time.sleep(2); assert status()['active']==pinned and not status()['ok']
            cli('Edit-Transport.ps1','-Disable',pinned)
            until(lambda: int((root/'engine.pid').read_text())!=first_engine)
            until(lambda: any(c['tag']==pinned and not c['enabled'] for c in status().get('candidates',[])))
            assert status()['active']==pinned and not status()['ok']
            cfg=json.loads((root/'state/transport-sing-box.json').read_text())
            assert next(o for o in cfg['outbounds'] if o['tag']=='active')['default']=='unavailable'
            starts=int((root/'starts').read_text()); saved=(root/'config.json').read_text()
            broken=json.loads(saved); broken['transport']['apiPort']=65536
            (root/'config.json').write_text(json.dumps(broken))
            until(lambda: bool(status().get('configError')))
            assert int((root/'starts').read_text())==starts
            (root/'config.json').write_text(saved); (root/'fail-active').unlink()
            cli('Set-TransportPath.ps1','-Auto'); cli('Edit-Transport.ps1','-Enable',pinned)
            until(lambda: status().get('mode')=='auto' and status().get('ok'))
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
        current['transport']['switch']['stallConns']+=1
        before=int((root/'starts').read_text())
        (root/'config.json').write_text(json.dumps(current))
        until(lambda: int((root/'starts').read_text()) > before, seconds=10)
        reconfigured = until(lambda: (s if (s:=status()).get('portConflict') and
                                     s.get('configRevision') != rebound.get('configRevision') else None), seconds=25)
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
        assert status()['phase'] == 'stopped'
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
        assert status()['phase'] == 'stopped'
        assert stopped(int((root / 'engine.pid').read_text()))
        assert stopped(int((root / 'tunnel.pid').read_text()))
        assert all(stopped(int(pid)) for pid in (root/'probes.pid').read_text().splitlines()), 'SSH probe leaked after timeout/stop'
        # Happ: физический интерфейс не найден (Linux-стенд его не имеет). Паузы 3/5/10 с и error= в журнале;
        # резервный режим bind=none только при vpn off, после 3 подряд неудач.
        root2 = root / 'bind-home'
        (root2 / 'status').mkdir(parents=True)
        (root2 / 'state').mkdir()
        cfg2 = json.loads((root / 'config.json').read_text())
        cfg2['transport'].update(bindPhysical=True)
        with socket.socket() as s2:
            s2.bind(('127.0.0.1', 0)); cfg2['transport']['apiPort'] = s2.getsockname()[1]
        cfg2['happier']['localWeb']['enabled'] = False
        (root2 / 'config.json').write_text(json.dumps(cfg2))
        (root2 / 'status/vpn.json').write_text(json.dumps(dict(state='on')))
        for name in ('starts', 'engine.pid'):
            if (root / name).exists(): (root / name).unlink()
        log2 = root2 / 'logs/transport.log'

        def failures():
            if not log2.exists(): return []
            return [l.split()[0] for l in log2.read_text(encoding='utf-8').splitlines()
                    if ' process-failed ' in l and 'error=Физический интерфейс недоступен' in l]
        daemon = subprocess.Popen([PWSH, '-NoLogo', '-NoProfile', '-File', str(fixture_daemon), '-Home', str(root2), '-ParentPid', '0'],
                                  env=dict(os.environ, LOCALAPPDATA=str(root2)), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        children.append(daemon)
        def stamp(line):
            return datetime.fromisoformat(line.split()[0][:26] + '+00:00').timestamp()
        until(lambda: len(failures()) >= 2, seconds=25)
        assert not (root / 'starts').exists(), 'движок не должен стартовать без привязки при vpn on'
        assert 'bind-mode' not in log2.read_text(encoding='utf-8'), 'vpn не off: резервного режима быть не должно'
        # Третья попытка при vpn off входит в резервный режим; пауза до неё 5 с, до второй неудачи 3 с.
        (root2 / 'status/vpn.json').write_text(json.dumps(dict(state='off')))
        until(lambda: 'bind=none reason=no-physical-interface' in log2.read_text(encoding='utf-8'), seconds=25)
        lines = log2.read_text(encoding='utf-8').splitlines()
        fails = [stamp(l) for l in lines if ' process-failed ' in l and 'error=Физический интерфейс недоступен' in l]
        bind = stamp(next(l for l in lines if 'bind=none reason=no-physical-interface' in l))
        assert 1.5 <= fails[1] - fails[0] <= 5.5 and 3.0 <= bind - fails[1] <= 9, ('паузы 3 -> 5 с', fails, bind)
        until(lambda: (root / 'starts').exists(), seconds=10)
        sb_cfg = json.loads((root2 / 'state/transport-sing-box.json').read_text())
        assert sb_cfg['route']['auto_detect_interface'] is False
        assert not any('bind_interface' in o for o in sb_cfg['outbounds']), 'bind=none: без привязки сокетов'
        (root2 / 'stop').touch()
        daemon.wait(timeout=10)
        assert not (root/'daemon.stderr').read_text().strip(), (root/'daemon.stderr').read_text()
        coverage = ('lifecycle, reload, port selection/backoff, bind fallback, stop and ParentPid cleanup'
                    if '--lifecycle-only' in sys.argv else
                    'no periodic traffic, local loss/process gating, 64 KiB stall, ten-second limit, lost replies and exceptions, '
                    'failover, pin/auto, reload, restart, port selection/backoff, bind fallback, stop and ParentPid cleanup')
        print('OK: '+coverage+' (loopback simulators)')

    except Exception:
        print('STATUS', status(), file=sys.stderr)
        for name in ('daemon.stdout','daemon.stderr'):
            if (root/name).exists(): print(name,(root/name).read_text(),file=sys.stderr)
        log=root/'logs/transport.log'
        if log.exists(): print(log.read_text(), file=sys.stderr)
        for p in children:
            if p.poll() is not None: print('EXIT', p.returncode, p.communicate(), file=sys.stderr)
        raise
    finally:
        direct_listener.close(); optional.close(); occupied_ssh.close(); occupied_web.close()
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
