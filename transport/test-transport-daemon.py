#!/usr/bin/env python3
"""Real daemon + A/B, fake executables/Clash WS, loopback checks only; <=420 s.
No rewritten PowerShell or replaced functions: tests exercise production arguments.
"""
from datetime import datetime
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time

PWSH = sys.argv[1] if len(sys.argv) > 1 else 'pwsh'
DAEMON = Path(__file__).with_name('Transport.Daemon.ps1').resolve()
START = time.monotonic()
BUDGET = float(os.environ.get('TRANSPORT_DAEMON_TEST_BUDGET', '400'))
START_WAIT = 90


def until(check, seconds=15, *, deadline=None, label='local fixture'):
    began = time.monotonic()
    deadline = min(deadline if deadline is not None else began + seconds, START + BUDGET)
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.08)
    raise AssertionError('Deadline exceeded: %s; waited %.2fs; loadavg=%s' %
                         (label, time.monotonic()-began, os.getloadavg()))


def executable(path, source):
    path.write_text('#!' + sys.executable + '\n' + source)
    path.chmod(0o700)


def read_json(path, default=None):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def records(path):
    try:
        return [json.loads(line) for line in path.read_text().splitlines()]
    except FileNotFoundError:
        return []


def stopped(pid):
    try:
        return Path('/proc/%d/stat' % pid).read_text().split()[2] == 'Z'
    except FileNotFoundError:
        return True


