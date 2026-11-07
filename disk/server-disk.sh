#!/usr/bin/env bash
# Private user process. Never sources project/runtime/handoff files.
set -euo pipefail
umask 077
state="$HOME/.local/share/remote-disk"
export REMOTE_DISK_STATE="$state"
python3 - "$@" <<'PY'
import os,sys,json,subprocess,hashlib,tarfile,urllib.request,time,socket,base64,re,fcntl,xml.etree.ElementTree as E
from pathlib import Path
s=Path(os.environ['REMOTE_DISK_STATE']); binary=s/'bin/syncthing'; cfg=s/'config.xml'
a=sys.argv[1:] or ['bootstrap']
def safe(p):
    if any(x.is_symlink() for x in (p,*p.parents)): raise ValueError('Symlink refused')
safe(s)
# Metadata and attachment mutations live here because clients must share one lock.
def name_ok(name):
    if (not isinstance(name,str) or not 1<=len(name)<=128 or '..' in name
        or name[-1] in ' .' or not all(c.isalnum() or c in '_-. ' for c in name)
        or name[0] in ' .-' or name.split('.')[0].upper() in
        {'CON','PRN','AUX','NUL',*[f'COM{i}' for i in range(1,10)],*[f'LPT{i}' for i in range(1,10)]}):
        raise ValueError('Invalid folder name')
    return name

def folder_id(name):return 'disk-'+hashlib.sha256(('folder:'+name_ok(name)).encode()).hexdigest()[:24]
def folder_path(name):
    p=Path.home()/'Disk'/name_ok(name);safe(p);return p

def git(p,*args):
    result=subprocess.run(['git','-C',str(p),*args],capture_output=True,text=True)
    return result.stdout.replace('\r','').strip() if result.returncode==0 else ''

def clean_origin(value):
    # Never return userinfo, query or fragment (including access tokens).
    from urllib.parse import urlsplit,urlunsplit
    value=value.strip()
    if '://' in value:
        try:
            u=urlsplit(value)
            if not u.hostname:return ''
            host=u.hostname
            if ':' in host:host='['+host+']'
            if u.port:host+=':'+str(u.port)
            return urlunsplit((u.scheme,host,u.path,'',''))
        except ValueError:return ''
    m=re.fullmatch(r'(?:[^/@:]+@)?([^/:]+):(.+)',value)
    if m:return m[1]+':'+m[2].split('?')[0].split('#')[0]
    # Local origins are paths, not credentials.
    return value.split('?')[0].split('#')[0] if '@' not in value else ''

def has_files(p):
    return p.is_dir() and any(x.name not in {'.git','.stignore','.stfolder','.stversions'} for x in p.iterdir())

def git_counts(p):
    if not p.is_dir():return dict(uncommittedFiles=None,unpushedCommits=None)
    raw=subprocess.run(['git','-C',str(p),'status','--porcelain=v1','-z','--untracked-files=all'],capture_output=True)
    if raw.returncode:return dict(uncommittedFiles=None,unpushedCommits=None)
    records=raw.stdout.split(b'\0');count=0;i=0
    while i<len(records):
        row=records[i];i+=1
        if not row:continue
        count+=1
        if b'R' in row[:2] or b'C' in row[:2]:i+=1
    upstream=git(p,'rev-parse','--abbrev-ref','@{upstream}')
    unpushed=git(p,'rev-list','--count',upstream+'..HEAD') if upstream else git(p,'rev-list','--count','HEAD','--not','--remotes')
    return dict(uncommittedFiles=count,unpushedCommits=int(unpushed) if unpushed.isdigit() else 0)

def worktrees(p):
    entries=[]
    for record in git(p,'worktree','list','--porcelain','-z').split('\0'):
        if not record.startswith('worktree '):continue
        path=Path(record[9:]);connectable=path.parent==Path.home()/'Disk' and path.is_dir() and not path.is_symlink()
        try:name_ok(path.name)
        except ValueError:connectable=False
        entries.append(dict(path=str(path),connectable=connectable,**git_counts(path)))
    return entries

