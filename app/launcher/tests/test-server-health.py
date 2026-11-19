#!/usr/bin/env python3
"""Real Wizard ServerHealth dispatch with one fake saved-route SSH call; no live hosts."""
import json
import os
import re
import shutil
from pathlib import Path
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[3]
PWSH = Path(os.environ.get('PWSH', Path.home()/'.cache/pwsh-test/pwsh'))
FIXTURE = ('health=1\ndiskTotalKb=100000\ndiskUsedKb=80000\ndiskFreeKb=15000\n'
           'memoryTotalKb=10000\nmemoryAvailableKb=900\nload1=1.25\nload5=0.5\n'
           'load15=0.75\ncores=4\nuptimeSec=90061.25\n')

def quote(value): return "'" + str(value).replace("'", "''") + "'"

def run(args, env, timeout=20):
    return subprocess.run([str(x) for x in args], env=env, stdin=subprocess.DEVNULL,
                          capture_output=True, text=True, timeout=timeout)

with tempfile.TemporaryDirectory(prefix='server-health-') as tmp:
    d = Path(tmp); root = d/'local/RemoteAgents'; root.mkdir(parents=True)
    fake = d/'ssh'
    fake.write_text(r'''#!/usr/bin/env python3
import json,os,sys,time
from pathlib import Path
d=Path(os.environ['HEALTH_FIXTURE'])
(d/'ssh-start').write_text(str(time.monotonic()))
with (d/'calls').open('a') as f: f.write(json.dumps(sys.argv[1:])+'\n')
assert sys.argv[-2]==os.environ.get('HEALTH_ADDRESS','127.0.0.3'), 'must use configured working channel'
assert sys.argv[sys.argv.index('-p')+1]==os.environ.get('HEALTH_PORT','22255')
assert 'BatchMode=yes' in sys.argv and 'StrictHostKeyChecking=yes' in sys.argv
assert 'HostKeyAlias=blocked.example.invalid' in sys.argv
command=sys.argv[-1]
assert '\r' not in command, 'CRLF command must normalize at SSH boundary'
assert 'df -Pk "$HOME"' in command and '/proc/meminfo' in command
assert '/proc/loadavg' in command and '_NPROCESSORS_ONLN' in command and '/proc/uptime' in command
assert not any(word in command for word in ['sudo ', 'mkdir ', 'systemctl ', 'du '])
mode=(d/'mode').read_text()
if mode=='timeout':time.sleep(30)
if mode=='pin':print('Host key verification failed.',file=sys.stderr);sys.exit(255)
if mode=='invalid':sys.stdout.write('health=1\r\npassword=SECRET\r\n');sys.exit(0)
output=(d/'output').read_bytes()
if mode=='switch':
    profile=d/'profile.json'; changed=json.loads(profile.read_text())
    changed['serverAddress']='replacement.example.invalid';profile.write_text(json.dumps(changed))
if mode=='negative':output=output.replace(b'diskFreeKb=15000',b'diskFreeKb=-500')
sys.stdout.buffer.write(output)
''')
    fake.chmod(0o700); (d/'output').write_bytes(FIXTURE.replace('\n', '\r\n').encode())
    profile=d/'profile.json'
    profile.write_text(json.dumps(dict(sshExecutable=str(fake), serverAddress='blocked.example.invalid',
        login='worker', keyPath=str(d/'unused-key'), knownHostsPath=str(d/'pins'), arguments=['-p','22255'])))
    config=dict(schema=1,version=1,transport=dict(profilePath=str(profile),channelFirst=True,
        channelSshAddress='127.0.0.3',sshPort=2222,channelSocksPort=2223),bridge=dict(enabled=True))
    (root/'config.json').write_text(json.dumps(config)); original=(root/'config.json').read_bytes()
    env={**os.environ,'LOCALAPPDATA':str(d/'local'),'HEALTH_FIXTURE':str(d)}
    # Build exactly the standalone runtime used by sync/rollback, then load it in
    # a fresh process. No repository fallback may hide missing copied libraries.
    listing=run([PWSH,'-NoProfile','-NonInteractive','-Command',
        f". {quote(REPO/'build/Wizard.Engine.ps1')}; @(Get-WizardRuntimeFiles) | ConvertTo-Json -Compress"],env)
    assert listing.returncode==0,(listing.stdout,listing.stderr)
    runtime_files=json.loads(listing.stdout)
    runtime=d/'runtime'
    for name in runtime_files:
        target=runtime/name; target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(REPO/name,target)
    probe=d/'runtime-load.ps1'
    probe.write_text(f"""$ErrorActionPreference='Stop'
. {quote(runtime/'build/Wizard.Common.ps1')}
foreach($name in @('Invoke-WizardStep','Get-WizardServerHealth','Get-WizardRuntimeFiles')){{
    if(-not (Get-Command $name -ErrorAction SilentlyContinue)){{throw ('runtime did not load '+$name)}}
}}
Write-Output 'PASS: standalone runtime loads Wizard.Common.ps1'
""")
    p=run([PWSH,'-NoProfile','-NonInteractive','-File',probe],env)
    assert p.returncode==0,(p.stdout,p.stderr)
    print(p.stdout.strip())
    for source in ('build/Wizard.Common.ps1','build/Wizard.ps1'):
        for line in (REPO/source).read_text(encoding='utf-8-sig').splitlines():
            if not line.lstrip().startswith('. '):continue
            dependency=re.fullmatch(r"\. \(Join-Path (\$PSScriptRoot|\(Split-Path \$PSScriptRoot -Parent\)) '([^']+)'\)",line.strip())
            assert dependency,('unhandled dot-source dependency',source,line)
            base=Path('build') if dependency[1]=='$PSScriptRoot' else Path('.')
            assert (base/dependency[2]).as_posix() in runtime_files,('missing runtime dependency',source,line)
    print('PASS: every Wizard.Common.ps1/Wizard.ps1 dot-source dependency is in Get-WizardRuntimeFiles')
    wizard=runtime/'build/Wizard.ps1'
    before=0; timings={}
    for mode in ('ok','negative','invalid','pin','timeout'):
        (d/'mode').write_text(mode); start=time.monotonic()
        p=run([PWSH,'-NoProfile','-NonInteractive','-File',wizard,'-Home',root,'-Action','ServerHealth'],env)
        timings[mode]=round((time.monotonic()-start)*1000)
        result=json.loads(p.stdout.strip().splitlines()[-1]); state=json.loads((root/'state/server-health.json').read_text(encoding='utf-8-sig'))
        calls=(d/'calls').read_text().splitlines()
        assert len(calls)==before+1, 'one SSH attempt only even on exit 255 / timeout'
        before=len(calls)
        assert (root/'config.json').read_bytes()==original, 'read-only action must not edit config'
        assert not (root/'state/connection-generations').exists(), 'must not probe/start transports'
        assert not (root/'state/wizard-control').exists(), 'must not start a persistent session'
        # CLI wall time includes loading PowerShell; measure the SSH timeout
        # separately so slow startup cannot masquerade as an unbounded probe.
        if mode=='timeout':
            assert time.monotonic()-float((d/'ssh-start').read_text())<9, timings
        # Запуск PowerShell под параллельной нагрузкой не входит в сетевой таймаут.
        # Сам SSH выше всё ещё обязан завершиться менее чем за 9 с.
        assert timings[mode]<(18000 if mode=='timeout' else 10000),(mode,timings)
        assert state['serverId']=='blocked.example.invalid\n22255\nworker',state
        if mode in ('ok','negative'):
            assert p.returncode==0 and result['ok'] and state['ok'],(p.stderr,result)
            data=result['result'];assert data==state
            assert data['disk']==dict(totalBytes=102400000,usedBytes=81920000,freeBytes=0 if mode=='negative' else 15360000)
            assert data['memory']==dict(totalBytes=10240000,availableBytes=921600,usedBytes=9318400)
            assert data['load']==dict(one=1.25,five=0.5,fifteen=0.75,cores=4)
            assert data['uptimeSec']==90061.25 and data['updatedUtc']
        else:
            assert p.returncode==1 and not result['ok'] and not state['ok'],(p.stderr,result)
            assert 'disk' not in state and 'SECRET' not in result['reason']
            if mode=='invalid':assert 'ответ состояния сервера' in result['reason']
    # The same request also supports the legacy loopback channel and a pinned direct profile.
    (d/'mode').write_text('ok')
    for address, port, channel_path in [('127.0.0.1', '2222', 'fixture-channel'), ('blocked.example.invalid', '22255', '')]:
        config['transport']['channelFirst']=False
        config['transport']['channelPath']=channel_path
        (root/'config.json').write_text(json.dumps(config)); original=(root/'config.json').read_bytes()
        p=run([PWSH,'-NoProfile','-NonInteractive','-File',wizard,'-Home',root,'-Action','ServerHealth'],
              {**env,'HEALTH_ADDRESS':address,'HEALTH_PORT':port})
        assert p.returncode==0,(p.stdout,p.stderr)
        assert len((d/'calls').read_text().splitlines())==before+1
        before+=1
        assert (root/'config.json').read_bytes()==original
    # Один и тот же файл состояния задаёт эффективные адрес и порт для обеих форм канала.
    config['transport']['channelFirst']=True
    (root/'config.json').write_text(json.dumps(config))
    configured=dict(sshPort=2222,channelSocksPort=2223,syncPort=22001,lanProxyPort=17880,vpnInPort=17881,apiPort=29090,
                    probePortBase=26000,socksPortBase=28000,channelSshAddress='127.0.0.3',serverPort=22255)
    effective={**configured,'sshPort':2232,'channelSshAddress':'127.0.0.4'}
    ports_file=root/'state/transport-ports.json'
    ports_file.write_bytes(json.dumps(dict(schema=1,configured=configured,effective=effective),indent=2).replace('\n','\r\n').encode())
    for first, address, port in [(True,'127.0.0.4','22255'),(False,'127.0.0.1','2232')]:
        config['transport']['channelFirst']=first; config['transport']['channelPath']='fixture-channel'
        (root/'config.json').write_text(json.dumps(config)); original=(root/'config.json').read_bytes()
        p=run([PWSH,'-NoProfile','-NonInteractive','-File',wizard,'-Home',root,'-Action','ServerHealth'],
              {**env,'HEALTH_ADDRESS':address,'HEALTH_PORT':port})
        assert p.returncode==0,(p.stdout,p.stderr)
        assert len((d/'calls').read_text().splitlines())==before+1
        assert (root/'config.json').read_bytes()==original
        before+=1
    ports_file.unlink()
    # A response arriving after a profile replacement keeps the polled server's identity.
    config['transport']['channelFirst']=True
    (root/'config.json').write_text(json.dumps(config))
    saved_profile=profile.read_bytes(); (d/'mode').write_text('switch')
    p=run([PWSH,'-NoProfile','-NonInteractive','-File',wizard,'-Home',root,'-Action','ServerHealth'],env)
    assert p.returncode==0,(p.stdout,p.stderr)
    state=json.loads((root/'state/server-health.json').read_text(encoding='utf-8-sig'))
    assert state['serverId']=='blocked.example.invalid\n22255\nworker',state
    assert json.loads(profile.read_text())['serverAddress']=='replacement.example.invalid'
    assert len((d/'calls').read_text().splitlines())==before+1
    profile.write_bytes(saved_profile)
    # Exercise malformed, missing, duplicate, fractional integer, impossible and oversized counters in one process.
    parser=d/'parser.ps1'; bad=[FIXTURE.replace('cores=4\n',''), FIXTURE+'cores=4\n',
        FIXTURE.replace('diskTotalKb=100000','diskTotalKb=0'),FIXTURE.replace('memoryAvailableKb=900','memoryAvailableKb=10001'),
        FIXTURE.replace('diskFreeKb=15000','diskFreeKb=90000'), FIXTURE.replace('cores=4','cores=1.5'),
        FIXTURE.replace('cores=4','cores=-1'),
        *[FIXTURE.replace(key+'='+value,key+'=-'+value) for key,value in
          [('diskTotalKb','100000'),('diskUsedKb','80000'),('memoryTotalKb','10000'),
           ('memoryAvailableKb','900'),('load1','1.25'),('uptimeSec','90061.25')]],
        FIXTURE.replace('diskFreeKb=15000','diskFreeKb=-0.5'), FIXTURE.replace('load1=1.25','load1=NaN'),
        FIXTURE.replace('load1=1.25','load1=1,25'), FIXTURE.replace('health=1','health=2'),
        FIXTURE.replace('uptimeSec=90061.25','uptimeSec='+('9'*400))]
    inputs=d/'bad.json';inputs.write_text(json.dumps(bad))
    parser.write_text(f"""$ErrorActionPreference='Stop'
. {quote(runtime/'build/Wizard.Common.ps1')}
$n=0
foreach($text in (Get-Content -Raw {quote(inputs)} | ConvertFrom-Json)){{
    $rejected=$false;try{{$null=ConvertFrom-WizardServerHealth $text}}catch{{$rejected=$true}}
    if(-not $rejected){{throw 'invalid health accepted'}};$n++
}}
# The exact command sent from a Windows checkout must lose CRLF at the common boundary.
function Find-InstallProfile($Root){{return {quote(profile)}}}
function Invoke-DiskProcess($Exe,$Argv,$InputText,[int]$TimeoutSeconds){{
    if($Argv[-1].Contains("`r") -or $Argv[-2] -ne '127.0.0.3' -or $TimeoutSeconds -ne 8){{throw 'bad SSH boundary'}}
    return [IO.File]::ReadAllText({quote(d/'output')})
}}
$null=Invoke-WizardReadOnlySsh {quote(root)} ((Get-WizardServerHealthCommand).Replace("`r",'').Replace("`n","`r`n"))
if(@(Get-WizardResources ServerHealth ([pscustomobject]@{{}})).Count -ne 0){{throw 'read-only action took a mutation lock'}}
Write-Output "PASS: $n invalid health cases + CRLF SSH boundary + no mutation locks"
""")
    p=run([PWSH,'-NoProfile','-NonInteractive','-File',parser],env)
    assert p.returncode==0,(p.stdout,p.stderr)
    print(p.stdout.strip())
    print(f'PASS: 10 standalone Wizard ServerHealth fake SSH scenarios (channel-first, legacy channel, effective ports/address, saved SSH), negative Avail clamped to zero, in-flight profile replacement, CRLF metrics/state, one call/run, saved route, read-only; milliseconds {timings}')