with tempfile.TemporaryDirectory(prefix='transport-daemon-test-') as tmp:
    root = Path(tmp)
    (root / 'state').mkdir()
    (root / 'ws.jsonl').touch()
    # Real direct-check constructor gets two loopback endpoints; nothing goes outside.
    direct = socket.socket()
    direct.bind(('127.0.0.1', 0)); direct.listen()
    direct_calls = []

    def accept_direct():
        while True:
            try:
                c, _ = direct.accept()
                c.settimeout(4)
                direct_calls.append(c.recv(1))  # connect only: no payload
                c.close()
            except OSError:
                return
    threading.Thread(target=accept_direct, daemon=True).start()
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0)); api_port = s.getsockname()[1]
    ssh, sb = root / 'ssh.exe', root / 'sing-box'
    executable(ssh, r'''import json, os, socket, sys, time
from pathlib import Path
root=Path(__file__).parent
if '-N' in sys.argv:
    listener=socket.socket(); listener.bind(('127.0.0.1',int(sys.argv[sys.argv.index('-D')+1].split(':')[-1]))); listener.listen()
    (root/'tunnel.pid').write_text(str(os.getpid()))
    while True: time.sleep(.1)
port=int(sys.argv[sys.argv.index('-p')+1]); n=int(sys.argv[-1].split()[2])
with (root/'probes.jsonl').open('a') as f: f.write(json.dumps(dict(port=port,bytes=n,pid=os.getpid(),at=time.time()))+'\n')
modes=json.loads((root/'modes.json').read_text()); mode=modes.get(str(port),{}).get('probe','ok')
if mode=='hang':
    os.write(1,b'x'*16384); time.sleep(60)
elif mode=='dead': time.sleep(60)
else:
    if mode=='hold-ok':
        while (root/'hold-proof').exists(): time.sleep(.02)
    # Deterministic startup first A, while still checking every candidate concurrently.
    time.sleep(.05 if port==26000 else .15)
    os.write(1,b'x'*n)
''')
    executable(sb, r'''import http.server, json, os, socketserver, sys, threading, time
from pathlib import Path
sys.path.insert(0,FAKE_MODULE)
from clash_ws_fake import websocket
root=Path(__file__).parent
if sys.argv[1]=='check':
    with (root/'checks.jsonl').open('a') as f: f.write(json.dumps(dict(at=time.time()))+'\n')
    deadline=time.monotonic()+10
    while (root/'hold-validation').exists() and time.monotonic()<deadline: time.sleep(.02)
    sys.exit(2 if (root/'hold-validation').exists() else 0)
c=json.loads(Path(sys.argv[-1]).read_text()); api=c['experimental']['clash_api']
(root/'engine.pid').write_text(str(os.getpid()))
class Banner(socketserver.BaseRequestHandler):
    def handle(self):
        mode=json.loads((root/'modes.json').read_text()).get(str(self.server.server_address[1]),{}).get('banner','ok')
        with (root/'banners.jsonl').open('a') as f: f.write(json.dumps(dict(port=self.server.server_address[1],at=time.time()))+'\n')
        if mode=='dead': time.sleep(15)
        else: self.request.sendall(b'SSH-2.0-fixture\r\n')
class TCP(socketserver.ThreadingTCPServer):
    allow_reuse_address=True
    daemon_threads=True
banner_servers={}
for i in c['inbounds']:
    if i['tag'].startswith('probe-'):
        server=TCP(('127.0.0.1',i['listen_port']),Banner)
        banner_servers[i['listen_port']]=server
        threading.Thread(target=server.serve_forever,kwargs=dict(poll_interval=.02),daemon=True).start()
def close_refused_banners():
    # A real refused TCP connect lets the cooldown scenario enter recovery by
    # condition, without spending six seconds of the ten-second switch window.
    while True:
        modes=json.loads((root/'modes.json').read_text())
        for port,server in list(banner_servers.items()):
            if modes.get(str(port),{}).get('banner')=='refused':
                server.shutdown(); server.server_close(); del banner_servers[port]
                (root/('banner-closed-'+str(port))).touch()
        time.sleep(.02)
threading.Thread(target=close_refused_banners,daemon=True).start()
class API(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def do_GET(self): websocket(self,root,api['secret'])
    def do_PUT(self):
        if self.headers.get('Authorization')!='Bearer '+api['secret']:
            self.send_error(401); return
        data=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with (root/'puts.jsonl').open('a') as f: f.write(json.dumps(dict(tag=data['name'],at=time.time()))+'\n')
        self.send_response(204); self.send_header('Content-Length','0'); self.end_headers()
    def log_message(self,*args): pass
class HTTP(http.server.ThreadingHTTPServer):
    allow_reuse_address=True
    daemon_threads=True
HTTP(('127.0.0.1',int(api['external_controller'].split(':')[-1])),API).serve_forever()
'''.replace('FAKE_MODULE', repr(str(DAEMON.parent))))
    profile = dict(sshExecutable=str(ssh), serverAddress='203.0.113.10', login='alice',
                   keyPath=str(root/'key'), knownHostsPath=str(root/'known_hosts'), arguments=[])
    (root/'known_hosts').write_text('203.0.113.10 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDKtkImHp4iQlyBtwBY4Vx3cBxfNF0Hdga/ucaszwI2r\n')
    (root/'profile.json').write_text(json.dumps(profile))
    (root/'channel.json').write_text(json.dumps(dict(inbounds=[dict(tag='sync',override_port=23456)],
        outbounds=[dict(type='vless',tag='old',server='203.0.113.10',server_port=443,uuid='00000000-0000-4000-8000-000000000001')])))
    transport = dict(profilePath=str(root/'profile.json'), channelPath=str(root/'channel.json'), singBoxPath=str(sb),
        bindPhysical=False, metered='false', openSsh=False, apiPort=api_port,
        switch=dict(stallSeconds=2,stallConns=2),stallSeconds=2,probeTimeoutSec=8,restartDelaySec=1)
    # Explicit compatibility regression: obsolete scheduling keys MUST be ignored.
    transport.update(activeIntervalSec=1,allLivenessIntervalSec=1,rankIntervalSec=1)
    config = dict(version=1,transport=transport)
    (root/'config.json').write_text(json.dumps(config))
    (root/'modes.json').write_text('{}')
    endpoint='127.0.0.1:%d' % direct.getsockname()[1]
    env=dict(os.environ,LOCALAPPDATA=str(root),REMOTEAGENTS_TEST_DIRECT_TARGETS=endpoint+','+endpoint)
    daemon=None; parent=None; daemon_started=None
    out=(root/'stdout').open('w'); err=(root/'stderr').open('w')
    def start(parent_pid=0):
        global daemon_started
        daemon_started=time.monotonic()
        return subprocess.Popen([PWSH,'-NoLogo','-NoProfile','-NonInteractive','-File',str(DAEMON),'-Home',str(root),
            '-ParentPid',str(parent_pid)],env=env,stdin=subprocess.DEVNULL,stdout=out,stderr=err)
    def status(): return read_json(root/'status/transport.json',{})
    def safe_text(text):
        secret=read_json(root/'state/transport-secret.json',{}).get('secret')
        sensitive=[secret, '00000000-0000-4000-8000-000000000001']
        for name in ('key','known_hosts'):
            path=root/name
            if path.exists():
                lines=path.read_text().splitlines()
                sensitive.extend(lines)
                if name=='known_hosts': sensitive.extend(line.split()[-1] for line in lines if line.split())
        # Drop whole lines containing credentials, including raw fixture key material.
        return '\n'.join(line for line in text.splitlines() if
            not re.search(r'password|passwd|passphrase|private[ _-]?key|authorization|bearer|ssh-ed25519',line,re.I)
            and not any(value and value in line for value in sensitive))
    def wait_ready(check, *, label, deadline=None):
        def checked():
            code=daemon.poll()
            if code is not None:
                raise AssertionError('daemon exited: returncode=%s; stderr=%s' %
                                     (code,safe_text((root/'stderr').read_text())))
            current=status()
            errors={key:current.get(key) for key in ('fatal','configError','portConflict')}
            if errors['fatal'] is True or errors['configError'] or errors['portConflict']:
                raise AssertionError('daemon startup error: '+safe_text(str(errors)))
            return check()
        return until(checked,seconds=START_WAIT,deadline=deadline,label=label)
    def diagnostics():
        current=status(); now=time.time(); updated=current.get('updatedAt'); age=None
        if updated:
            try: age=now-datetime.fromisoformat(updated).timestamp()
            except (TypeError,ValueError): pass
        elapsed=None if daemon_started is None else time.monotonic()-daemon_started
        path=root/'probes.jsonl'
        count=len(path.read_text().splitlines()) if path.exists() else 0
        print('STATUS',safe_text(str(current)),file=sys.stderr)
        print('DIAGNOSTICS: now=%s updatedAt=%s age_seconds=%s daemon_elapsed_seconds=%s '
              'loadavg=%s probes_exists=%s probes_records=%s' %
              (datetime.fromtimestamp(now).astimezone().isoformat(),updated,age,elapsed,
               os.getloadavg(),path.exists(),count),file=sys.stderr)
        log=root/'logs/transport.log'
        print('logs/transport.log (last 30 lines)',
              safe_text('\n'.join(log.read_text().splitlines()[-30:])) if log.exists() else '<missing>',
              file=sys.stderr)
    def puts(): return records(root/'puts.jsonl')
    def probes(): return records(root/'probes.jsonl')
    def row(tag): return next(c for c in status()['candidates'] if c['tag']==tag)
    def engine_pid(): return int((root/'engine.pid').read_text())
    def modes(values):
        target=root/'modes.tmp'; target.write_text(json.dumps(values)); target.replace(root/'modes.json')
    def emit(stream,data):
        with (root/'ws.jsonl').open('a') as f: f.write(json.dumps(dict(stream=stream,data=data))+'\n')
    def dial(tag,local=False):
        emit('logs',dict(type='error',payload='open connection to fixture:443 using outbound/vless[%s]: %s' %
                        (tag,'network is unreachable' if local else 'i/o timeout')))
    def ready():
        wait_ready(lambda: status().get('ok') and len(probes())>=2 and all(c['state']=='ok' for c in status()['candidates']),
                   label='initial daemon and path proof')
        # Wait for the initial round AND both real WS subscriptions before injection.
        wait_ready(lambda: len(records(root/'subscriptions.jsonl'))>=2,label='initial WebSocket subscriptions')
    def reload(cancel=False):
        began=time.monotonic(); requested_at=time.time(); checks=len(records(root/'checks.jsonl'))
        old=engine_pid(); subscriptions=len(records(root/'subscriptions.jsonl')); revision=status()['configRevision']
        if cancel: (root/'hold-validation').touch()
        transport['restartDelaySec']=1 if transport['restartDelaySec']==2 else 2
        target=root/'config.tmp'; target.write_text(json.dumps(config)); target.replace(root/'config.json')
        # Preserve the existing validation/gate deadline separately from engine readiness.
        # Do not confuse slow job startup with failed cancellation.
        deadline=time.monotonic()+30
        if cancel:
            # Validation runs asynchronously while the old engine stays available.
            # Hold the fixture validator, then create a REAL in-flight gate just
            # before releasing it. Cancellation timing excludes job startup.
            until(lambda: len(records(root/'checks.jsonl'))>checks,
                  deadline=deadline,label='reload validation started')
            banners=len(records(root/'banners.jsonl')); dial(status()['active'])
            until(lambda: len(records(root/'banners.jsonl'))>banners,
                  deadline=deadline,label='gate running during validated reload')
            assert not stopped(old), 'old engine stopped before validation finished'
            modes({}); (root/'hold-validation').unlink()
            cancel_began=time.monotonic()
            until(lambda: stopped(old),seconds=5.8,label='validated reload cancels old engine')
            print('CANCEL: old engine stopped %.2fs after validation release' %
                  (time.monotonic()-cancel_began),flush=True)
        def replaced():
            return stopped(old) and engine_pid()!=old
        # Engine readiness may be slow on a loaded host; cancellation above still has 5.8 s.
        ready_deadline=began+START_WAIT
        wait_ready(replaced,deadline=ready_deadline,label='reload replaces engine after validation')
        replaced_after=time.monotonic()-began
        wait_ready(lambda: len(records(root/'subscriptions.jsonl'))>=subscriptions+2,
              deadline=ready_deadline,label='reload WebSocket subscriptions')
        wait_ready(lambda: status().get('configRevision')!=revision and status().get('ok') and
              all(c['state']=='ok' for c in status()['candidates']),
              deadline=ready_deadline,label='reload revision and initial path proof')
        validation=records(root/'checks.jsonl')[checks:]
        assert validation, 'reload skipped sing-box config validation'
        print('RELOAD: validation %.2fs; replaced %.2fs; paths/subscriptions ready %.2fs' %
              (validation[0]['at']-requested_at,replaced_after,time.monotonic()-began),flush=True)
        return old
    def reset_generation(tag=None):
        # Reset gate/reducer state through the real pin control, without paying for
        # another validation process/engine restart between unrelated scenarios.
        # Wait for PUBLISHED fresh results: exited SSH children alone can still
        # have undelivered ok events that would erase the next injected failure.
        # Reload itself is covered after site errors/rate limiting and during a check.
        old=engine_pid(); deadline=time.monotonic()+12; probe_start=len(probes())
        subscriptions=len(records(root/'subscriptions.jsonl'))
        def subscribed():
            return {'logs','connections'} <= {r['stream'] for r in records(root/'subscriptions.jsonl')[subscriptions:]}
        def fresh(tags,since):
            current=[c for c in status().get('candidates',[]) if c['tag'] in tags]
            return len(current)==len(tags) and all(c.get('checkedAt') and
                datetime.fromisoformat(c['checkedAt']).timestamp()>=since for c in current)
        pin_at=time.time()
        pin_file=root/'state/transport-pin.json'; tag=tag or status()['active']
        pin_file.write_text(json.dumps(dict(mode='pinned',tag=tag)))
        until(lambda: status().get('mode')=='pinned' and status().get('active')==tag and status().get('ok') and
              len(probes())>probe_start and all(stopped(p['pid']) for p in probes()[probe_start:]) and subscribed() and fresh([tag],pin_at),
              deadline=deadline,label='pin generation ready')
        probe_start=len(probes()); subscriptions=len(records(root/'subscriptions.jsonl')); auto_at=time.time()
        pin_file.write_text(json.dumps(dict(mode='auto',tag=None)))
        until(lambda: status().get('mode')=='auto' and status().get('ok') and
              all(c['state']=='ok' for c in status()['candidates']) and
              len(probes())>=probe_start+len(ports) and all(stopped(p['pid']) for p in probes()[probe_start:]) and subscribed() and fresh(ports,auto_at),
              deadline=deadline,label='automatic generation ready')
        assert engine_pid()==old, 'pin reset restarted engine'
        assert_clean()
    def pass_test(name): print('PASS: '+name,flush=True)
    def stall(tag,stop_when,seconds=7):
        deadline=time.monotonic()+seconds; seq=0
        while time.monotonic()<deadline:
            seq+=1
            emit('connections',dict(connections=[dict(id='stall-'+str(i),upload=seq*100,download=0,chains=[tag,'active'],
                start='2026-11-19T10:00:00Z',metadata=dict(type='mixed/vpn-in')) for i in range(2)]))
            if stop_when(): break
            time.sleep(.15)
        emit('connections',dict(connections=[]))
    def assert_clean():
        assert all(c['penaltyStep']==0 for c in status()['candidates']),status()
        assert status()['localNet']!='down',status()

    try:
        daemon=start(); ready()
        cfg=read_json(root/'state/transport-sing-box.json')
        assert cfg['log']['level']=='warn'
        ports={i['tag'][6:]:i['listen_port'] for i in cfg['inbounds'] if i['tag'].startswith('probe-')}
        assert len(ports)==2,ports
        # 3: twenty seconds of real subscriptions do not cause scheduled SSH/direct probes.
        before=probes(); direct_before=len(direct_calls); time.sleep(20)
        assert probes()==before and len(direct_calls)==direct_before
        assert len(before)==2 and all(p['bytes']==65536 for p in before)
        pass_test('no-scheduled-probes')
        # 2: healthy banner proves the path; repeated site errors reuse its 30 s window.
        a=status()['active']; baseline=len(puts()); banner_count=len(records(root/'banners.jsonl'))
        dial(a); until(lambda: len(records(root/'banners.jsonl'))>banner_count)
        time.sleep(1.4); dial(a); time.sleep(1.2)
        assert len(puts())==baseline and row(a)['penaltyStep']==0 and status()['phase']=='ok',status()
        assert len(records(root/'banners.jsonl'))==banner_count+1
        pass_test('site-failure-no-switch')
        # The pin/auto generation below resets the gate; reload is exercised
        # after rate limiting and while a real gate is running.
        # 1: refused banner -> REAL loopback direct proof -> selector failover.
        # Force a recent real selector change, then return to auto. The first
        # failure must meet the 10 s cooldown, so recovery starts BEFORE failover.
        reset_generation(next(t for t in ports if t!=status()['active']))
        a=status()['active']; b=next(t for t in ports if t!=a); pid=engine_pid()
        selection=datetime.fromisoformat(status()['switches'][-1]['at']).timestamp()
        recovery_start=len(probes())
        modes({str(ports[a]):dict(banner='refused',probe='hang')})
        until(lambda: (root/('banner-closed-'+str(ports[a]))).exists(),label='refused banner listener closed')
        began=time.monotonic(); dial(a)
        deadline=began+15
        until(lambda: status().get('phase')=='searching' and
              status().get('reason',{}).get('code')=='path-dial-failed' and
              len(probes())>=recovery_start+2,deadline=deadline,label='recovery before first failover')
        recovery=probes()[recovery_start:]
        assert sorted(p['port'] for p in recovery)==sorted(ports.values()),recovery
        assert all(p['at']<selection+10 for p in recovery),recovery
        until(lambda: all(stopped(p['pid']) for p in recovery) and row(a)['state']=='fail',
              deadline=deadline,label='recovery finishes with failed target')
        until(lambda: status().get('ok') and status().get('active')==b,
              deadline=deadline,label='first failover after recovery')
        assert time.monotonic()-began<=15 and engine_pid()==pid
        assert row(a)['penaltyStep']>=1 and status()['switches'][-1]['why']=='path-dial-failed',status()
        assert direct_calls and all(c==b'' for c in direct_calls)
        pass_test('failover')
        # 6: recovery is already spent for 60 s and A's row is still fail.
        # Hold A's new proof until the real selector AND failed row are observed:
        # an acknowledgement alone must not make the watchdog consider it ready.
        assert row(a)['state']=='fail',status()
        first_switch=datetime.fromisoformat(status()['switches'][-1]['at']).timestamp()
        (root/'hold-proof').touch()
        modes({str(ports[b]):dict(banner='dead',probe='hang'),str(ports[a]):dict(probe='hold-ok')})
        baseline=len(puts()); proof_start=len(probes()); began=time.monotonic(); dial(b)
        deadline=began+15
        until(lambda: status().get('active')==b and row(b)['penaltyStep']>=1 and
              status().get('phase')=='searching',deadline=deadline,label='second failure inside cooldown')
        assert time.time()<first_switch+10 and row(a)['state']=='fail',status()
        def switched_back():
            changes=puts()[baseline:]
            if not changes: return False
            assert all(p['at']>=first_switch+10 for p in changes),changes
            return any(p['tag']==a for p in changes)
        until(switched_back,deadline=deadline,label='second failover respects 10 s cooldown')
        switched_at=time.monotonic()
        until(lambda: status().get('active')==a and row(a)['state']=='fail' and not status().get('ok'),
              deadline=deadline,label='selected path still requires proof')
        until(lambda: any(p['port']==ports[a] for p in probes()[proof_start:]),
              deadline=deadline,label='independent 64 KiB selected-path check')
        (root/'hold-proof').unlink()
        until(lambda: status().get('ok') and status().get('active')==a and row(a)['state']=='ok',
              deadline=deadline,label='selected failed row becomes watchdog-ready within 15 s')
        assert time.monotonic()-switched_at<=15 and engine_pid()==pid
        history=status()['switches']; times=[datetime.fromisoformat(x['at']).timestamp() for x in history]
        assert all(y-x>=10 for x,y in zip(times,times[1:]) if y>=selection+10),history
        print('RECOVERY: completed before second failure; selected failed row confirmed %.2fs after switch' %
              (time.monotonic()-switched_at),flush=True)
        pass_test('switch-rate-limit')
        modes({}); reload()
        # 4: B's local classification rolls back penalties without selector/process changes.
        a=status()['active']; pid=engine_pid(); baseline=len(puts()); dial(a,local=True)
        until(lambda: status().get('localNet')=='down')
        assert status()['phase']=='searching' and status()['reason']['code']=='local-network-down'
        assert len(puts())==baseline and engine_pid()==pid
        assert all(c['penaltyStep']==0 for c in status()['candidates'])
        pass_test('local-network-down')
        reset_generation()
        # 5: real connection snapshots -> 64 KiB confirmation, success then frozen variant.
        a=status()['active']; count=len(probes()); baseline=len(puts())
        stall(a,lambda: len(probes())>count)
        until(lambda: status().get('phase')=='ok'); time.sleep(.5)
        assert len(puts())==baseline and probes()[count]['bytes']==65536 and probes()[count]['port']==ports[a]
        reset_generation()  # reset reducer's 60 s ignore-after-success window
        a=status()['active']; count=len(probes()); pid=engine_pid()
        modes({str(ports[a]):dict(probe='hang')})
        stall(a,lambda: len(probes())>count)
        until(lambda: status().get('ok') and status().get('active')!=a,seconds=15)
        assert status()['switches'][-1]['why']=='path-stalled' and engine_pid()==pid,status()
        assert probes()[count]['bytes']==65536 and probes()[count]['port']==ports[a]
        pass_test('stall-confirm')
        modes({}); reset_generation()
        # 9: cancel a REAL gate by hot reload before its 6 s timeout, with results discarded.
        a=status()['active']
        modes({str(ports[a]):dict(banner='dead')})
        reload(cancel=True)
        assert_clean(); time.sleep(1.2); assert_clean()
        pass_test('cancel-no-penalty')
        # 8: reader and reducer see pinned A only; failures never select B.
        a=status()['active']; (root/'state/transport-pin.json').write_text(json.dumps(dict(mode='pinned',tag=a)))
        until(lambda: status().get('mode')=='pinned' and status().get('ok'))
        time.sleep(.4); baseline=len(puts())
        modes({str(ports[a]):dict(banner='dead',probe='hang')}); dial(a)
        until(lambda: status().get('phase')=='searching',seconds=12)
        assert status()['active']==a and all(x['tag']==a for x in puts()[baseline:]),status()
        pass_test('pinned-no-switch')
        modes({}); (root/'state/transport-pin.json').write_text(json.dumps(dict(mode='auto',tag=None)))
        until(lambda: status().get('mode')=='auto' and status().get('ok') and
              all(c['state']=='ok' for c in status()['candidates']))
        # 7: both banners fail together -> both penalized, engine stays alive.
        assert_clean(); pid=engine_pid()
        modes({str(p):dict(banner='dead',probe='hang') for p in ports.values()})
        for t in ports: dial(t)
        until(lambda: status().get('phase')=='searching' and status().get('reason',{}).get('code') in
              ('all-paths-penalized','no-candidates'),seconds=12)
        assert all(c['penaltyStep']>=1 for c in status()['candidates']) and engine_pid()==pid and daemon.poll() is None,status()
        pass_test('all-penalized-searching')
        # 10: old consumer and complete status contract, including actual history times.
        s=status(); assert set(('code','text','since'))<=s['reason'].keys()
        datetime.fromisoformat(s['reason']['since']); assert s['localNet'] in ('ok','down','unknown')
        assert 0<len(s['switches'])<=10
        for x in s['switches']: datetime.fromisoformat(x['at']); assert set(('from','to','why'))<=x.keys()
        for c in s['candidates']:
            assert 0<=c['penaltyStep']<=5
            if c['penaltyUntil']: datetime.fromisoformat(c['penaltyUntil'])
        cli=subprocess.run([PWSH,'-NoProfile','-NonInteractive','-File',str(DAEMON.with_name('Get-TransportStatus.ps1')),
                            '-Home',str(root)],env=env,stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=8)
        assert cli.returncode==0,cli.stderr
        pass_test('status-fields')
        # Preserve stop/child cleanup assertions and parent-driven shutdown, with a real fake tunnel.
        (root/'stop').touch(); daemon.wait(timeout=8); assert daemon.returncode==0
        assert status()['phase']=='stopped' and stopped(pid)
        assert all(stopped(p['pid']) for p in probes()),'SSH probe leaked after cancellation/stop'
        modes({}); (root/'stop').unlink(); transport['openSsh']=True
        (root/'config.json').write_text(json.dumps(config))
        # Parent must survive both startup waits; shutdown is triggered explicitly below.
        parent=subprocess.Popen([sys.executable,'-c','import time; time.sleep(%s)' % (2*START_WAIT+30)])
        daemon=start(parent.pid)
        wait_ready(lambda: status().get('ok') and len(status()['candidates'])==3,label='openSsh daemon ready')
        wait_ready(lambda: (root/'tunnel.pid').exists(),label='openSsh tunnel ready')
        tunnel=int((root/'tunnel.pid').read_text()); pid=engine_pid()
        parent.terminate(); parent.wait(timeout=3); daemon.wait(timeout=8)
        assert daemon.returncode==0 and status()['phase']=='stopped'
        assert stopped(pid) and stopped(tunnel) and all(stopped(p['pid']) for p in probes())
        assert all(p['bytes']==65536 for p in probes()),'262144-byte rank probe'
        assert not (root/'stderr').read_text().strip(),(root/'stderr').read_text()
        print('PASS: child-cleanup; real A/B integration %.1f s' % (time.monotonic()-START),flush=True)
    except Exception:
        diagnostics()
        for name in ('stderr','puts.jsonl','probes.jsonl','banners.jsonl','checks.jsonl','subscriptions.jsonl','ws.jsonl','modes.json'):
            if (root/name).exists(): print(name,safe_text((root/name).read_text()),file=sys.stderr)
        raise
    finally:
        if daemon and daemon.poll() is None:
            (root/'stop').touch()
            try: daemon.wait(timeout=5)
            except subprocess.TimeoutExpired: daemon.kill(); daemon.wait()
        if parent and parent.poll() is None: parent.terminate(); parent.wait()
        direct.close(); out.close(); err.close()
        for name in ('engine.pid','tunnel.pid'):
            if (root/name).exists():
                try: os.kill(int((root/name).read_text()),9)
                except ProcessLookupError: pass
        for p in probes():
            if not stopped(p['pid']):
                try: os.kill(p['pid'],9)
                except ProcessLookupError: pass
