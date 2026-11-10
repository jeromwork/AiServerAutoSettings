#!/usr/bin/env python3
"""User-owned public transport catalog. No machine paths or credentials cross machines."""
import json, os, sys, tempfile, fcntl
from pathlib import Path
GROUPS = ('entries', 'hops', 'relays', 'cdn')
FIELDS = {'entries': {'name','ssh','enabled','kinds'}, 'hops': {'name','ssh','enabled','hostKey'},
          'relays': {'name','host','port','enabled'}, 'cdn': {'name','domain','entry','path','enabled'}}
def validate(data):
    import re
    if not isinstance(data,dict) or data.get('schema') != 1 or set(data)-{'schema',*GROUPS}: raise ValueError('schema')
    names=set()
    for group in GROUPS:
        rows=data.get(group,[])
        if not isinstance(rows,list) or len(rows)>128: raise ValueError('rows')
        for row in rows:
            if not isinstance(row,dict) or set(row)-FIELDS[group]: raise ValueError('private or unknown field')
            name=row.get('name','')
            if not isinstance(name,str) or not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}',name) or name.lower() in names: raise ValueError('name')
            names.add(name.lower())
            if 'enabled' in row and not isinstance(row['enabled'],bool): raise ValueError('enabled')
            for key,value in row.items():
                if isinstance(value,str) and (len(value)>512 or any(ord(c)<32 for c in value) or '@' in value and '://' in value): raise ValueError('text')
            if group in ('entries','hops') and (not isinstance(row.get('ssh'),str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}',row['ssh'])): raise ValueError('ssh alias')
            if group=='relays' and (not isinstance(row.get('host'),str) or not re.fullmatch(r'[A-Za-z0-9_.:-]+',row['host']) or type(row.get('port')) is not int or not 1<=row['port']<=65535): raise ValueError('relay')
            if group=='cdn' and (not isinstance(row.get('domain'),str) or not re.fullmatch(r'[A-Za-z0-9.-]+',row['domain']) or not isinstance(row.get('entry'),str)): raise ValueError('cdn')
            if 'hostKey' in row and (not isinstance(row['hostKey'],list) or any(not isinstance(x,str) or not re.fullmatch(r'(ssh-|ecdsa-)[A-Za-z0-9@._+-]+ [A-Za-z0-9+/=]+',x) for x in row['hostKey'])): raise ValueError('hostKey')
            if 'kinds' in row and (not isinstance(row['kinds'],list) or any(x not in ('hy2','hy2obfs','tuic','trojan','reality','shadowtls','ws-direct','ws-cdn') for x in row['kinds'])): raise ValueError('kinds')
    for row in data.get('cdn',[]):
        if row['entry'] not in [x['name'] for x in data.get('entries',[])]: raise ValueError('cdn entry')
    return {'schema':1,**{g:data.get(g,[]) for g in GROUPS}}
def main():
    directory=Path.home()/'.config/remoteagents'
    for p in (directory,*directory.parents):
        if p.is_symlink(): raise ValueError('symlink')
    directory.mkdir(parents=True,exist_ok=True,mode=0o700)
    file=directory/'transport-catalog.json'
    lock=directory/'transport-catalog.lock'
    if file.is_symlink() or lock.is_symlink(): raise ValueError('symlink')
    with lock.open('a') as stream:
        fcntl.flock(stream,fcntl.LOCK_EX)
        action=sys.argv[1] if len(sys.argv)>1 else 'get'
        current=validate(json.loads(file.read_text(encoding='utf-8-sig').replace('\r',''))) if file.exists() else validate({'schema':1})
        if action=='put':
            request=json.loads(sys.stdin.read(262145).replace('\r',''))
            # Compare-and-swap prevents overwriting another computer's edits.
            if request.get('expected')!=current: raise ValueError('catalog changed; refresh')
            current=validate(request['catalog'])
        elif action!='get': raise ValueError('action')
        if action=='put' or not file.exists():
            fd,tmp=tempfile.mkstemp(dir=directory)
            try:
                with os.fdopen(fd,'w') as out: json.dump(current,out,ensure_ascii=False);out.write('\n');out.flush();os.fsync(out.fileno())
                os.chmod(tmp,0o600);os.replace(tmp,file)
            finally:
                if os.path.exists(tmp): os.unlink(tmp)
        print(json.dumps(current,ensure_ascii=False))
if __name__=='__main__':
    try: main()
    except Exception: print('Каталог не сохранён: проверьте формат, права или обновите список.',file=sys.stderr);sys.exit(1)
