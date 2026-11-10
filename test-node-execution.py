"""Real PS5.1 executors, synthetic barriers; no SSH, agents or user source."""
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.name=='nt','Windows PS5.1 executor')
class TaskExecutionTests(unittest.TestCase):
    def test_same_task_background_commands_conflict_cleanup_and_exact_binding(self):
        with tempfile.TemporaryDirectory(prefix='ra-node-execution-') as temporary:
            root=Path(temporary);processes=[]
            guard=root/'fixture-guard.ps1'
            guard.write_text("$r=[Console]::ReadLine()|ConvertFrom-Json;@{ready=$true;fresh=$true;requestId=$r.requestId;projectId=$r.projectId;hostId=$r.hostId;replicaPath=$r.replicaPath;snapshotId=[guid]::NewGuid().ToString('N')}|ConvertTo-Json -Compress",encoding='utf-8-sig')
            def launch(project):
                replica=root/project;replica.mkdir()
                token=secrets.token_hex(32)
                proc=subprocess.Popen(['powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',str(Path(__file__).with_name('windows-bridge-executor.ps1'))],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
                processes.append(proc)
                binding={'projectId':project,'hostId':'home','deviceLabel':'fixture-'+project,'windowsReplica':str(replica)}
                proc.stdin.write(json.dumps({'token':token,'workspace':str(replica),'device':binding['deviceLabel'],'allow_shell':True,'parent_pid':os.getpid(),'server_owned':True,'enforce_target':True,'sync_guard':{'path':str(guard),'data_dir':str(root),'project_id':project,'host_id':'home'}})+'\n');proc.stdin.flush()
                ready=proc.stdout.readline()
                self.assertTrue(ready,proc.stderr.read() if proc.poll() is not None else 'Executor startup')
                return {'process':proc,'token':token,'binding':binding,'port':json.loads(ready)['port']}
            def call(node,op,args=None,binding=True):
                payload={'token':node['token'],'op':op,'args':args or {}}
                if binding is True:payload['binding']=node['binding']
                elif binding:payload['binding']=binding
                with socket.create_connection(('127.0.0.1',node['port']),timeout=5) as conn:
                    conn.settimeout(45);conn.sendall(json.dumps(payload).encode()+b'\n')
                    return json.loads(conn.makefile('rb').readline(262145))
            try:
                a=launch('p-one');b=launch('p-two')
                self.assertFalse(call(a,'status',binding=False)['ok'])
                self.assertFalse(call(a,'status',binding=dict(a['binding'],hostId='wrong'))['ok'])
                self.assertTrue(call(a,'status')['ok'])
                self.assertFalse(call(a,'command',{'command':'Write-Output forbidden'})['ok'])
                background=call(a,'process_start',{'command':'Start-Sleep -Seconds 30','taskId':'emulator-task','exclusive':True})
                self.assertTrue(background['ok'],background)
                companion=call(a,'command',{'command':"Write-Output 'companion-build'",'taskId':'emulator-task'})
                self.assertTrue(companion['ok'],companion);self.assertIn('companion-build',companion['output'])
                denied=call(b,'command',{'command':'Write-Output forbidden','taskId':'other-task'})
                self.assertFalse(denied['ok']);self.assertIn('busy',denied['error'])
                self.assertFalse(call(a,'process_stop',{'id':background['id'],'taskId':'other-task'})['ok'])
                self.assertTrue(call(a,'process_stop',{'id':background['id'],'taskId':'emulator-task'})['ok'])
                self.assertTrue(call(b,'command',{'command':'Write-Output released','taskId':'other-task'})['ok'])
                finished=call(a,'process_start',{'command':'Start-Sleep -Milliseconds 100','taskId':'short-task'})
                self.assertTrue(finished['ok'])
                import ctypes
                kernel=ctypes.windll.kernel32
                kernel.OpenProcess.restype=ctypes.c_void_p
                handle=kernel.OpenProcess(0x100000,False,finished['pid'])
                if handle:
                    try:self.assertEqual(kernel.WaitForSingleObject(ctypes.c_void_p(handle),10000),0)
                    finally:kernel.CloseHandle(ctypes.c_void_p(handle))
                # Another executor can reclaim a completed lease even before poll.
                reclaimed=call(b,'command',{'command':'Write-Output reclaimed','taskId':'next-task'})
                self.assertTrue(reclaimed['ok'],reclaimed)
                self.assertFalse(call(a,'process_poll',{'id':finished['id'],'taskId':'short-task'})['running'])
            finally:
                for node in [n for n in (locals().get('a'),locals().get('b')) if n]:
                    try:call(node,'shutdown')
                    except Exception:pass
                for proc in processes:
                    try:proc.wait(timeout=8)
                    except subprocess.TimeoutExpired:proc.kill();proc.wait(timeout=5)
                    proc.stdin.close();proc.stdout.close();proc.stderr.close()


if __name__=='__main__':unittest.main()
