#!/usr/bin/env python3
"""Real Wizard CLI + fake SSH/server; no owner network or credentials."""
import json, os, shlex, subprocess, tempfile, time
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
PWSH = Path(os.environ.get('PWSH', Path.home()/'.cache/pwsh-test/pwsh'))
def run(args, env, **kw):
    return subprocess.run([str(x) for x in args], env=env, stdin=subprocess.DEVNULL,
                          capture_output=True, text=True, timeout=kw.pop('timeout', 30), **kw)
def quote(x): return "'"+str(x).replace("'", "''")+"'"

with tempfile.TemporaryDirectory(prefix='config-sync-cli-') as tmp:
    d = Path(tmp); root = d/'local/RemoteAgents'; root.mkdir(parents=True)
    remote = d/'server/.config/remoteagents'; remote.mkdir(parents=True)
    catalog = dict(schema=1, entries=[], hops=[], relays=[], cdn=[])
    snapshot = dict(kind='remoteagents-config-sync', schema=1, revision='revision-a', config=dict(
        kind='remoteagents-config', schema=1, server=dict(address='blocked.example.invalid', port=22255,
        login='worker', hostKeys=['ssh-ed25519 AAAATESTPIN'], routes=[dict(kind='direct')]), secrets={}))
    (remote/'config-sync.json').write_text(json.dumps(snapshot).replace('\n', '\r\n')+'\r\n')
    (remote/'transport-catalog.json').write_text(json.dumps(catalog)+'\r\n')
    fake = d/'ssh'
    fake.write_text('''#!/usr/bin/env python3
import json,os,shlex,subprocess,sys,time
from pathlib import Path
d=Path(os.environ['SYNC_FIXTURE'])
with (d/'calls').open('a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
mode=(d/'mode').read_text()
if sys.argv[-2]!='127.0.0.3': time.sleep(40);sys.exit(255)
assert sys.argv[sys.argv.index('-p')+1]=='22255'
assert 'StrictHostKeyChecking=yes' in sys.argv and 'HostKeyAlias=blocked.example.invalid' in sys.argv
if mode=='timeout': time.sleep(40);sys.exit(255)
if mode=='pin': print('Host key verification failed.',file=sys.stderr);sys.exit(255)
if mode=='invalid': print('{"secret":"pw", BROKEN');sys.exit(0)
p=subprocess.run(shlex.split(sys.argv[-1]),env={**os.environ,'HOME':str(d/'server')},capture_output=True)
sys.stdout.buffer.write(p.stdout);sys.stderr.buffer.write(p.stderr);sys.exit(p.returncode)
''')
    fake.chmod(0o700); (d/'mode').write_text('ok')
    profile = d/'profile.json'
    profile.write_text(json.dumps(dict(sshExecutable=str(fake), serverAddress='blocked.example.invalid',
        login='worker', keyPath=str(d/'unused-key'), knownHostsPath=str(d/'known_hosts'), arguments=['-p','22255'])))
    config = dict(schema=1, version=1, transport=dict(profilePath=str(profile), channelFirst=True,
        channelSshAddress='127.0.0.3', sshPort=2222, channelSocksPort=2223),
        bridge=dict(enabled=True), profile=dict(device=dict(name='no-reregistration')))
    (root/'config.json').write_text(json.dumps(config))
    env = {**os.environ, 'LOCALAPPDATA':str(d/'local'), 'SYNC_FIXTURE':str(d)}
    prepare = d/'prepare.ps1'
    prepare.write_text(f"""$ErrorActionPreference='Stop'
. {quote(REPO/'build/Wizard.Common.ps1')}
$data=ConvertFrom-WizardConfigSync (Read-TransportJson {quote(remote/'config-sync.json')})
$data.bootstrap|Add-Member -Force catalog (Read-TransportJson {quote(remote/'transport-catalog.json')})
Write-TransportJson {quote(root/'state/config-settings-version.json')} @{{schema=2;hash=(Get-WizardSettingsHash $data)}}
""")
    p = run([PWSH,'-NoProfile','-NonInteractive','-File',prepare],env)
    assert p.returncode==0,p.stderr
    def sync():
        start=time.monotonic()
        p=run([PWSH,'-NoProfile','-NonInteractive','-File',REPO/'build/Wizard.ps1','-Home',root,'-Action','ConfigSync'],env)
        return p,json.loads(p.stdout.strip().splitlines()[-1]),round((time.monotonic()-start)*1000)
    p, result, fast_ms = sync()
    assert p.returncode==0 and result['ok'] and result['result']['changed'] is False,(p.stderr,result)
    assert fast_ms<20000 and len((d/'calls').read_text().splitlines())==1,fast_ms
    assert not (root/'state/connection-generations').exists(),'no candidate daemon on unchanged snapshot'
    # A metadata change must stay cheap, while the catalog is fetched on every call.
    snapshot['revision']='revision-b'
    (remote/'config-sync.json').write_text(json.dumps(snapshot)+'\r\n')
    p,result,metadata_ms=sync()
    assert p.returncode==0 and not result['result']['changed'] and metadata_ms<20000,result
    # Tray and Windows Scheduler may call at once: never queue a second run.
    holder=d/'hold.ps1';ready=d/'ready';release=d/'release'
    holder.write_text(f"""$ErrorActionPreference='Stop'
. {quote(REPO/'build/Wizard.Common.ps1')}
Invoke-WizardAction {quote(root)} ConfigSync $null {{
    [IO.File]::WriteAllText({quote(ready)},'ready')
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while(-not (Test-Path {quote(release)})){{if($watch.Elapsed.TotalSeconds -gt 20){{throw 'fixture lock timeout'}};Start-Sleep -Milliseconds 50}}
}}
""")
    held=subprocess.Popen([str(PWSH),'-NoProfile','-NonInteractive','-File',str(holder)],env=env,
                          stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try:
        for _ in range(150):
            if ready.exists():break
            assert held.poll() is None,'lock holder failed'
            time.sleep(.05)
        else:raise AssertionError('lock holder did not become ready')
        before=len((d/'calls').read_text().splitlines())
        p,result,duplicate_ms=sync()
        assert p.returncode==1 and 'Сверка конфига уже выполняется' in result['reason'],result
        assert duplicate_ms<5000 and len((d/'calls').read_text().splitlines())==before,duplicate_ms
    finally:
        release.write_text('release');out,err=held.communicate(timeout=8)
        assert held.returncode==0,err
    # Parse errors in a private channel secret must not echo its JSON or password.
    snapshot['config']['vpn']={'bootstrap':{'channel':{'secret':'vpn-channel'}}}
    snapshot['config']['secrets']={'vpn-channel':'{"password":"pw", BROKEN'}
    (remote/'config-sync.json').write_text(json.dumps(snapshot)+'\r\n')
    p,result,elapsed=sync()
    assert p.returncode==1 and 'Повреждён JSON закрытых' in result['reason'],result
    assert 'pw' not in result['reason'] and 'BROKEN' not in result['reason'],result
    del snapshot['config']['vpn'];snapshot['config']['secrets']={}
    (remote/'config-sync.json').write_text(json.dumps(snapshot)+'\r\n')
    # Invalid JSON must never echo even a short secret. All failures go through the real CLI/log path.
    for mode, expected in [('invalid','повреждённый JSON'),('pin','Ключ хоста'),('timeout','Таймаут')]:
        (d/'mode').write_text(mode)
        p,result,elapsed=sync()
        assert p.returncode==1 and not result['ok'] and expected in result['reason'],(p.stderr,result)
        log=(root/'logs/setup.log').read_text()
        assert 'wizard.ConfigSync.failed '+result['reason'] in log and 'pw' not in log and 'BROKEN' not in log,log
        if mode=='timeout': timeout_ms=elapsed;assert elapsed<20000,elapsed
    (d/'mode').write_text('ok');(remote/'config-sync.json').unlink()
    p,result,elapsed=sync()
    assert p.returncode==1 and 'config-sync.json' in result['reason'],result
    assert all(json.loads(line)[-2]=='127.0.0.3' for line in (d/'calls').read_text().splitlines()),'direct SSH was attempted'
    print(f'PASS: Wizard ConfigSync fake SSH/server; unchanged {fast_ms} ms, metadata {metadata_ms} ms, timeout {timeout_ms} ms, duplicate {duplicate_ms} ms; one channel request/run; no daemon, direct SSH or device-name calls; failure reason in JSON + setup.log')
