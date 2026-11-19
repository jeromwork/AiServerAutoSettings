#!/usr/bin/env python3
"""Close idle Happier sessions for default and registered accounts in ~/secrets/happier/accounts."""
import argparse
import fcntl
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
from urllib.parse import urlsplit

def command(happier,env,timeout,*args):
    result=subprocess.run([happier,'session',*args,'--json'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,env=env,timeout=timeout,check=True)
    data=json.loads(result.stdout)
    if not isinstance(data,dict) or data.get('error') or data.get('ok') is False or data.get('success') is False:
        raise ValueError('command error')
    return data

def https_origin(value):
    if not isinstance(value,str): return None
    try:
        url=urlsplit(value)
        if url.scheme=='https' and url.hostname and url.username is None and url.password is None and url.path in ('','/') and not url.query and not url.fragment:
            return 'https://'+url.netloc
    except ValueError:
        pass
    return None

def record(account,sid,title,hours,action):
    log=Path.home()/'.local/state/close-idle-chats.log'
    row=json.dumps(dict(time=time.strftime('%Y-%m-%dT%H:%M:%S%z'),account=account,id=str(sid)[:2000],title=str(title)[:2000],idle_hours=hours,action=action),ensure_ascii=False)+'\n'
    mode='w' if log.exists() and log.stat().st_size+len(row.encode('utf-8'))>256*1024 else 'a'
    with log.open(mode,encoding='utf-8') as out: out.write(row)
    print(row,end='')

def accounts(home):
    clean=dict(os.environ)
    for key in ('HAPPIER_HOME_DIR','HAPPIER_SERVER_URL','HAPPIER_WEBAPP_URL'):
        clean.pop(key,None)
    found=[('default',clean.copy())]
    root=home/'secrets/happier/accounts'
    if root.is_symlink() or not root.is_dir(): return found
    try:
        names=sorted(os.listdir(root))
    except OSError:
        record('-','-','',None,'skip accounts: OSError')
        return found
    node=home/'.local/share/remoteagents-accounts/node'
    for name in names:
        folder=root/name
        if not re.fullmatch('[a-f0-9]{64}',name) or folder.is_symlink() or not folder.is_dir(): continue
        meta=home/'.config/remoteagents/accounts'/(name+'.json')
        unit=home/'.config/systemd/user'/('remoteagents-happier-'+name+'.service')
        if not meta.is_file() and not unit.is_file(): continue
        env=clean.copy();env['HAPPIER_HOME_DIR']=str(folder)
        if not meta.is_symlink() and meta.is_file():
            try:
                data=json.loads(meta.read_text(encoding='utf-8'))
                if isinstance(data,dict):
                    for field,key in (('serverUrl','HAPPIER_SERVER_URL'),('webappUrl','HAPPIER_WEBAPP_URL')):
                        origin=https_origin(data.get(field))
                        if origin is not None: env[key]=origin
            except (OSError,ValueError,UnicodeError):
                pass
        if node.is_dir(): env['PATH']=str(node)+os.pathsep+env.get('PATH',os.defpath)
        found.append((name[:8],env))
    return found

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hours',type=float,default=2)
    parser.add_argument('--dry-run',action='store_true')
    parser.add_argument('--timeout',type=float,default=40)
    parser.add_argument('--budget',type=float,default=600)
    args=parser.parse_args()
    if not math.isfinite(args.hours) or args.hours<0: parser.error('--hours must be finite and nonnegative')
    if not math.isfinite(args.timeout) or args.timeout<=0: parser.error('--timeout must be finite and positive')
    if not math.isfinite(args.budget) or args.budget<0: parser.error('--budget must be finite and nonnegative')
    state=Path.home()/'.local/state';state.mkdir(parents=True,exist_ok=True)
    with (state/'close-idle-chats.lock').open('a') as lock:
        try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: return 0
        binary=Path.home()/'.local/bin/happier'
        happier=str(binary) if binary.exists() else shutil.which('happier') or 'happier'
        deadline=time.monotonic()+args.budget
        def left(): return deadline-time.monotonic()
        account_list=accounts(Path.home())
        failed=False;exhausted=False
        for index,(label,env) in enumerate(account_list):
            try:
                if left()<=0:
                    for remaining,_ in account_list[index:]: record(remaining,'-','',None,'skip: time budget')
                    failed=True;break
                def run(*command_args):
                    return command(happier,env,min(args.timeout,max(left(),0.1)),*command_args)
                try:
                    try:
                        data=run('list','--active')
                    except subprocess.TimeoutExpired:
                        if left()<=0: raise
                        data=run('list','--active')
                    sessions=data['data']['sessions']
                    if not isinstance(sessions,list): raise ValueError('invalid sessions')
                except (OSError,subprocess.SubprocessError,ValueError,KeyError,TypeError) as exc:
                    record(label,'-','',None,'skip list: '+type(exc).__name__);failed=True;continue
                for session in sessions:
                    if left()<=0:
                        for remaining,_ in account_list[index:]: record(remaining,'-','',None,'skip: time budget')
                        failed=True;exhausted=True;break
                    sid=title='';hours=None;stage='session'
                    try:
                        if not isinstance(session,dict): raise ValueError('invalid session')
                        sid=session.get('id','');title=session.get('title','')
                        if not isinstance(sid,str) or not sid: raise ValueError('unknown id')
                        pending=session.get('pendingCount')
                        if type(pending) is not int or pending!=0:
                            record(label,sid,title,hours,'skip: pending or unknown pendingCount');continue
                        stage='history'
                        messages=run('history',sid,'--limit','12','--format','raw')['data']['messages']
                        if not isinstance(messages,list): raise ValueError('invalid messages')
                        if not messages:
                            record(label,sid,title,hours,'skip: no messages');continue
                        dates=[m.get('createdAt') if isinstance(m,dict) else None for m in messages]
                        now=time.time()*1000
                        if any(type(d) not in (int,float) or not math.isfinite(d) or d<=0 or d>now for d in dates):
                            record(label,sid,title,hours,'skip: unknown date');continue
                        hours=(now-max(dates))/3600000
                        if hours<=args.hours:
                            record(label,sid,title,hours,'keep: recent');continue
                        if args.dry_run:
                            record(label,sid,title,hours,'dry-run: would stop');continue
                        stage='stop';run('stop',sid)
                        record(label,sid,title,hours,'stopped')
                    except (OSError,subprocess.SubprocessError,ValueError,KeyError,TypeError,OverflowError) as exc:
                        record(label,sid,title,hours,'skip '+stage+': '+type(exc).__name__)
                if exhausted: break
            except Exception as exc:
                record(label,'-','',None,'skip account: '+type(exc).__name__);failed=True
    return 1 if failed else 0

if __name__=='__main__': raise SystemExit(main())
