#!/usr/bin/env python3
"""Disposable rootless sshd + real sing-box. No host services/keys are changed.
Server inventory's systemctl is replaced inside the isolated HOME only.
Use --repo for before/after runs; --baseline accommodates the old preflight-only setup.
"""
import argparse
import json
import os
from pathlib import Path
import pwd
import shutil
import socket
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[1])
parser.add_argument('--baseline', action='store_true')
parser.add_argument('--without-disk', action='store_true')
args = parser.parse_args()
PWSH = Path.home()/'.cache/pwsh-test/pwsh'

def run(cmd, **kw):
    try:
        p = subprocess.run([str(x) for x in cmd], capture_output=True, timeout=kw.pop('timeout', 45), **kw)
    except subprocess.TimeoutExpired as exc:
        # This stand has only disposable keys/data. Preserve phase markers before
        # TemporaryDirectory removes the fixture; never relax the timeout.
        print('Loopback fixture timeout; stdout: ' + (exc.stdout or b'').decode(errors='replace')[-2000:], flush=True)
        print('Loopback fixture phases: ' + (exc.stderr or b'').decode(errors='replace')[-4000:], flush=True)
        raise
    assert p.returncode == 0, p.stdout.decode(errors='replace') + p.stderr.decode(errors='replace')
    return p.stdout.decode()

def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]

def psq(x):
    return "'"+str(x).replace("'", "''")+"'"

