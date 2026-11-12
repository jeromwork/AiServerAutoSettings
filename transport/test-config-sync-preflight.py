#!/usr/bin/env python3
"""Two real sing-box daemons + rootless sshd in disposable homes/ports."""
import json, os, pwd, shutil, socket, subprocess, tempfile, time, uuid
from pathlib import Path
REPO=Path(__file__).resolve().parents[1]
PWSH=Path(os.environ.get('PWSH',Path.home()/'.cache/pwsh-test/pwsh'))
def port():
    with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
def psq(s):return "'"+str(s).replace("'","''")+"'"
def run(args):
    p=subprocess.run(list(map(str,args)),stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=10)
    assert p.returncode==0,p.stderr
    return p.stdout
with tempfile.TemporaryDirectory(prefix='config-sync-preflight-') as tmp:
    d=Path(tmp); children=[]; files=[]
    try:
        for name in ('host','client'):run(['ssh-keygen','-q','-t','ed25519','-N','','-f',d/name])
        pin=' '.join((d/'host.pub').read_text().split()[:2]);ssh_port=port();vless_port=port()
        (d/'authorized_keys').write_text((d/'client.pub').read_text())
        (d/'known_hosts').write_text('127.0.0.1 '+pin+'\n[127.0.0.1]:'+str(ssh_port)+' '+pin+'\n')
        (d/'ssh.conf').write_text('Host *\n Port '+str(ssh_port)+'\n')
        (d/'sshd.conf').write_text(f'''ListenAddress 127.0.0.1
Port {ssh_port}
HostKey {d/'host'}
PidFile {d/'sshd.pid'}
AuthorizedKeysFile {d/'authorized_keys'}
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers {pwd.getpwuid(os.getuid()).pw_name}
AllowTcpForwarding yes
PermitTTY no
''')
        def start(args,log):
            out=(d/log).open('w');files.append(out)
            p=subprocess.Popen(list(map(str,args)),stdin=subprocess.DEVNULL,stdout=out,stderr=out);children.append(p);return p
        server=start(['/usr/sbin/sshd','-D','-e','-f',d/'sshd.conf'],'sshd.log')
        uid=str(uuid.uuid4());binary=shutil.which('sing-box');assert binary,'sing-box required'
        (d/'server.json').write_text(json.dumps(dict(log=dict(level='error'),inbounds=[dict(type='vless',listen='127.0.0.1',listen_port=vless_port,users=[dict(uuid=uid)])],outbounds=[dict(type='direct',tag='direct')],route=dict(final='direct'))))
        vless=start([binary,'run','-c',d/'server.json'],'vless.log')
        for p,n in [(server,ssh_port),(vless,vless_port)]:
            for _ in range(100):
                assert p.poll() is None,'fixture server exited: '+(d/'sshd.log').read_text()+(d/'vless.log').read_text()
                try:
                    with socket.create_connection(('127.0.0.1',n),.1):break
                except OSError:time.sleep(.03)
            else:raise AssertionError('fixture server did not open')
        profile=dict(sshExecutable=shutil.which('ssh'),serverAddress='127.0.0.1',login=pwd.getpwuid(os.getuid()).pw_name,
                     keyPath=str(d/'client'),knownHostsPath=str(d/'known_hosts'),configPath=str(d/'ssh.conf'),arguments=['-p',str(ssh_port)])
        (d/'profile.json').write_text(json.dumps(profile))
        (d/'channel.json').write_text(json.dumps(dict(inbounds=[dict(tag='sync',override_port=23456)],outbounds=[dict(type='vless',tag='channel',server='127.0.0.1',server_port=vless_port,uuid=uid)])))
        root=d/'working';root.mkdir();stage=d/'candidate';stage.mkdir()
        t=dict(profilePath=str(d/'profile.json'),channelPath=str(d/'channel.json'),singBoxPath=binary,bindPhysical=False,openSsh=False,
               channelFirst=True,channelSshAddress='127.0.0.2',metered='false',sshPort=port(),syncPort=port(),apiPort=port(),
               channelSocksPort=port(),probePortBase=port(),socksPortBase=port(),probeTimeoutSec=8,stallSeconds=3)
        for target in (root,stage):(target/'config.json').write_text(json.dumps(dict(schema=1,version=1,transport=t)))
        script=d/'test.ps1'
        script.write_text(f"""$ErrorActionPreference='Stop'
. {psq(REPO/'build/Wizard.Common.ps1')}
$root={psq(root)};$stage={psq(stage)};$repo={psq(REPO)}
$child=$null
try{{
    $child=Start-TransportProcess (Get-TransportPowerShell) @('-NoProfile','-NonInteractive','-File',(Join-Path $repo 'transport/Transport.Daemon.ps1'),'-Home',$root,'-ParentPid',[string]$PID)
    Wait-TransportReady $root 30
    if(-not (Test-LocalSsh $root {t['sshPort']})){{throw 'working channel failed before preflight'}}
    $watch=[Diagnostics.Stopwatch]::StartNew()
    Invoke-TransportPreflight $stage $repo (Read-TransportJson (Join-Path $stage 'config.json'))
    if(-not (Test-StatusFresh $root transport) -or -not (Test-LocalSsh $root {t['sshPort']})){{throw 'preflight interrupted working channel'}}
    @{{ok=$true;preflightMs=$watch.ElapsedMilliseconds}}|ConvertTo-Json -Compress
}}finally{{[IO.File]::WriteAllText((Join-Path $root 'stop'),'stop');if($child){{[void]$child.Process.WaitForExit(5000)}};Stop-TransportProcess $child}}
""")
        p=subprocess.run([str(PWSH),'-NoProfile','-NonInteractive','-File',str(script)],stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=110)
        assert p.returncode==0,p.stdout+p.stderr+'\n'+''.join(f.read_text() for f in d.rglob('transport.log'))
        result=json.loads(p.stdout.strip().splitlines()[-1]);assert result['ok']
        probe=json.loads((stage/'state/transport-probe/config.json').read_text(encoding='utf-8-sig'))['transport']
        for key in ('sshPort','syncPort','apiPort','channelSocksPort','probePortBase','socksPortBase','channelSshAddress'):
            assert probe[key]!=t[key],key+' was shared with working daemon'
        assert json.loads((root/'config.json').read_text())['transport']==t,'working ports mutated'
        print(f"PASS: concurrent real VLESS/SSH working + preflight daemons, {result['preflightMs']} ms; all seven listener/range settings isolated; working SSH survives")
    finally:
        for p in reversed(children):
            if p.poll() is None:
                p.terminate()
                try:p.wait(5)
                except subprocess.TimeoutExpired:p.kill();p.wait(5)
        for f in files:f.close()
