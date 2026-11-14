#!/usr/bin/env bash
set -euo pipefail
umask 077
export REMOTE_DISK_SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
python3 - "$@" 3<&0 <<'PY'
import os,sys,json,subprocess,hashlib,tempfile,tarfile,urllib.request,time,socket,base64,re,fcntl,xml.etree.ElementTree as E
from pathlib import Path
s=Path.home()/'.local/share/remote-disk'; cfg=s/'config.xml'; binary=s/'bin/syncthing'; here=Path(os.environ['REMOTE_DISK_SCRIPT_DIR'])
a=sys.argv[1:] or ['bootstrap']; action=a[0]
def safe(p):
    if any(x.is_symlink() for x in (p,*p.parents)):raise ValueError('Символические ссылки запрещены')
def folder_path(name):
    if not isinstance(name,str) or not re.fullmatch(r'[^\W\d-][\w. -]{0,127}|[0-9][\w. -]{0,127}',name) or '..' in name or name[-1] in ' .' or re.match(r'(?i)^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',name):raise ValueError('Недопустимое имя папки')
    p=Path.home()/'Disk'/name;safe(p);return p

def ignores(p,write=True):
    f=p/'.stignore';managed=p/'.stignore-remoteagents';marker=p/'.stfolder'
    for path in (f,managed,marker):safe(path)
    rules=(here/'stignore.txt').read_text(encoding='utf-8-sig').replace('\r','').encode('utf-8')
    old=f.read_bytes() if f.exists() else b''
    include=b'#include .stignore-remoteagents'
    merged=old
    if include not in [line.strip() for line in old.removeprefix(b'\xef\xbb\xbf').splitlines()]:
        newline=b'\r\n' if b'\r\n' in old else b'\n'
        merged=old+(newline if old and not old.endswith(b'\n') else b'')+include+newline
    if not write:return
    marker.mkdir(exist_ok=True)
    # Publish the include target first. User rules stay byte-for-byte intact.
    for target,content in ((managed,rules),(f,merged)):
        if target.exists() and target.read_bytes()==content:continue
        fd,tmp=tempfile.mkstemp(dir=marker)
        try:
            with os.fdopen(fd,'wb') as out:out.write(content);out.flush();os.fsync(out.fileno())
            os.replace(tmp,target)
        finally:
            if os.path.exists(tmp):os.unlink(tmp)
def git(p,*args):
    r=subprocess.run(['git','-C',str(p),*args],capture_output=True,text=True,timeout=5);return r.stdout.strip() if r.returncode==0 else ''
def exclude_git(p):
    value=git(p,'rev-parse','--git-path','info/exclude')
    if not value:return
    target=Path(value);target=target if target.is_absolute() else p/target;safe(target)
    if not target.resolve().is_relative_to((Path.home()/'Disk').resolve()):return
    target.parent.mkdir(parents=True,exist_ok=True)
    old=target.read_text() if target.exists() else '';missing=[x for x in ('.stignore','.stignore-remoteagents','.stfolder','*.sync-conflict-*') if x not in old.splitlines()]
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
    targets=[('ssh',2222,int(data.get('sshPort',22)))]
    ports=json.loads((s/'ports.json').read_text()) if (s/'ports.json').exists() else {}
    if ports.get('listen'):targets.append(('sync',22001,int(ports['listen'])))
    return dict(log=dict(disabled=True),inbounds=[dict(type='direct',tag=tag,listen='127.0.0.1',listen_port=port,network='tcp',override_address='127.0.0.1',override_port=target) for tag,port,target in targets],outbounds=out,route=dict(final='server',auto_detect_interface=True))
def ensure_cron():
    line=b'* * * * * bash "$HOME/.local/share/remote-disk/server-disk.sh" bootstrap >/dev/null 2>&1'
    try:
        old=subprocess.run(['crontab','-l'],capture_output=True,timeout=5)
        if old.returncode not in (0,1) or line in old.stdout.splitlines():return
        content=old.stdout+(b'\n' if old.stdout and not old.stdout.endswith(b'\n') else b'')+line+b'\n'
        subprocess.run(['crontab','-'],input=content,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=5)
    except (OSError,subprocess.SubprocessError):pass
