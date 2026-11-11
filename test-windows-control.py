"""Isolated standalone-control checks: no real user state or Windows commands."""
import base64
import hashlib
import json
import os
import pwd
import re
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import server_node_catalog as catalog

ROOT=Path(__file__).resolve().parent
PWSH=Path(pwd.getpwuid(os.getuid()).pw_dir)/'.cache/pwsh-test/pwsh'

class ControlTests(unittest.TestCase):
    def record(self,home):
        label='win-'+'a'*28
        return dict(projectId='control',hostId='host-one',deviceLabel=label,windowsReplica=r'C:\Control Workspace',serverWorkspace=str(home/'work/projects/control'),socketPath=str(home/'.local/state/codex-remote'/(label+'.sock')),allowShell=True)

    def test_no_standard_input_encoding(self):
        for name in ('Start-WindowsControl.ps1','disk/Disk.Common.ps1','Start-CodexWindowsBridge.ps1'):
            with self.subTest(script=name):
                self.assertNotIn('StandardInputEncoding',(ROOT/name).read_text(encoding='utf-8-sig'))

    def test_prepare_utf8_stdin(self):
        with tempfile.TemporaryDirectory() as tmp:
            home=Path(tmp);shim=home/'ssh-shim';capture=home/'stdin.bin'
            shim.write_text('#!/usr/bin/env python3\nimport os, sys\nfrom pathlib import Path\nPath(os.environ["CONTROL_STDIN_CAPTURE"]).write_bytes(sys.stdin.buffer.read())\nprint(\'{"user":"tester","home":"/home/tester"}\')\n')
            shim.chmod(0o700)
            payload='Привет, сервер!\r\nРусский текст: ёжик.\rКонец\n'
            encoded=base64.b64encode(payload.encode('utf-8')).decode('ascii')
            script="""
. './Start-WindowsControl.ps1' -LibraryOnly
# A non-UTF-8 console must not affect bytes written to SSH stdin.
[Console]::InputEncoding=[Text.Encoding]::ASCII
[Console]::OutputEncoding=[Text.Encoding]::ASCII
$c=[pscustomobject]@{sshExecutable=$env:CONTROL_SSH_SHIM;configPath='config';keyPath='key';port=22;knownHostsPath='known';login='tester';serverAddress='example.invalid'}
$payload=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__'))
Invoke-ControlPrepare $c $payload | ConvertTo-Json -Compress
""".replace('__PAYLOAD__',encoded)
            env=dict(os.environ,HOME=tmp,CONTROL_SSH_SHIM=str(shim),CONTROL_STDIN_CAPTURE=str(capture))
            result=json.loads(subprocess.check_output([str(PWSH),'-NoProfile','-Command',script],cwd=ROOT,env=env,timeout=70))
            self.assertEqual(result,dict(user='tester',home='/home/tester'))
            self.assertEqual(capture.read_bytes(),payload.replace('\r\n','\n').replace('\r','\n').encode('utf-8'))

    def test_migration_bridge_live_roundtrip(self):
        # Exercise the actual embedded probe with an isolated public catalog and broker socket.
        import shutil
        import sys
        import types
        code = subprocess.check_output([str(PWSH), '-NoProfile', '-NonInteractive', '-Command',
            ". './build/Migrate.Common.ps1'; Get-MigrationBridgeProbe"], cwd=ROOT).decode('utf-8-sig')
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp); record = self.record(home); record['controlOnly'] = True
            base = home / '.local/share/codex-remote'; base.mkdir(parents=True)
            for name in ('codex-windows-bridge.py', 'server_node_catalog.py'):
                shutil.copyfile(ROOT/name, base/name)
            catalog.register(home/'.local/share/remote-agents-nodes', record, str(home))
            endpoint = Path(record['socketPath']); endpoint.parent.mkdir(parents=True)
            for valid in (True, False):
                with socket.socket(socket.AF_UNIX) as server:
                    server.bind(str(endpoint)); server.listen(1); server.settimeout(5)
                    captured = []
                    def reply():
                        with server.accept()[0] as client:
                            captured.append(json.loads(client.makefile('rb').readline()))
                            status = dict(ok=True, device=record['deviceLabel'], workspace=record['windowsReplica'],
                                control_only=True, project_id='control', host_id='host-one' if valid else 'other-host')
                            client.sendall(json.dumps(status).encode()+b'\n')
                    thread = threading.Thread(target=reply); thread.start()
                    expected = base64.b64encode(json.dumps(dict(hostId='host-one', workspace=record['windowsReplica'])).encode()).decode()
                    bootstrap = "import pwd,types,sys;home_dir=sys.argv[1];pwd.getpwuid=lambda uid:types.SimpleNamespace(pw_dir=home_dir);sys.argv=sys.argv[1:];exec("+repr(code)+")"
                    result = subprocess.run([sys.executable, '-c', bootstrap, str(home), expected], capture_output=True, timeout=10)
                    thread.join(5)
                    self.assertEqual(result.returncode == 0, valid, result.stderr.decode())
                    self.assertEqual(captured[0]['op'], 'status')
                    self.assertEqual(captured[0]['binding']['hostId'], 'host-one')
                    self.assertNotIn('token', captured[0])
                endpoint.unlink()

    def test_catalog(self):
        with tempfile.TemporaryDirectory() as tmp:
            home=Path(tmp); data=self.record(home)
            normal=dict(ok=True,device=data['deviceLabel'],workspace=data['windowsReplica'],sync_guard=dict(required=True,project_id='control',host_id='host-one'),file_mutations_enabled=False)
            control=dict(ok=True,device=data['deviceLabel'],workspace=data['windowsReplica'],control_only=True,project_id='control',host_id='host-one')
            self.assertTrue(catalog.matches(data,normal));self.assertFalse(catalog.matches(data,control))
            data['controlOnly']=True
            self.assertTrue(catalog.matches(data,control));self.assertFalse(catalog.matches(data,normal))
            for key in ('ok','device','workspace','control_only','project_id','host_id'):
                bad=dict(control);bad[key]=False;self.assertFalse(catalog.matches(data,bad),key)
            directory=home/'catalog';catalog.register(directory,data,str(home))
            self.assertTrue(catalog.records(directory,str(home))[0]['controlOnly'])
            data['controlOnly']=False;catalog.register(directory,data,str(home));self.assertNotIn('controlOnly',catalog.records(directory,str(home))[0])

    def test_prepare_nonroot(self):
        self.assertNotEqual(os.getuid(),0,'run these tests as an ordinary user')
        with tempfile.TemporaryDirectory() as tmp:
            home=Path(tmp); bin=home/'.local/bin';bin.mkdir(parents=True)
            (home/'.codex').mkdir()
            for name,config in [('claude','.claude.json'),('codex','.codex/config.toml')]:
                file=bin/name
                file.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$HOME/'+name+'.calls"\nprintf remote-agents-nodes > "$HOME/'+config+'"\n')
                file.chmod(0o700)
            data=self.record(home);data.update(deviceName='TEST-PC',controlOnly=True)
            directory=home/'.local/share/remote-agents-nodes'; other=dict(data,hostId='other-host')
            catalog.register(directory,other,str(home));other_file=directory/'other-host/control.json';before=other_file.read_bytes()
            env=dict(os.environ,HOME=str(home),PATH=str(bin)+':/usr/bin:/bin')
            # Feed CRLF sources through the exact shared launcher normalizer.
            with tempfile.TemporaryDirectory() as stage:
                stage=Path(stage)
                for name in ('codex-windows-bridge.py','codex-bridge-session.py','server_node_catalog.py','server-control.sh'):
                    (stage/name).write_bytes((ROOT/name).read_bytes().replace(b'\n',b'\r\n'))
                (stage/'Start-WindowsControl.ps1').write_bytes((ROOT/'Start-WindowsControl.ps1').read_bytes())
                command=". '"+str(stage/'Start-WindowsControl.ps1')+"' -LibraryOnly; $env:COMPUTERNAME='TEST-PC'; New-ControlPayload ([pscustomobject]@{hostId='host-one'}) '"+data['deviceLabel']+"' '"+data['windowsReplica']+"' ''"
                payload=subprocess.check_output([str(PWSH),'-NoProfile','-Command',command],env=env)
            self.assertNotIn(b'\r',payload)
            for attempt in range(2):
                result=subprocess.run(['bash','-s'],input=payload,env=env,capture_output=True,check=True)
                last=json.loads(result.stdout.splitlines()[-1]);self.assertEqual(last['home'],str(home));self.assertEqual(last['user'],subprocess.check_output(['id','-un'],text=True).strip())
            for name in ('claude','codex'):
                self.assertEqual(len((home/(name+'.calls')).read_text().splitlines()),1)
                self.assertIn('mcp add',(home/(name+'.calls')).read_text())
            for name in ('codex-windows-bridge.py','codex-bridge-session.py','server_node_catalog.py'):
                file=home/'.local/share/codex-remote'/name
                self.assertEqual(file.stat().st_mode & 0o777,0o600);self.assertNotIn(b'\r',file.read_bytes())
            record=json.loads((directory/'host-one/control.json').read_text());catalog.validate(record,str(home));self.assertTrue(record['controlOnly'])
            self.assertEqual(other_file.read_bytes(),before);self.assertFalse((home/'work/projects/control').exists())

    def test_real_session_binding(self):
        with tempfile.TemporaryDirectory() as tmp:
            home=Path(tmp);home.chmod(0o700);path=home/'session.sock'
            tcp=socket.socket();tcp.bind(('localhost',0));tcp.listen()
            binding=dict(projectId='control',hostId='host-one',deviceLabel='win-'+'a'*28,windowsReplica=r'C:\Control Workspace')
            seen=[]
            def respond():
                conn,_=tcp.accept()
                with conn:
                    frame=json.loads(conn.makefile('rb').readline());seen.append(frame);conn.sendall(b'{"ok":true}\n')
            thread=threading.Thread(target=respond,daemon=True);thread.start()
            env=dict(os.environ,HOME=tmp)
            process=subprocess.Popen(['python3',str(ROOT/'codex-bridge-session.py'),'--socket',str(path)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env)
            try:
                config=dict(binding,token='a'*64,port=tcp.getsockname()[1],device=binding['deviceLabel'])
                process.stdin.write(json.dumps(config).encode()+b'\n');process.stdin.flush()
                self.assertEqual(json.loads(process.stdout.readline())['state'],'connected')
                def request(data):
                    with socket.socket(socket.AF_UNIX) as conn:
                        conn.connect(str(path));conn.sendall(json.dumps(data).encode()+b'\n');return json.loads(conn.makefile('rb').readline())
                self.assertEqual(request(dict(op='status',args={})),{'ok':False,'error':'Windows unavailable or invalid request','reason':'binding-mismatch'})
                self.assertTrue(request(dict(op='status',args={},binding=binding))['ok'])
                thread.join(3);self.assertEqual(seen[0]['binding'],binding)
            finally:
                process.stdin.close();process.wait(timeout=5);process.stdout.close();process.stderr.close();tcp.close()

    def test_executor_control_strictmode(self):
        script=r'''
Set-StrictMode -Version Latest
$source=Get-Content './windows-bridge-executor.ps1' -Raw
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
$dispatch=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Dispatch'},$true)
Invoke-Expression $dispatch.Extent.Text
$config=[pscustomobject]@{control_only=$true;project_id='control';host_id='host-one';enforce_target=$true}
$begin=$source.IndexOf('$controlOnly =');$end=$source.IndexOf('$syncState =',$begin)
Invoke-Expression $source.Substring($begin,$end-$begin)
$secret='a'*64;$device='test-device';$root='C:\Control';$allowShell=$true;$processes=@{}
$binding=[pscustomobject]@{projectId='control';hostId='host-one';deviceLabel=$device;windowsReplica=$root}
$request=[pscustomobject]@{token=$secret;op='status';args=@{};binding=$binding}
$status=Dispatch $request
if(!$status.control_only -or $status.project_id -ne 'control' -or $status.host_id -ne 'host-one' -or $status.sync_guard.required){throw 'Invalid control status'}
$denied=$false
try {Dispatch ([pscustomobject]@{token=$secret;op='status';args=@{}})} catch {$denied=$true}
if(!$denied){throw 'Missing binding accepted'}
$binding.hostId='wrong';$denied=$false
try {Dispatch $request} catch {$denied=$true}
if(!$denied){throw 'Wrong binding accepted'}
# Actual new launcher config block must build valid properties on both PS versions.
$launch=Get-Content './Start-CodexWindowsBridge.ps1' -Raw
$start=$launch.IndexOf('    if ($ControlOnly) {');$end=$launch.IndexOf('    $executor.StandardInput.WriteLine',$start)
$ControlOnly=$true;$ProjectId='control';$HostId='host-one';$localConfig='{"enforce_target":false}'
Invoke-Expression $launch.Substring($start,$end-$start)
$c=$localConfig|ConvertFrom-Json
if(!$c.control_only -or !$c.enforce_target -or $c.project_id -ne 'control' -or $c.host_id -ne 'host-one'){throw 'Invalid launcher config'}
'PASS StrictMode: absent sync_guard, status identity, binding required, launcher localConfig'
'''
        with tempfile.TemporaryDirectory() as tmp:
            output=subprocess.check_output([str(PWSH),'-NoProfile','-Command',script],cwd=ROOT,env=dict(os.environ,HOME=tmp),text=True)
            self.assertIn('PASS StrictMode',output)

    def test_powershell_profile(self):
        with tempfile.TemporaryDirectory() as tmp:
            home=Path(tmp);profile=home/'host-one/ssh-transport.json';profile.parent.mkdir()
            profile.write_text(json.dumps(dict(sshExecutable='ssh',serverAddress='example.invalid',login='tester',keyPath='key',knownHostsPath='known',configPath='config',arguments=['-o','ClearAllForwardings=yes','-p','2222','example.invalid'])))
            script=". './Start-WindowsControl.ps1' -LibraryOnly; $c=Read-ControlProfile '"+str(profile)+"'; @{profile=$c;label=(Get-ControlLabel $c.hostId);arguments=@(Get-ControlSshArguments $c)}|ConvertTo-Json -Depth 5 -Compress"
            result=json.loads(subprocess.check_output([str(PWSH),'-NoProfile','-Command',script],cwd=ROOT,env=dict(os.environ,HOME=tmp)))
            self.assertEqual(result['profile']['hostId'],'host-one');self.assertEqual(result['profile']['port'],2222)
            self.assertEqual(result['label'],'win-'+hashlib.sha256(b'control/host-one').hexdigest()[:28]);self.assertNotIn('ClearAllForwardings',json.dumps(result['arguments']))
            self.assertEqual(result['arguments'][-2: ],['tester@example.invalid','bash -s'])

    def test_supervisor_helpers(self):
        with tempfile.TemporaryDirectory() as tmp:
            script=f"""
. './Start-WindowsControl.ps1' -LibraryOnly
$log='{tmp}/control.log';[IO.File]::WriteAllBytes($log,(New-Object byte[] 1048577))
Write-ControlLog $log 'after rotation'
$config='{tmp}/config.json';Save-ControlConfig $config 'agent' '/p/профиль.json';$read=Read-ControlConfig $config
$missing=Read-ControlConfig '{tmp}/none.json'
$first=New-Object Threading.Mutex($false,'control-test-{os.getpid()}')
$held=Test-ControlLock $first
@{{old=(Test-Path ($log+'.old'));text=(Get-Content $log -Raw);user=$read.agentUser;profile=$read.profile;empty=$missing.profile;held=$held}}|ConvertTo-Json
"""
            result=json.loads(subprocess.check_output([str(PWSH),'-NoProfile','-Command',script],cwd=ROOT,env=dict(os.environ,HOME=tmp)))
            self.assertTrue(result['old']);self.assertIn('after rotation',result['text']);self.assertLess(len(result['text']),100)
            self.assertEqual((result['user'],result['profile'],result['empty']),('agent','/p/профиль.json',''));self.assertTrue(result['held'])

    def test_install_copies_all_dependencies(self):
        source=(ROOT/'Start-WindowsControl.ps1').read_text(encoding='utf-8-sig')
        names=re.search(r"foreach\(\$name in @\(([^)]*)\)\)",source).group(1)
        for name in ('Start-WindowsControl.ps1','Start-CodexWindowsBridge.ps1','windows-bridge-executor.ps1','Windows.Paths.ps1','server-control.sh','codex-windows-bridge.py','codex-bridge-session.py','server_node_catalog.py'):
            self.assertIn("'"+name+"'",names);self.assertTrue((ROOT/name).exists(),name)

    def test_bridge_survives_five_failures(self):
        with tempfile.TemporaryDirectory() as tmp:
            home=Path(tmp);bin_dir=home/'bin';bin_dir.mkdir();count=home/'count';log=home/'control.log'
            for name in ('key','known','config'):(home/name).write_text('x')
            shim=bin_dir/'powershell.exe';shim.write_text('#!/bin/sh\nexec "'+str(PWSH)+'" "$@"\n');shim.chmod(0o755)
            ssh=bin_dir/'ssh-fail';ssh.write_text('#!/bin/sh\necho x >> "'+str(count)+'"\necho denied >&2\nexit 255\n');ssh.chmod(0o755)
            stage=home/'stage';stage.mkdir();(stage/'Start-CodexWindowsBridge.ps1').write_bytes((ROOT/'Start-CodexWindowsBridge.ps1').read_bytes())
            (stage/'windows-bridge-executor.ps1').write_text('[void][Console]::In.ReadLine();[Console]::Out.WriteLine(\'{"state":"ready","port":1}\');[Console]::Out.Flush();Start-Sleep 120')
            process=subprocess.Popen([str(PWSH),'-NoProfile','-File',str(stage/'Start-CodexWindowsBridge.ps1'),'-VPSHost','example.invalid','-VPSUser','tester','-IdentityFile',str(home/'key'),'-KnownHostsFile',str(home/'known'),'-SSHConfig',str(home/'config'),'-SSHExecutable',str(ssh),'-Workspace',tmp,'-SocketPath','/tmp/none.sock','-ProjectId','control','-HostId','host-one','-ControlOnly','-RetryForever','-LogFile',str(log)],cwd=ROOT,env=dict(os.environ,HOME=tmp,PATH=str(bin_dir)+os.pathsep+os.environ['PATH']),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            try:
                deadline=time.time()+90
                while time.time()<deadline and process.poll() is None and (not count.exists() or len(count.read_text().split())<6):time.sleep(0.5)
                self.assertIsNone(process.poll(),'bridge must keep retrying')
                self.assertGreaterEqual(len(count.read_text().split()),6)
                self.assertIn('bridge.disconnected',log.read_text())
            finally:
                process.kill();process.wait()

if __name__=='__main__': unittest.main(verbosity=2)