with tempfile.TemporaryDirectory(prefix='config-c-loopback-') as tmp:
    d = Path(tmp); home = d/'server-home'; home.mkdir()
    rendezvous = d/'rendezvous'; rendezvous.mkdir()
    repo = args.repo
    if args.baseline:
        repo = d/'baseline-bundle'; repo.mkdir()
        for directory in ('build', 'transport', 'disk', 'accounts'):
            shutil.copytree(args.repo/directory, repo/directory)
        for file in ('codex-windows-bridge.py', 'codex-bridge-session.py', 'server_node_catalog.py'):
            shutil.copy2(args.repo/file, repo/file)
    user = pwd.getpwuid(os.getuid()).pw_name
    remote_port = port()
    for key in ('host', 'client'):
        run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', d/key])
    (d/'authorized_keys').write_bytes((d/'client.pub').read_bytes())
    known = '[127.0.0.1]:'+str(remote_port)+' '+' '.join((d/'host.pub').read_text().split()[:2])+'\n'
    # HostKeyAlias is address-only for probes through the local transport.
    known += '127.0.0.1 '+' '.join((d/'host.pub').read_text().split()[:2])+'\n'
    (d/'known_hosts').write_text(known)
    bindir = home/'.local/bin'; bindir.mkdir(parents=True)
    (bindir/'systemctl').write_text('#!/bin/sh\nexit 0\n'); (bindir/'systemctl').chmod(0o700)
    if not args.without_disk:
        disk = home/'.local/share/remote-disk'; disk.mkdir(parents=True)
        (disk/'ports.json').write_text('{"listen":23456}')
    conf = d/'sshd.conf'
    conf.write_text(f'''ListenAddress 127.0.0.1
Port {remote_port}
HostKey {d/'host'}
PidFile {d/'sshd.pid'}
AuthorizedKeysFile {d/'authorized_keys'}
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers {user}
AllowTcpForwarding yes
PermitTTY no
SetEnv REMOTE_DISK_CHANNEL_SOURCE={home}/no-channel HOME={home} PATH={bindir}:/usr/bin:/bin
LogLevel VERBOSE
''')
    logfile = (d/'sshd.log').open('w')
    server = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(conf)], stdout=logfile, stderr=logfile)
    daemon = None
    root = d/'local/RemoteAgents'; root.mkdir(parents=True)
    try:
        for _ in range(100):
            try:
                with socket.create_connection(('127.0.0.1', remote_port), .1): break
            except OSError:
                assert server.poll() is None, (d/'sshd.log').read_text()
                time.sleep(.03)
        (d/'ssh.conf').write_text(f'Host *\n Port {remote_port}\n')
        profile = dict(sshExecutable=shutil.which('ssh'), serverAddress='127.0.0.1', login=user,
                       keyPath=str(d/'client'), knownHostsPath=str(d/'known_hosts'), configPath=str(d/'ssh.conf'))
        profile['arguments'] = ['-F', str(d/'ssh.conf'), '-p', str(remote_port), '-l', user, '-i', str(d/'client'), '-o',
                                'IdentitiesOnly=yes', '-o', 'UserKnownHostsFile='+str(d/'known_hosts'), '-o', 'GlobalKnownHostsFile=none', '-T', '127.0.0.1']
        (d/'profile.json').write_text(json.dumps(profile))
        t = dict(profilePath=str(d/'profile.json'), singBoxPath=shutil.which('sing-box'), bindPhysical=False,
                 metered='false', probeTimeoutSec=8, stallSeconds=3, sshPort=port(), syncPort=port(), apiPort=port())
        (root/'config.json').write_text(json.dumps(dict(schema=1, version=1, transport=t, components={})))
        # Baseline hardcodes the remote SSH service to :22; adapt only this fixture
        # port so both revisions can use the same unprivileged, isolated sshd.
        if args.baseline:
            wizard_server = repo/'build/Wizard.Server.ps1'
            wizard_server.write_text(wizard_server.read_text(encoding='utf-8-sig').replace('test -r /etc/sing-box/config.json', 'test -r "${REMOTE_DISK_CHANNEL_SOURCE:-/etc/sing-box/config.json}"'))
            setup = repo/'build/Setup.Common.ps1'
            setup.write_text(setup.read_text(encoding='utf-8-sig').replace('34000','14000').replace('36000','16000'))
            common = repo/'transport/Transport.Common.ps1'
            text = common.read_text(encoding='utf-8-sig')
            text = text.replace("@('ssh',[int]$o.sshPort,22)", f"@('ssh',[int]$o.sshPort,{remote_port})")
            text = text.replace('override_port=22};$rules+=', f'override_port={remote_port}'+'};$rules+=')
            common.write_text('\ufeff'+text)
        script = d/'run.ps1'
        body = r"""
$ErrorActionPreference='Stop'
. (Join-Path $Repo 'build/Wizard.Common.ps1')
$env:REMOTEAGENTS_WIZARD_SESSION=$(if($Baseline){'0'}else{'1'})
$script:WizardProgressFile=Join-Path $Root 'progress.jsonl'
$watch=[Diagnostics.Stopwatch]::StartNew()
if(-not $Baseline){[void](Invoke-WizardSsh $Root 'true')}
$server=Invoke-WizardStep $Root $Repo 'Server' ([pscustomobject]@{address='127.0.0.1';login=$Login;installMissing=$false})
if(-not $server.ssh){throw 'server not authenticated'}
$serverMs=$watch.ElapsedMilliseconds
$catalog=[pscustomobject]@{schema=1;entries=@();hops=@();relays=@();cdn=@()}
$result=Invoke-WizardStep $Root $Repo 'Connection' ([pscustomobject]@{catalog=$catalog})
# Baseline returns a temporary proof; start its working daemon too for a fair final proof.
if($Baseline){
 $child=Start-TransportProcess (Get-TransportPowerShell) @('-NoProfile','-NonInteractive','-File',(Join-Path $Repo 'transport/Transport.Daemon.ps1'),'-Home',$Root,'-ParentPid',[string]$PID)
 try{
  Wait-TransportReady $Root 30
  if(-not (Test-LocalSsh $Root ((Read-TransportSettings $Root).Options.sshPort))){throw 'working proof failed'}
  $workingMs=$watch.ElapsedMilliseconds
 }finally{[IO.File]::WriteAllText((Join-Path $Root 'stop'),'stop');[void]$child.Process.WaitForExit(5000);Stop-TransportProcess $child}
}else{
 $workingMs=$connectionMs
 if(-not (Test-WizardNetworkProof $Root ([DateTime]::UtcNow.AddSeconds(-30)))){throw 'working proof failed'}
 # Exercise helper caching and multi-command multiplexing on the same real SSH session.
 Send-WizardHelpers $Root $Repo
 $peer=Invoke-WizardSsh $Root 'printf %s "$SSH_CONNECTION"'
 $first=Invoke-WizardSsh $Root 'stat -c %Y "$HOME/.local/share/remoteagents-wizard/server-wizard.sh"'
 Start-Sleep -Milliseconds 1100
 Send-WizardHelpers $Root $Repo
 $second=Invoke-WizardSsh $Root 'stat -c %Y "$HOME/.local/share/remoteagents-wizard/server-wizard.sh"'
 if($first -cne $second){throw 'unchanged helper rewritten'}
 $peer2=Invoke-WizardSsh $Root 'printf %s "$SSH_CONNECTION"'
 if($peer -cne $peer2){throw 'control session changed'}
 $remoteCode=@'
import time,os,json,sys
from pathlib import Path
ident,directory=sys.argv[1:]
directory=Path(directory)
other=directory/('ready-'+('b' if ident=='a' else 'a'))
(directory/('ready-'+ident)).touch()
deadline=time.monotonic()+20
while not other.exists() and time.monotonic()<deadline:
 time.sleep(.02)
print(json.dumps(dict(id=ident,met=other.exists(),ssh=os.environ['SSH_CONNECTION'])))
'@
 $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteCode))
 $children=@()
 try{
  foreach($id in @('a','b')){
   $remote='python3 -c ''import base64;exec(base64.b64decode("'+$encoded+'"))'' '+$id+' '+(Quote-Transport $Rendezvous)
   $childCode='. '+("'"+(Join-Path $Repo 'build/Wizard.Common.ps1').Replace("'","''")+"'")+'; Invoke-WizardSsh '+("'"+$Root.Replace("'","''")+"'")+' '+("'"+$remote.Replace("'","''")+"'")
   $si=New-Object Diagnostics.ProcessStartInfo;$si.FileName=Get-TransportPowerShell
   $si.Arguments=((@('-NoProfile','-NonInteractive','-Command',$childCode)|ForEach-Object {Quote-Transport $_}) -join ' ')
   $si.UseShellExecute=$false;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
   $p=New-Object Diagnostics.Process;$p.StartInfo=$si;[void]$p.Start()
   $children+=@{p=$p;out=$p.StandardOutput.ReadToEndAsync();err=$p.StandardError.ReadToEndAsync()}
  }
  $rows=@()
  foreach($c in $children){if(-not $c.p.WaitForExit(35000) -or $c.p.ExitCode -ne 0){throw ('shared control child failed '+$c.err.GetAwaiter().GetResult())};$rows+=ConvertFrom-Json $c.out.GetAwaiter().GetResult()}
  if($rows.Count -ne 2 -or $rows[0].id -cne 'a' -or $rows[1].id -cne 'b' -or $rows[0].met -ne $true -or $rows[1].met -ne $true){
   $ready=@(Get-ChildItem -LiteralPath $Rendezvous -Filter 'ready-*'|Sort-Object Name|ForEach-Object {$_.Name})
   throw ('remote commands were serialized; ready: '+($ready -join ', ')+'; rows: '+(ConvertTo-Json -InputObject $rows -Compress))
  }
  if($rows[0].ssh -cne $peer -or $rows[1].ssh -cne $peer){throw 'actions did not share one authenticated SSH connection'}
 }finally{foreach($c in $children){if(-not $c.p.HasExited){$c.p.Kill()};$c.p.Dispose()}}
 [void](Invoke-WizardSsh $Root 'mkdir -p "$HOME/.local/share/remote-disk"; cat > "$HOME/.local/share/remote-disk/ports.json"' '{"listen":23456}')
 Set-WizardDiskChannel $Root
 $config=Read-TransportJson (Join-Path $Root 'config.json')
 if(@((Read-TransportJson $config.transport.channelPath).inbounds|Where-Object {$_.tag -eq 'sync'}).Count -ne 1){throw 'late disk inbound missing'}
 $session=@(Get-ChildItem -Path (Join-Path $Root 'state/wizard-control/*/ready.json'))[0].DirectoryName
 Write-DiskUtf8 (Join-Path $session 'stop') 'stop'
 $deadline=[Diagnostics.Stopwatch]::StartNew()
 while(Test-Path (Join-Path $session 'ready.json')){if($deadline.Elapsed.TotalSeconds -gt 10){throw 'control stop timeout'};Start-Sleep -Milliseconds 30}
 # ready.json disappears before the old host finishes its queue cleanup.
 # Its serving lock covers that entire cleanup, so the orphan belongs to the new host.
 Invoke-WizardResourceLock $Root ('control-serve-'+(Split-Path $session -Leaf)) {} -TimeoutMs 20000
 Remove-Item -LiteralPath (Join-Path $session 'stop') -Force
 $orphan=[pscustomobject]@{id=('a'*32);timeout=1;command=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('touch "$HOME/orphan-replayed"'));input=''}
 Write-WizardSessionMessage (Join-Path $session (('a'*32)+'.request.json')) $orphan
 $clean=Invoke-WizardSsh $Root 'if [ -e "$HOME/orphan-replayed" ]; then echo replayed; else echo clean; fi'
 if($clean.Trim() -cne 'clean'){throw 'an orphan modifying request was replayed after controller restart'}


}
@{serverMs=$serverMs;connectionMs=$watch.ElapsedMilliseconds;workingMs=$workingMs;ok=$true}|ConvertTo-Json -Compress
"""
        for label, needle in [('warm SSH', 'if(-not $Baseline){[void](Invoke-WizardSsh'),
                              ('Server', '$server=Invoke-WizardStep'), ('Connection', '$result=Invoke-WizardStep'),
                              ('helpers', ' Send-WizardHelpers $Root $Repo'), ('children', ' $children=@()'),
                              ('late disk', ' Set-WizardDiskChannel $Root'), ('control stop', ' $session=@(Get-ChildItem'),
                              ('orphan', ' $clean=Invoke-WizardSsh')]:
            body = body.replace(needle, "[Console]::Error.WriteLine('loopback: " + label + "');\n" + needle)
        header = f"param([string]$Repo={psq(repo)},[string]$Root={psq(root)},[string]$Login={psq(user)},[string]$Rendezvous={psq(rendezvous)},[bool]$Baseline=${str(args.baseline).lower()})\n"
        # Record total immediately after Connection, excluding helper-cache assertions.
        body = body.replace("# Baseline returns", "$connectionMs=$watch.ElapsedMilliseconds\n# Baseline returns")
        body = body.replace('connectionMs=$watch.ElapsedMilliseconds;', 'connectionMs=$connectionMs;')
        script.write_bytes(('\ufeff'+header+body).replace('\n','\r\n').encode())
        env = dict(os.environ, LOCALAPPDATA=str(d/'local'), REMOTEAGENTS_CONTROL_IDLE_SECONDS='30')
        output = run([PWSH, '-NoProfile', '-NonInteractive', '-File', script], env=env, stdin=subprocess.DEVNULL, timeout=110)
        result = json.loads(output.strip())
        print(json.dumps(dict(mode='before' if args.baseline else 'after', withoutDisk=args.without_disk, **result)))
        if not args.baseline:
            lines = (d/'sshd.log').read_text()
            assert len(list((root/'state/wizard-control').glob('*/ready.json'))) == 1, lines
            print('PASS: one SSH session shared across processes; remote commands overlap; helpers unchanged; late disk inbound reload/proof; orphan request discarded')
    finally:
        (root/'stop').write_text('stop')
        for session in (root/'state/wizard-control').glob('*') if (root/'state/wizard-control').exists() else []:
            (session/'stop').write_text('stop')
        deadline = time.monotonic()+6
        while time.monotonic()<deadline:
            if not list((root/'state/wizard-control').glob('*/ready.json')):
                time.sleep(1)
                break
            time.sleep(.1)
        server.terminate(); server.wait(timeout=5); logfile.close()