def metadata(p):
    top=git(p,'rev-parse','--show-toplevel')
    in_git=bool(top) and Path(top).resolve()==p.resolve()
    try:identity=folder_id(p.name)
    except ValueError:identity=None
    # Preserve the ID of an already indexed legacy folder; never index one path twice.
    if cfg.exists():
        matches=[f.get('id') for f in E.parse(cfg).getroot().findall('folder') if f.get('path','').rstrip('/')==str(p)]
        if len(matches)>1:raise ValueError('Multiple existing folder IDs for one server path')
        if matches:identity=matches[0]
    return dict(name=p.name,id=identity,path=str(p),origin=clean_origin(git(p,'remote','get-url','origin')) if in_git else '',
                branch=git(p,'symbolic-ref','--quiet','--short','HEAD') if in_git else '',
                worktree=in_git and (p/'.git').is_file(),hasFiles=has_files(p),
                worktrees=worktrees(p) if in_git else [],**(git_counts(p) if in_git else dict(uncommittedFiles=None,unpushedCommits=None)))

def check_ignores(p,rules):
    safe(p/'.stignore')
    if (p/'.stignore').exists() and (p/'.stignore').read_text(encoding='utf-8-sig').splitlines()!=rules:
        raise ValueError('Existing .stignore: review/remove it manually')

def exclude_git(p):
    if not git(p,'rev-parse','--show-toplevel'):return
    value=git(p,'rev-parse','--git-path','info/exclude')
    if not value:raise ValueError('Cannot locate git exclude')
    target=Path(value)
    if not target.is_absolute():target=p/target
    # A worktree git path can be outside the synced folder; git is authoritative.
    safe(target);target.parent.mkdir(parents=True,exist_ok=True)
    old=target.read_bytes() if target.exists() else b''
    lines=old.decode('utf-8-sig').splitlines()
    missing=[x for x in ('.stignore','.stfolder','.stversions','*.sync-conflict-*') if x not in lines]
    if missing:
        with target.open('ab') as f:f.write(((('\n' if old and not old.endswith(b'\n') else '')+'\n'.join(missing)+'\n')).encode())

if a[0]=='list':
    disk=Path.home()/'Disk';safe(disk)
    print(json.dumps([metadata(p) for p in sorted(disk.iterdir()) if p.is_dir() and not p.is_symlink()] if disk.exists() else [],ensure_ascii=True));sys.exit()
if a[0]=='inspect':
    data=json.loads(base64.b64decode(a[1],validate=True));p=folder_path(data['name'])
    check_ignores(p,data['ignores'])
    print(json.dumps(dict(metadata(p),exists=p.exists())));sys.exit()
# Read-only operations above create nothing. Refusals are checked before even state creation.
if a[0]=='attach':
    preflight=json.loads(base64.b64decode(a[1],validate=True));p=folder_path(preflight['name'])
    check_ignores(p,preflight['ignores'])
    if preflight['localHasFiles'] and has_files(p) and not preflight.get('merge',False):
        raise ValueError('Nonempty local and server folders: explicit -Merge required')
s.mkdir(parents=True,exist_ok=True)
lock=(s/'bootstrap.lock').open('a')
fcntl.flock(lock,fcntl.LOCK_EX)
if a[0]=='exclude':
    data=json.loads(base64.b64decode(a[1],validate=True));p=folder_path(data['name'])
    if p.is_dir():exclude_git(p)
    print('{}');sys.exit()
