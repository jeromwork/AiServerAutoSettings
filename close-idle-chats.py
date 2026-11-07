#!/usr/bin/env python3
"""Close idle Happier sessions, keeping uncertain sessions open."""
import argparse
import fcntl
import json
import math
from pathlib import Path
import subprocess
import time

def command(happier,*args):
    result=subprocess.run([happier,'session',*args,'--json'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,timeout=40,check=True)
    data=json.loads(result.stdout)
    if not isinstance(data,dict) or data.get('error') or data.get('ok') is False or data.get('success') is False:
        raise ValueError('command error')
    return data

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hours',type=float,default=2)
    parser.add_argument('--dry-run',action='store_true')
    args=parser.parse_args()
    if not math.isfinite(args.hours) or args.hours<0: parser.error('--hours must be finite and nonnegative')
    state=Path.home()/'.local/state';state.mkdir(parents=True,exist_ok=True)
    with (state/'close-idle-chats.lock').open('a') as lock:
        try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: return 0
        log=state/'close-idle-chats.log'
        def record(sid,title,hours,action):
            row=json.dumps(dict(time=time.strftime('%Y-%m-%dT%H:%M:%S%z'),id=str(sid)[:2000],title=str(title)[:2000],idle_hours=hours,action=action),ensure_ascii=False)+'\n'
            mode='w' if log.exists() and log.stat().st_size+len(row.encode('utf-8'))>256*1024 else 'a'
            with log.open(mode,encoding='utf-8') as out: out.write(row)
            print(row,end='')
        binary=Path.home()/'.local/bin/happier'
        happier=str(binary) if binary.exists() else 'happier'
        try:
            sessions=command(happier,'list','--active')['data']['sessions']
            if not isinstance(sessions,list): raise ValueError('invalid sessions')
        except (OSError,subprocess.SubprocessError,ValueError,KeyError,TypeError) as exc:
            record('-','',None,'skip list: '+type(exc).__name__);return 1
        for session in sessions:
            sid=title='';hours=None;stage='session'
            try:
                if not isinstance(session,dict): raise ValueError('invalid session')
                sid=session.get('id','');title=session.get('title','')
                if not isinstance(sid,str) or not sid: raise ValueError('unknown id')
                pending=session.get('pendingCount')
                if type(pending) is not int or pending!=0:
                    record(sid,title,hours,'skip: pending or unknown pendingCount');continue
                stage='history'
                messages=command(happier,'history',sid,'--limit','12','--format','raw')['data']['messages']
                if not isinstance(messages,list): raise ValueError('invalid messages')
                if not messages:
                    record(sid,title,hours,'skip: no messages');continue
                dates=[m.get('createdAt') if isinstance(m,dict) else None for m in messages]
                now=time.time()*1000
                if any(type(d) not in (int,float) or not math.isfinite(d) or d<=0 or d>now for d in dates):
                    record(sid,title,hours,'skip: unknown date');continue
                hours=(now-max(dates))/3600000
                if hours<=args.hours:
                    record(sid,title,hours,'keep: recent');continue
                if args.dry_run:
                    record(sid,title,hours,'dry-run: would stop');continue
                stage='stop';command(happier,'stop',sid)
                record(sid,title,hours,'stopped')
            except (OSError,subprocess.SubprocessError,ValueError,KeyError,TypeError,OverflowError) as exc:
                record(sid,title,hours,'skip '+stage+': '+type(exc).__name__)
    return 0

if __name__=='__main__': raise SystemExit(main())
