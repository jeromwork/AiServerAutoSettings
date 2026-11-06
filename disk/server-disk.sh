#!/usr/bin/env bash
# Private user process. Never sources project/runtime/handoff files.
set -euo pipefail
umask 077
[ "$(id -u)" != 0 ] || { echo 'RemoteDisk must run as an ordinary user; a root SSH profile must use runuser' >&2; exit 1; }
state="$HOME/.local/share/remote-disk"
mkdir -p "$state"
exec 9>"$state/bootstrap.lock"
flock -w 20 9
export REMOTE_DISK_STATE="$state"
python3 - "$@" <<'PY'
import os,sys,json,subprocess,hashlib,tarfile,urllib.request,time,socket,xml.etree.ElementTree as E
from pathlib import Path
s=Path(os.environ['REMOTE_DISK_STATE']); binary=s/'bin/syncthing'; cfg=s/'config.xml'
a=sys.argv[1:] or ['bootstrap']
def safe(p):
    if any(x.is_symlink() for x in (p,*p.parents)): raise ValueError('Symlink refused')
safe(s)
if a[0]=='mkdir':
    import base64,re
    name=base64.b64decode(a[1],validate=True).decode()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,63}',name): raise ValueError('Invalid folder name')
    p=Path.home()/'Disk'/name; safe(p); p.mkdir(parents=True,exist_ok=True)
    print(json.dumps({'path':str(p)})); sys.exit()
if a[0] != 'bootstrap': raise ValueError('Unknown action')
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
print(json.dumps(dict(ports,deviceId=identity,apiKey=key)))
PY
