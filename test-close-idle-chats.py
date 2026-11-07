"""Isolated idle-chat checks: only a PATH shim and temporary user state."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT=Path(__file__).resolve().parent
SECRET='PRIVATE MESSAGE TEXT MUST NEVER BE LOGGED'
SHIM='''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
home=Path.home();args=sys.argv[1:]
with (home/'calls').open('a') as out: out.write(json.dumps(args)+'\\n')
print('node warning',file=sys.stderr)
data=json.loads((home/'data.json').read_text())
assert args[0]=='session' and args[-1]=='--json'
if args[1]=='list':
    assert args==['session','list','--active','--json']
    result={'data':{'sessions':[dict(id=k,title='Чат '+k,pendingCount=v.get('pending',0)) for k,v in data.items()]}}
else:
    item=data[args[2]]
    if args[1]=='history':
        assert args[3:]==['--limit','12','--format','raw','--json']
        if item.get('bad'): print('broken JSON');sys.exit(0)
        if item.get('fail'): sys.exit(1)
        result={'data':{'messages':item['messages']}}
    else:
        assert args[1]=='stop' and args[3:]==['--json']
        result={'ok':False} if item.get('stop_error') else {'ok':True}
print(json.dumps(result))
'''

class IdleTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.home=Path(self.tmp.name);bin_dir=self.home/'bin';bin_dir.mkdir()
        shim=bin_dir/'happier';shim.write_text(SHIM);shim.chmod(0o700)
        self.env=dict(os.environ,HOME=str(self.home),PATH=str(bin_dir)+os.pathsep+os.defpath)
        self.log=self.home/'.local/state/close-idle-chats.log'
        self.data={}

    def chat(self,sid,hours=3,**extra):
        self.data[sid]=dict(messages=[dict(createdAt=int((time.time()-hours*3600)*1000),content=SECRET)],**extra)

    def run_script(self,*args):
        (self.home/'data.json').write_text(json.dumps(self.data))
        result=subprocess.run([sys.executable,str(ROOT/'close-idle-chats.py'),*args],env=self.env,capture_output=True,text=True,timeout=5)
        self.assertEqual(result.returncode,0,result.stderr)
        return result

    def calls(self,action):
        file=self.home/'calls'
        return [row for row in map(json.loads,file.read_text().splitlines()) if row[1]==action] if file.exists() else []

    def test_sessions_and_failure_isolation(self):
        self.chat('bad-json',bad=True);self.chat('old');self.chat('recent',1)
        self.data['recent']['messages'].append(dict(createdAt=int((time.time()-5*3600)*1000)))
        self.data['empty']=dict(messages=[]);self.chat('pending',pending=1)
        self.data['unknown']=dict(messages=[dict(content=SECRET)])
        self.chat('failed-history',fail=True);self.chat('failed-stop',stop_error=True);self.chat('after-errors')
        result=self.run_script()
        self.assertEqual([row[2] for row in self.calls('stop')],['old','failed-stop','after-errors'])
        rows={row['id']:row for row in map(json.loads,self.log.read_text().splitlines())}
        for sid,reason in [('bad-json','JSONDecodeError'),('empty','no messages'),('pending','pending'),('unknown','unknown date'),('failed-history','CalledProcessError'),('failed-stop','skip stop')]:
            with self.subTest(session=sid): self.assertIn(reason,rows[sid]['action'])
        self.assertEqual(rows['recent']['action'],'keep: recent')
        self.assertAlmostEqual(rows['old']['idle_hours'],3,places=2)
        self.assertEqual(rows['old']['title'],'Чат old');self.assertTrue(rows['old']['time'])
        self.assertNotIn(SECRET,self.log.read_text()+result.stdout+result.stderr)
        self.assertNotIn('node warning',result.stdout+result.stderr)

    def test_dry_run(self):
        self.chat('old');result=self.run_script('--dry-run')
        self.assertEqual(self.calls('stop'),[])
        self.assertIn('dry-run: would stop',result.stdout);self.assertIn('dry-run: would stop',self.log.read_text())

    def test_hours(self):
        self.chat('three',3);self.chat('five',5);self.run_script('--hours','4')
        self.assertEqual([row[2] for row in self.calls('stop')],['five'])

    def test_lock_and_log_limit(self):
        self.log.parent.mkdir(parents=True);self.log.write_bytes(b'x'*(256*1024))
        with (self.log.parent/'close-idle-chats.lock').open('a') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            result=self.run_script();self.assertEqual(result.stdout+result.stderr,'');self.assertEqual(self.calls('list'),[])
        self.chat('old');self.run_script()
        self.assertLessEqual(self.log.stat().st_size,256*1024)
        self.assertEqual(json.loads(self.log.read_text())['action'],'stopped')

if __name__=='__main__': unittest.main(verbosity=2)