if a[0]=='engine-windows':
    import base64,re
    cache=s/'cache'; safe(cache); cache.mkdir(exist_ok=True)
    archive=cache/'syncthing-windows-amd64-v2.1.7.zip'; safe(archive)
    size=14281765
    sha='3ce7da770f546a8d02b65b2e7ee31f2a3b8b7c3f990ede045590cca4172ecfe1'
    def valid():
        if not archive.exists() or archive.stat().st_size!=size:return False
        h=hashlib.sha256()
        with archive.open('rb') as f:
            for block in iter(lambda:f.read(262144),b''):h.update(block)
        return h.hexdigest()==sha
    if len(a)==2 and a[1]=='prepare':
        if not valid():
            part=cache/'engine.zip.part'; safe(part)
            try:
                with urllib.request.urlopen('https://github.com/syncthing/syncthing/releases/download/v2.1.7/syncthing-windows-amd64-v2.1.7.zip',timeout=30) as r, part.open('wb') as f:
                    import shutil
                    shutil.copyfileobj(r,f,262144)
                part.replace(archive)
                if not valid():
                    archive.unlink(); raise ValueError('SHA256 mismatch')
            finally:
                if part.exists():part.unlink()
        print(json.dumps({'size':size}));sys.exit()
    if len(a)==4 and a[1]=='chunk' and all(re.fullmatch(r'[0-9]+',v) for v in a[2:]):
        offset,length=map(int,a[2:])
        if length>2097152 or offset>size or offset+length>size:raise ValueError('Invalid chunk range')
        if not valid():raise ValueError('Run engine-windows prepare first')
        with archive.open('rb') as f:
            f.seek(offset);data=f.read(length)
        print(base64.b64encode(data).decode('ascii'));sys.exit()
    raise ValueError('Invalid engine-windows arguments')
if a[0] not in ('bootstrap','device-port','attach','detach','resolve'): raise ValueError('Unknown action')
if not binary.exists():
    if os.uname().machine!='x86_64': raise ValueError('Only linux-amd64 supported')
    archive=s/'download.tar.gz'
    # --archive is for isolated offline acceptance only.
    if len(a)==3 and a[1]=='--archive': archive=Path(a[2])
    else: urllib.request.urlretrieve('https://github.com/syncthing/syncthing/releases/download/v2.1.7/syncthing-linux-amd64-v2.1.7.tar.gz',archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest()!='2edc416e7ed136b7c858ed5f3f02a3b8316589605e54c380228ceea7acbf0142': raise ValueError('SHA256 mismatch')
    binary.parent.mkdir(exist_ok=True)
    with tarfile.open(archive) as t: binary.write_bytes(t.extractfile('syncthing-linux-amd64-v2.1.7/syncthing').read())
    binary.chmod(0o700)
if not subprocess.check_output([str(binary),'--version'],text=True).startswith('syncthing v2.1.7 '): raise ValueError('Wrong version')
if not cfg.exists():
    subprocess.run([str(binary),'generate','--home',str(s),'--no-port-probing'],check=True,stdout=subprocess.DEVNULL)
    tree=E.parse(cfg); root=tree.getroot()
    for f in list(root.findall('folder')): root.remove(f)
    sockets=[]
    for _ in range(3):
        sock=socket.socket();sock.bind(('127.0.0.1',0));sockets.append(sock)
    ports=[x.getsockname()[1] for x in sockets]
    def put(parent,name,value):
        n=parent.find(name)
        if n is None:n=E.SubElement(parent,name)
        n.text=str(value)
    opt=root.find('options')
    for name in ('globalAnnounceEnabled','localAnnounceEnabled','relaysEnabled','natEnabled','startBrowser','crashReportingEnabled'): put(opt,name,'false')
    for n in list(opt.findall('listenAddress')): opt.remove(n)
    put(opt,'listenAddress',f'tcp://127.0.0.1:{ports[0]}')
    put(opt,'autoUpgradeIntervalH',0);put(opt,'urAccepted',-1)
    put(root.find('gui'),'address',f'127.0.0.1:{ports[1]}')
    tree.write(cfg,encoding='utf-8',xml_declaration=True);cfg.chmod(0o600)
    (s/'ports.json').write_text(json.dumps(dict(listen=ports[0],gui=ports[1],reverse=ports[2])))
    for sock in sockets:sock.close()
root=E.parse(cfg).getroot();ports=json.loads((s/'ports.json').read_text())
key=root.findtext('gui/apikey')
def ready():
    try:
        req=urllib.request.Request(f"http://127.0.0.1:{ports['gui']}/rest/system/status",headers={'X-API-Key':key})
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req,timeout=1) as r:return json.load(r)['myID']
    except Exception:return None
