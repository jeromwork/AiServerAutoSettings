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
import json, os, sys, time
from pathlib import Path
base=Path(os.environ.get('HAPPIER_HOME_DIR') or Path.home());args=sys.argv[1:]
with (base/'calls').open('a') as out: out.write(json.dumps(args)+'\\n')
(base/'env').write_text(json.dumps({'server':os.environ.get('HAPPIER_SERVER_URL'),'path':os.environ.get('PATH','')}))
print('node warning',file=sys.stderr)
data=json.loads((base/'data.json').read_text())
assert args[0]=='session' and args[-1]=='--json'
if args[1]=='list':
    assert args==['session','list','--active','--json']
    if (base/'list-fail').exists(): sys.exit(1)
    if (base/'list-slow').exists() and not (base/'list-slow.done').exists():
        (base/'list-slow.done').touch();time.sleep(5)
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
        for key in ('HAPPIER_HOME_DIR','HAPPIER_SERVER_URL','HAPPIER_WEBAPP_URL'):
            self.env.pop(key,None)
        self.log=self.home/'.local/state/close-idle-chats.log'
        self.data={};self.accounts={}

    def add_account(self,letter,catalog=True,unit=False):
        aid=letter*64
        folder=self.home/'secrets/happier/accounts'/aid;folder.mkdir(parents=True)
        if catalog:
            meta=self.home/'.config/remoteagents/accounts'/(aid+'.json');meta.parent.mkdir(parents=True,exist_ok=True)
            meta.write_text(json.dumps(dict(schema=1,account=aid,label='t',serverUrl='https://s.example',webappUrl='https://w.example')))
        if unit:
            service=self.home/'.config/systemd/user'/('remoteagents-happier-'+aid+'.service')
            service.parent.mkdir(parents=True,exist_ok=True);service.touch()
        self.accounts[aid]={}
        return folder

    def chat(self,sid,hours=3,account=None,**extra):
        data=self.data if account is None else self.accounts[account]
        data[sid]=dict(messages=[dict(createdAt=int((time.time()-hours*3600)*1000),content=SECRET)],**extra)

    def run_script(self,*args,code=0):
        (self.home/'data.json').write_text(json.dumps(self.data))
        for aid,data in self.accounts.items():
            (self.home/'secrets/happier/accounts'/aid/'data.json').write_text(json.dumps(data))
        result=subprocess.run([sys.executable,str(ROOT/'close-idle-chats.py'),*args],env=self.env,capture_output=True,text=True,timeout=20)
        self.assertEqual(result.returncode,code,result.stderr)
        return result

    def calls(self,action,base=None):
        file=(base or self.home)/'calls'
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

    def test_all_accounts_cleaned(self):
        a=self.add_account('a');b=self.add_account('b',catalog=False,unit=True)
        node=self.home/'.local/share/remoteagents-accounts/node';node.mkdir(parents=True)
        for account,suffix in ((None,'d'),('a'*64,'a'),('b'*64,'b')):
            self.chat('old-'+suffix,account=account);self.chat('recent-'+suffix,1,account=account)
        result=self.run_script()
        for base,suffix in ((self.home,'d'),(a,'a'),(b,'b')):
            self.assertEqual([row[2] for row in self.calls('stop',base)],['old-'+suffix])
        rows=list(map(json.loads,self.log.read_text().splitlines()))
        self.assertEqual({row['id']:row['account'] for row in rows},
                         {prefix+suffix:label for suffix,label in (('d','default'),('a','a'*8),('b','b'*8)) for prefix in ('old-','recent-')})
        self.assertNotIn('a'*64,self.log.read_text()+result.stdout)
        self.assertEqual(json.loads((a/'env').read_text())['server'],'https://s.example')
        self.assertIsNone(json.loads((b/'env').read_text())['server'])
        self.assertEqual(json.loads((a/'env').read_text())['path'],str(node)+os.pathsep+self.env['PATH'])
        self.assertEqual(json.loads((self.home/'env').read_text())['path'],self.env['PATH'])

    def test_account_failure_isolated(self):
        a=self.add_account('a');(a/'list-fail').touch();b=self.add_account('b')
        self.chat('old-d');self.chat('old-b',account='b'*64)
        self.run_script(code=1)
        self.assertEqual([row[2] for row in self.calls('stop')],['old-d'])
        self.assertEqual([row[2] for row in self.calls('stop',b)],['old-b'])
        self.assertEqual(len(self.calls('list',a)),1)
        rows=list(map(json.loads,self.log.read_text().splitlines()))
        self.assertTrue(any(row['account']=='a'*8 and row['action'].startswith('skip list:') for row in rows))

    def test_dry_run_all_accounts(self):
        a=self.add_account('a');self.chat('old-d');self.chat('old-a',account='a'*64)
        self.run_script('--dry-run')
        self.assertEqual(self.calls('stop'),[]);self.assertEqual(self.calls('stop',a),[])
        rows=list(map(json.loads,self.log.read_text().splitlines()))
        self.assertEqual([row['account'] for row in rows if row['action']=='dry-run: would stop'],['default','a'*8])

    def test_list_timeout_retried_once(self):
        a=self.add_account('a');(a/'list-slow').touch();self.chat('old-a',account='a'*64)
        self.run_script('--timeout','1')
        self.assertEqual(len(self.calls('list',a)),2)
        self.assertEqual([row[2] for row in self.calls('stop',a)],['old-a'])

    def test_ignores_non_accounts(self):
        a=self.add_account('a');root=a.parent
        (root/('c'*64)).mkdir();(root/'notanid').mkdir()
        (root/('d'*64)).symlink_to(a,target_is_directory=True)
        (self.home/'.config/remoteagents/accounts'/('d'*64+'.json')).write_text('{}')
        self.chat('old-d');self.chat('old-a',account='a'*64)
        self.run_script()
        self.assertEqual(len(self.calls('list')),1);self.assertEqual(len(self.calls('list',a)),1)
        self.assertFalse((root/('c'*64)/'calls').exists());self.assertFalse((root/'notanid'/'calls').exists())
        rows=list(map(json.loads,self.log.read_text().splitlines()))
        self.assertEqual({row['account'] for row in rows},{'default','a'*8})

    def test_inherited_happier_env_ignored(self):
        elsewhere=self.home/'elsewhere';elsewhere.mkdir()
        self.env.update(HAPPIER_HOME_DIR=str(elsewhere),HAPPIER_SERVER_URL='https://inherited.example',HAPPIER_WEBAPP_URL='https://inherited-web.example')
        self.chat('old');self.run_script()
        self.assertEqual([row[2] for row in self.calls('stop')],['old'])
        self.assertFalse((elsewhere/'calls').exists())
        self.assertIsNone(json.loads((self.home/'env').read_text())['server'])

    def test_budget_zero(self):
        a=self.add_account('a');self.chat('old');self.chat('old-a',account='a'*64)
        self.run_script('--budget','0',code=1)
        self.assertFalse((self.home/'calls').exists());self.assertFalse((a/'calls').exists())
        rows=list(map(json.loads,self.log.read_text().splitlines()))
        self.assertEqual([(row['account'],row['action']) for row in rows],
                         [('default','skip: time budget'),('a'*8,'skip: time budget')])

    def test_bad_arguments(self):
        for flag,value in (('--timeout','0'),('--budget','-1'),('--timeout','nan'),('--timeout','inf'),('--budget','nan'),('--budget','inf')):
            with self.subTest(flag=flag,value=value):
                result=subprocess.run([sys.executable,str(ROOT/'close-idle-chats.py'),flag,value],env=self.env,capture_output=True,text=True,timeout=20)
                self.assertEqual(result.returncode,2,result.stderr)
        self.assertFalse((self.home/'calls').exists())

if __name__=='__main__': unittest.main(verbosity=2)
