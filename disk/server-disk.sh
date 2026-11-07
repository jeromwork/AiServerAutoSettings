#!/usr/bin/env bash
set -euo pipefail
umask 077
export REMOTE_DISK_SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
python3 - "$@" <<'PY'
import os,sys,json,subprocess,hashlib,tarfile,urllib.request,time,socket,base64,re,fcntl,xml.etree.ElementTree as E
from pathlib import Path
s=Path.home()/'.local/share/remote-disk'; cfg=s/'config.xml'; binary=s/'bin/syncthing'; here=Path(os.environ['REMOTE_DISK_SCRIPT_DIR'])
a=sys.argv[1:] or ['bootstrap']; action=a[0]
def safe(p):
    if any(x.is_symlink() for x in (p,*p.parents)):raise ValueError('Символические ссылки запрещены')
def folder_path(name):
    if not isinstance(name,str) or not re.fullmatch(r'[^\W\d-][\w. -]{0,127}|[0-9][\w. -]{0,127}',name) or '..' in name or name[-1] in ' .' or re.match(r'(?i)^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',name):raise ValueError('Недопустимое имя папки')
    p=Path.home()/'Disk'/name;safe(p);return p

def fid(name):return 'disk-'+hashlib.sha256(('folder:'+name).encode()).hexdigest()[:24]
def has_files(p):return p.exists() and any(x.name not in {'.git','.stignore','.stfolder','.stversions'} for x in p.iterdir())
def ignores(p,write=False):
    f=p/'.stignore';safe(f);rules=(here/'stignore.txt').read_bytes()
    if f.exists() and f.read_bytes()!=rules:
        normalized='\n'.join(f.read_text(encoding='utf-8-sig').splitlines())+'\n'
        if hashlib.sha256(normalized.encode()).hexdigest() not in (here/'legacy-ignores.sha256').read_text().splitlines():raise ValueError('Чужой .stignore: сохраните и удалите его вручную перед подключением')
    if write:f.write_bytes(rules)
def git(p,*args):
    r=subprocess.run(['git','-C',str(p),*args],capture_output=True,text=True,timeout=5);return r.stdout.strip() if r.returncode==0 else ''
def exclude_git(p):
    value=git(p,'rev-parse','--git-path','info/exclude')
    if not value:return
    target=Path(value);target=target if target.is_absolute() else p/target;safe(target);target.parent.mkdir(parents=True,exist_ok=True)
    old=target.read_text() if target.exists() else '';missing=[x for x in ('.stignore','.stfolder','*.sync-conflict-*') if x not in old.splitlines()]
    if missing:target.write_text(old+('\n' if old and not old.endswith('\n') else '')+'\n'.join(missing)+'\n')
def channel(data):
    source=json.loads(Path(os.environ.get('REMOTE_DISK_CHANNEL_SOURCE','/etc/sing-box/config.json')).read_text())
    inbound=next(x for x in source['inbounds'] if x['type']=='vless' and x.get('listen_port')==443 and any(u.get('name')=='client' for u in x['users']))
    user=next(x for x in inbound['users'] if x.get('name')=='client');tls=inbound['tls'];reality=tls['reality']
    raw=base64.urlsafe_b64decode(reality['private_key']+'===')
    if len(raw)!=32:raise ValueError('Некорректный Reality key')
    der=subprocess.run(['openssl','pkey','-inform','DER','-pubout','-outform','DER'],input=bytes.fromhex('302e020100300506032b656e04220420')+raw,capture_output=True,timeout=5)
    if der.returncode:raise ValueError('Не удалось получить Reality public key')
    public=base64.urlsafe_b64encode(der.stdout[-32:]).decode().rstrip('=')
    v=dict(type='vless',tag='vless-direct',server=data['server'],server_port=443,uuid=user['uuid'],flow=user.get('flow',''),tls=dict(enabled=True,server_name=tls.get('server_name') or reality['handshake']['server'],utls=dict(enabled=True,fingerprint='chrome'),reality=dict(enabled=True,public_key=public,short_id=reality['short_id'][0])))
    out=[v];tags=['vless-direct']
    if data.get('hop'):out += [dict(v,tag='vless-hop',detour='hop-ssh'),dict(data['hop'],type='ssh',tag='hop-ssh')];tags.append('vless-hop')
    out.append(dict(type='urltest',tag='server',outbounds=tags,url='https://www.gstatic.com/generate_204',interval='1m',tolerance=300))
    return dict(log=dict(disabled=True),inbounds=[dict(type='direct',tag=tag,listen='127.0.0.1',listen_port=port,network='tcp',override_address='127.0.0.1',override_port=target) for tag,port,target in [('ssh',2222,22),('sync',22001,json.loads((s/'ports.json').read_text())['listen'])]],outbounds=out,route=dict(final='server',auto_detect_interface=True))