def reconcile(api,identity):
    disk=Path.home()/'Disk';safe(disk)
    folders=api('config/folders');devices=[d['deviceID'] for d in api('config/devices') if d['deviceID']!=identity]
    if not disk.exists():return
    for p in sorted(disk.iterdir()):
        if not p.is_dir() or p.is_symlink():continue
        try:
            folder_path(p.name)
            matches=[f for f in folders if f['path'].rstrip('/')==str(p)]
            if len(matches)>1:raise ValueError('Несколько ID для одной папки')
            current=matches[0] if matches else None
            folder_id=current['id'] if current else p.name
            if any(f['id']==folder_id and f['path'].rstrip('/')!=str(p) for f in folders):raise ValueError('ID занят')
            if not current:
                current=api('config/defaults/folder');current.update(id=folder_id,label=p.name,path=str(p),type='sendreceive',paused=False,devices=[dict(deviceID=identity)],maxConflicts=-1,versioning=dict(type='staggered',params=dict(maxAge='0',cleanInterval='3600')),rescanIntervalS=60,fsWatcherEnabled=True)
            conflict_changed=current.get('maxConflicts')!=-1 or current.get('type')!='sendreceive'
            current['type']='sendreceive'
            current['maxConflicts']=-1
            missing=[d for d in devices if not any(x['deviceID']==d for x in current['devices'])]
            ignores(p);exclude_git(p)
            if missing or not matches or conflict_changed:
                current['devices'] += [dict(deviceID=d) for d in missing]
                api('config/folders/'+urllib.parse.quote(folder_id,safe=''),'PUT',current)
        except ValueError as e:print('RemoteDisk: '+p.name+': '+str(e),file=sys.stderr)

def main():
    for path in (s,cfg,binary,s/'ports.json',s/'bootstrap.lock',s/'syncthing.log',s/'syncthing.pid'):safe(path)
    if action not in ('add-device','channel-config','bootstrap','install-auto'):raise ValueError('Неизвестная команда')
    payload=a[1] if len(a)==2 else None
    if payload=='--stdin':
        with os.fdopen(3,'r') as stream:payload=stream.read(8*1024*1024+1).replace('\r','').strip()
        if len(payload)>8*1024*1024:raise ValueError('Запрос слишком велик')
    data=json.loads(base64.b64decode(payload,validate=True)) if payload else {}
    if action=='install-auto':
        units=Path.home()/'.config/systemd/user';safe(units);units.mkdir(parents=True,exist_ok=True)
        script=s/'server-disk.sh'
        if not script.exists():raise ValueError('Сначала скопируйте server-disk.sh в ~/.local/share/remote-disk')
        for unit in ('remote-disk-folders.service','remote-disk-folders.timer'):safe(units/unit)
        (units/'remote-disk-folders.service').write_text('[Unit]\nDescription=RemoteDisk folder discovery\n[Service]\nType=oneshot\nExecStart=/bin/bash "%h/.local/share/remote-disk/server-disk.sh" bootstrap\n')
        (units/'remote-disk-folders.timer').write_text('[Unit]\nDescription=Discover RemoteDisk folders every 30s\n[Timer]\nOnStartupSec=10\nOnUnitInactiveSec=30\n[Install]\nWantedBy=timers.target\n')
        subprocess.run(['systemctl','--user','daemon-reload'],check=True)
        subprocess.run(['systemctl','--user','enable','--now','remote-disk-folders.timer'],check=True)
        print('{}');return
    if action=='channel-config':print(json.dumps(channel(data)));return
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
            device_id=data['deviceId']
            previous=next((d for d in api('config/devices') if d['deviceID']==device_id),None)
            device=dict(previous) if previous else api('config/defaults/device')
            device['deviceID']=device_id
            if not previous:device.update(name='RemoteDisk',addresses=['dynamic'],autoAcceptFolders=False)
            if 'deviceName' in data:device['name']=data['deviceName']
            if 'addresses' in data:device['addresses']=data['addresses']
            if device!=previous:api('config/devices/'+urllib.parse.quote(device_id,safe=''),'PUT',device)
        reconcile(api,identity)
        if action=='add-device':print('{}');return
        if action=='bootstrap':ensure_cron()
        print(json.dumps(dict(deviceId=identity,listen=ports['listen'])))
try:main()
except ValueError as e:print(str(e),file=sys.stderr);sys.exit(1)
except Exception:print('RemoteDisk: операция не выполнена',file=sys.stderr);sys.exit(1)
PY