identity=ready()
if not identity:
    env={k:v for k,v in os.environ.items() if not k.startswith('ST')}
    with (s/'syncthing.log').open('ab') as log:
        # nohup + own session, no inherited lock/SSH descriptors.
        p=subprocess.Popen(['nohup',str(binary),'serve','--home',str(s),'--no-browser','--no-restart','--no-upgrade'],stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True,close_fds=True,env=env)
    (s/'syncthing.pid').write_text(str(p.pid))
    for _ in range(100):
        identity=ready()
        if identity:break
        if p.poll() is not None:raise RuntimeError('Syncthing exited; inspect syncthing.log')
        time.sleep(.1)
if not identity:raise RuntimeError('API readiness timeout')
def api(route,method='GET',body=None):
    request=urllib.request.Request(f"http://127.0.0.1:{ports['gui']}/rest/{route}",
        headers={'X-API-Key':key,'Content-Type':'application/json'},method=method,
        data=None if body is None else json.dumps(body).encode())
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request,timeout=5) as r:
        return json.loads(r.read() or b'{}')

def device_port(device):
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,128}',device):raise ValueError('Invalid device name')
    path=s/'device-ports.json';safe(path)
    mapping=json.loads(path.read_text()) if path.exists() else {}
    if device not in mapping:
        while True:
            sock=socket.socket();sock.bind(('127.0.0.1',0));port=sock.getsockname()[1];sock.close()
            if port not in [*mapping.values(),*ports.values()]:break
        mapping[device]=port
        temp=path.with_suffix('.tmp');temp.write_text(json.dumps(mapping));temp.replace(path)
    return mapping[device]

if a[0]=='resolve':
    from urllib.parse import urlencode
    data=json.loads(base64.b64decode(a[1],validate=True));p=folder_path(data['name'])
    folders=api('config/folders');folder=next((x for x in folders if x['path'].rstrip('/')==str(p)),None)
    if not folder:raise ValueError('Folder is not connected')
    fid=folder['id'];actions=[]
    api('db/scan?'+urlencode(dict(folder=fid)),'POST')
    pattern=re.compile(r'^(.*)\.sync-conflict-\d{8}-\d{6}-([A-Z2-7]{7})(\.[^/]*)?$')
    candidates=[]
    for parent,dirs,files in os.walk(p,followlinks=False):
        dirs[:]=[d for d in dirs if d not in ('.git','.stfolder','.stversions') and not (Path(parent)/d).is_symlink()]
        for name in files:
            match=pattern.fullmatch(name)
            if match:candidates.append((Path(parent)/name,match))
    journal=s/'conflicts.jsonl'
    def audit(action,relative,phase):
        with journal.open('a',encoding='utf-8') as log:
            log.write(json.dumps(dict(time=time.time(),action=action,file=relative,phase=phase),ensure_ascii=True)+'\n');log.flush();os.fsync(log.fileno())
    for copy,match in sorted(candidates,key=lambda x:x[0].name):
        safe(copy);relative=str(copy.relative_to(p));query=urlencode(dict(folder=fid,file=relative))
        api('db/scan?'+urlencode(dict(folder=fid,sub=relative)),'POST')
        info=api('db/file?'+query).get('local',{})
        # v2.1.7 suffix is the INCOMING WINNER, not the owner of the losing copy.
        # The index's modifiedBy identifies where this conflict copy was created;
        # unlike the suffix this also distinguishes conflicts received from other clients.
        creator=info.get('modifiedBy')
        if not creator or info.get('deleted') or info.get('size')!=copy.stat().st_size:
            raise ValueError('Conflict provenance not yet indexed; retry')
        original=copy.with_name(match[1]+(match[3] or ''));safe(original)
        before=original.stat() if original.exists() else None
        primary=api('db/file?'+urlencode(dict(folder=fid,file=str(original.relative_to(p))))).get('local',{})
        action='restore-server' if creator==identity[:7] else 'discard-client'
        if action=='restore-server' and primary.get('modifiedBy')==identity[:7]:action='discard-obsolete-server'
        if action=='restore-server':
            from datetime import datetime
            indexed=datetime.fromisoformat(primary['modified'].replace('Z','+00:00')).timestamp()
            if before is None or primary.get('deleted') or primary.get('size')!=before.st_size or abs(indexed-before.st_mtime)>0.001:
                raise ValueError('Server edit not yet indexed; retry')
        signature=lambda st:None if st is None else (st.st_ino,st.st_size,st.st_mtime_ns,st.st_ctime_ns)
        audit(action,relative,'intent')
        if action=='restore-server':
            if signature(before)!=signature(original.stat() if original.exists() else None):
                raise ValueError('Server file changed during conflict resolution; retry')
            os.replace(copy,original)
            # Make this resolution a NEW server edit, after the client's winning mtime.
            now=time.time_ns();os.utime(original,ns=(now,now))
        else:copy.unlink()
        audit(action,relative,'done');actions.append(dict(file=relative,action=action))
    if actions:api('db/scan?'+urlencode(dict(folder=fid)),'POST')
    print(json.dumps(dict(actions=actions)));sys.exit()