def ensure_cron():
    line=b'* * * * * bash "$HOME/.local/share/remote-disk/server-disk.sh" bootstrap >/dev/null 2>&1'
    try:
        old=subprocess.run(['crontab','-l'],capture_output=True,timeout=5)
        if old.returncode not in (0,1) or line in old.stdout.splitlines():return
        content=old.stdout+(b'\n' if old.stdout and not old.stdout.endswith(b'\n') else b'')+line+b'\n'
        subprocess.run(['crontab','-'],input=content,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=5)
    except (OSError,subprocess.SubprocessError):pass
def main():
    for path in (s,cfg,binary,s/'ports.json',s/'bootstrap.lock',s/'syncthing.log',s/'syncthing.pid'):safe(path)
    if action not in ('list','attach','detach','add-device','channel-config','bootstrap'):raise ValueError('Неизвестная команда')
    data=json.loads(base64.b64decode(a[1],validate=True)) if len(a)==2 else {}
    if action=='channel-config':print(json.dumps(channel(data)));return
    if action=='list':
        disk=Path.home()/'Disk';safe(disk);root=E.parse(cfg).getroot() if cfg.exists() else E.Element('configuration');rows=[]
        for p in sorted(disk.iterdir()) if disk.exists() else []:
            if not p.is_dir() or p.is_symlink():continue
            try:folder_path(p.name)
            except ValueError:continue
            ids=[f.get('id') for f in root.findall('folder') if f.get('path','').rstrip('/')==str(p)]
            if len(ids)>1:raise ValueError('Несколько ID для одной папки')
            rows.append(dict(name=p.name,id=ids[0] if ids else fid(p.name),hasFiles=has_files(p)))
        print(json.dumps(rows));return
    if action in ('attach','detach'):
        p=folder_path(data['name'])
        if action=='attach':
            ignores(p)
            linked=cfg.exists() and any(f.get('path','').rstrip('/')==str(p) and any(d.get('id')==data['deviceId'] for d in f.findall('device')) for f in E.parse(cfg).getroot().findall('folder'))
            if not linked and has_files(p) and data.get('localHasFiles') and not data.get('merge'):raise ValueError('Обе папки непустые: требуется -Merge')
    s.mkdir(parents=True,exist_ok=True)
    with (s/'bootstrap.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        if not binary.exists():
            archive=Path(a[2]) if len(a)==3 and a[1]=='--archive' else s/'download.tar.gz'
            if archive==s/'download.tar.gz':
                with urllib.request.urlopen('https://github.com/syncthing/syncthing/releases/download/v2.1.7/syncthing-linux-amd64-v2.1.7.tar.gz',timeout=30) as r:archive.write_bytes(r.read())
            if hashlib.sha256(archive.read_bytes()).hexdigest()!='2edc416e7ed136b7c858ed5f3f02a3b8316589605e54c380228ceea7acbf0142':raise ValueError('SHA256 mismatch')
            binary.parent.mkdir(exist_ok=True)
            with tarfile.open(archive) as t:binary.write_bytes(t.extractfile('syncthing-linux-amd64-v2.1.7/syncthing').read())
            binary.chmod(0o700)
        if not subprocess.check_output([str(binary),'--version'],timeout=5).startswith(b'syncthing v2.1.7 '):raise ValueError('Требуется Syncthing 2.1.7')
        if not cfg.exists():
            subprocess.run([str(binary),'generate','--home',str(s),'--no-port-probing'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
            tree=E.parse(cfg);root=tree.getroot();opt=root.find('options');socks=[socket.socket() for _ in range(2)]
            for sock in socks:sock.bind(('127.0.0.1',0))
            ports=dict(zip(('listen','gui'),[x.getsockname()[1] for x in socks]))
            for f in root.findall('folder'):root.remove(f)
            def put(parent,n,v):
                for old in parent.findall(n):parent.remove(old)
                E.SubElement(parent,n).text=str(v)
            for n in ('globalAnnounceEnabled','localAnnounceEnabled','relaysEnabled','natEnabled','startBrowser','crashReportingEnabled'):put(opt,n,'false')
            for n,v in dict(autoUpgradeIntervalH=0,reconnectionIntervalS=10,urAccepted=-1,listenAddress=f"tcp://127.0.0.1:{ports['listen']}").items():put(opt,n,v)
            put(root.find('gui'),'address',f"127.0.0.1:{ports['gui']}");tree.write(cfg,encoding='utf-8',xml_declaration=True)
            (s/'ports.json').write_text(json.dumps(ports))
            for sock in socks:sock.close()
        root=E.parse(cfg).getroot();ports=json.loads((s/'ports.json').read_text());key=root.findtext('gui/apikey');http=urllib.request.build_opener(urllib.request.ProxyHandler({}))
        def api(route,method='GET',body=None):
            req=urllib.request.Request(f"http://127.0.0.1:{ports['gui']}/rest/{route}",headers={'X-API-Key':key,'Content-Type':'application/json'},method=method,data=None if body is None else json.dumps(body).encode())
            with http.open(req,timeout=3) as r:return json.loads(r.read() or b'{}')
        def ready():
            try:return api('system/status')['myID']
            except Exception:return None
        identity=ready()
        if not identity:
            with (s/'syncthing.log').open('ab') as log:proc=subprocess.Popen([str(binary),'serve','--home',str(s),'--no-browser','--no-restart','--no-upgrade'],stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True,close_fds=True,env={k:v for k,v in os.environ.items() if not k.startswith('ST')})
            (s/'syncthing.pid').write_text(str(proc.pid))
            for _ in range(80):
                identity=ready()
                if identity:break
                time.sleep(.1)
        if not identity:raise ValueError('Движок не запустился')
        api('config/options','PATCH',dict(globalAnnounceEnabled=False,localAnnounceEnabled=False,relaysEnabled=False,natEnabled=False,autoUpgradeIntervalH=0,reconnectionIntervalS=10))
        if action=='add-device':
            api('config/devices/'+data['deviceId'],'PUT',dict(deviceID=data['deviceId'],name=data.get('deviceName','RemoteDisk'),addresses=data.get('addresses',['dynamic']),autoAcceptFolders=False));print('{}');return
        if action in ('attach','detach'):
            folders=api('config/folders');matches=[f for f in folders if f['path'].rstrip('/')==str(p)]
            if len(matches)>1:raise ValueError('Несколько ID для одной папки')
            current=matches[0] if matches else None;folder_id=current['id'] if current else fid(data['name'])
            if action=='detach':
                if current:current['devices']=[d for d in current['devices'] if d['deviceID']!=data['deviceId']];api('config/folders/'+folder_id,'PUT',current)
            else:
                if any(f['id']==folder_id and f['path'].rstrip('/')!=str(p) for f in folders):raise ValueError('ID уже занят другой папкой')
                linked=current and any(d['deviceID']==data['deviceId'] for d in current['devices'])
                if not linked and has_files(p) and data.get('localHasFiles') and not data.get('merge'):raise ValueError('Обе папки непустые: требуется -Merge')
                ignores(p);p.mkdir(parents=True,exist_ok=True);ignores(p,True);exclude_git(p)
                current=current or dict(id=folder_id,label=data['name'],path=str(p),type='sendreceive',paused=False,devices=[dict(deviceID=identity)],rescanIntervalS=60,fsWatcherEnabled=True)
                if not any(d['deviceID']==data['deviceId'] for d in current['devices']):current['devices'].append(dict(deviceID=data['deviceId']))
                current['maxConflicts']=10;api('config/folders/'+folder_id,'PUT',current)
            print(json.dumps(dict(id=folder_id)));return
        if action=='bootstrap':ensure_cron()
        print(json.dumps(dict(deviceId=identity,listen=ports['listen'])))
try:main()
except ValueError as e:print(str(e),file=sys.stderr);sys.exit(1)
except Exception:print('RemoteDisk: операция не выполнена',file=sys.stderr);sys.exit(1)
PY