if a[0]=='device-port':
    print(json.dumps(dict(reverse=device_port(a[1]))));sys.exit()
if a[0] in ('attach','detach'):
    data=json.loads(base64.b64decode(a[1],validate=True));p=folder_path(data['name']);fid=folder_id(data['name'])
    # Explicit old ID is accepted only for removal, never changes legacy attachments.
    if a[0]=='detach' and data.get('id'):fid=data['id']
    folders=api('config/folders')
    matches=[x for x in folders if x['path'].rstrip('/')==str(p)]
    if len(matches)>1:raise ValueError('Multiple existing folder IDs for one server path')
    current=next((x for x in folders if x['id']==fid),None)
    if current is None and matches:current=matches[0];fid=current['id']
    if a[0]=='detach':
        if current:
            current['devices']=[x for x in current['devices'] if x['deviceID']!=data['deviceId']]
            api('config/folders/'+fid,'PUT',current)
        print('{}');sys.exit()
    rules=data['ignores'];check_ignores(p,rules)
    if data['localHasFiles'] and has_files(p) and not data.get('merge',False):
        raise ValueError('Nonempty local and server folders: explicit -Merge required')
    if current and Path(current['path'])!=p:raise ValueError('Folder ID already uses another server path')
    # Inspect every failure condition before creating a folder or altering its config.
    p.mkdir(parents=True,exist_ok=True);exclude_git(p)
    (p/'.stignore').write_text('\n'.join(rules)+'\n',encoding='utf-8')
    if current is None:
        current=dict(data['folder'],id=fid,label=data['name'],path=str(p),paused=True,devices=[dict(deviceID=identity)])
    if not any(x['deviceID']==data['deviceId'] for x in current['devices']):
        current['devices'].append(dict(deviceID=data['deviceId']))
    api('config/devices/'+data['deviceId'],'PUT',dict(deviceID=data['deviceId'],name=data['deviceName'],
        addresses=[f"tcp://127.0.0.1:{device_port(data['deviceName'])}"],autoAcceptFolders=False))
    current['versioning']=dict(type='')
    api('config/folders/'+fid,'PUT',current)
    applied=api('config/folders/'+fid)
    if applied['type']!='sendreceive' or not any(x['deviceID']==data['deviceId'] for x in applied['devices']):
        raise ValueError('Server folder verification failed')
    if not next((x for x in folders if x['id']==fid),None):api('config/folders/'+fid,'PATCH',dict(paused=False))
    print(json.dumps(dict(id=fid,path=str(p))));sys.exit()
print(json.dumps(dict(ports,deviceId=identity,apiKey=key)))
PY
