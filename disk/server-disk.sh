#!/usr/bin/env bash
set -euo pipefail
umask 077
export REMOTE_DISK_SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
python3 - "$@" 3<&0 <<'PY'
import os,sys,json,subprocess,hashlib,tempfile,tarfile,urllib.request,time,socket,base64,re,fcntl,stat,xml.etree.ElementTree as E
from pathlib import Path
s=Path.home()/'.local/share/remote-disk'; cfg=s/'config.xml'; binary=s/'bin/syncthing'; here=Path(os.environ['REMOTE_DISK_SCRIPT_DIR'])
a=sys.argv[1:] or ['bootstrap']; action=a[0]
# systemd-таймер, поставленный прежним install-auto, вызывает reconcile: это та же команда, что bootstrap.
if action=='reconcile':action='bootstrap'
# Чтение REST быстрое. PUT папки ждёт перезапуска её движка: на нагруженном сервере это секунды, а папок много.
API_READ_TIMEOUT,API_WRITE_TIMEOUT=3,30
# Свой код, потому что Syncthing не знает, что .stignore с нашим прежним шаблоном — не правила пользователя.
# SHA-256 точных байтов шаблонов, которые мы сами клали в папки: disk/stignore.txt на app/config (395c2cb, b8cfc4e, f79b03f)
# и список имён Get-DiskIgnores из RemoteDisk.ps1 до 395c2cb. Их правила теперь живут в .stignore-remoteagents.
PREVIOUS_TEMPLATES=frozenset((
 '9c1b2c9568492b513199bd44ee9963a1915e5d89c5cf79031cd9e3067ffc3409',
 '53ec8f57dcd8d6e778ecb1b1fea26ed071f82820ff8d42198bc33d553773bbb5',
 '9a486952e5510eaf30e6d95dfe3400fb48a71e1d7d68a0cbccfb539562f6b80c',
 'c20a596f615c0a62ffd6e5a1e8a9dd8c3a06420b26d312b29b9d8dced0632eb8'))
def safe(p):
    if any(x.is_symlink() for x in (p,*p.parents)):raise ValueError('Символические ссылки запрещены')
def folder_path(name):
    if not isinstance(name,str) or not re.fullmatch(r'\w[\w. ()-]{0,127}',name) or len(name.encode('utf-8'))>240 or '..' in name or name[-1] in ' .' or re.match(r'(?i)^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',name):raise ValueError('Недопустимое имя папки')
    p=Path.home()/'Disk'/name;safe(p);return p

def incoming_name(label):
    # Label приходит от другого компьютера: это имя, а не путь. Ограничиваем и байты (Linux), и символы (Windows).
    name=re.sub(r'[^\w. ()-]','_',label or '').strip(' .')
    while '..' in name:name=name.replace('..','_')
    if not name:name='Папка'
    if not re.match(r'\w',name) or re.match(r'(?i)^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',name):name='_'+name
    name=name[:110]
    while len(name.encode('utf-8'))>220:name=name[:-1]
    return name.rstrip(' .')

def incoming_marker(p):
    marker=p/'.stfolder/remote-disk-folder-id';safe(marker);return marker

def new_folder(api,identity,folder_id,p):
    current=api('config/defaults/folder')
    current.update(id=folder_id,label=p.name,path=str(p),type='sendreceive',paused=False,devices=[dict(deviceID=identity)],maxConflicts=-1,versioning=dict(type='staggered',params=dict(maxAge='0',cleanInterval='3600')),rescanIntervalS=60,fsWatcherEnabled=True,fsWatcherDelayS=2)
    return current

def configured_paths(folders):
    return [str(Path(os.path.abspath(os.path.expanduser(f['path'])))).casefold().rstrip('/') for f in folders]

def accept_pending(api,identity,folders,devices,reserved):
    disk=Path.home()/'Disk'
    for folder_id,offer in sorted(api('cluster/pending/folders').items()):
        try:
            # Pending может содержать старое предложение уже удалённого устройства. Никогда не включаем autoAcceptFolders.
            peers=sorted(set(offer.get('offeredBy',{})) & set(devices))
            if not peers or any(f['id']==folder_id for f in folders):continue
            p=reserved.get(folder_id)
            if p is None:
                name=incoming_name(offer['offeredBy'][peers[0]].get('label') or folder_id)
                disk.mkdir(exist_ok=True)
                used={x.name.casefold() for x in disk.iterdir()}
                paths=configured_paths(folders)
                n=1
                while True:
                    candidate=name if n==1 else name+' ('+str(n)+')'
                    if candidate.casefold() in used:
                        n+=1;continue
                    p=folder_path(candidate);normalized=str(p).casefold()
                    if any(normalized.startswith(x+'/') for x in paths):raise ValueError('Корень Disk уже входит в другую папку Syncthing')
                    if not any(x==normalized or x.startswith(normalized+'/') for x in paths):
                        try:p.mkdir()
                        except FileExistsError:used.add(candidate.casefold())
                        else:break
                    n+=1
                # Запоминаем ID до PUT: после ошибки REST повтор использует тот же каталог, не создаёт ещё один.
                (p/'.stfolder').mkdir()
                write_atomic(incoming_marker(p),folder_id.encode('utf-8'),p/'.stfolder')
                reserved[folder_id]=p
            safe(p)
            normalized=str(p).casefold()
            if any(x==normalized or x.startswith(normalized+'/') or normalized.startswith(x+'/') for x in configured_paths(folders)):raise ValueError('Путь входящей папки уже занят другой папкой Syncthing')
            ignores(p)
            current=new_folder(api,identity,folder_id,p)
            current['devices'] += [dict(deviceID=d) for d in devices]
            api('config/folders/'+urllib.parse.quote(folder_id,safe=''),'PUT',current)
            folders.append(current)
        except FOLDER_ERRORS as e:skipped(folder_id,e)

def write_atomic(target,content,tmpdir):
    # Атомарная замена; права существующего файла сохраняются (иначе mkstemp сделал бы из 0664 файл 0600).
    mode=stat.S_IMODE(target.stat().st_mode) if target.exists() else None
    fd,tmp=tempfile.mkstemp(dir=tmpdir)
    try:
        with os.fdopen(fd,'wb') as out:
            out.write(content);out.flush()
            if mode is not None:os.fchmod(out.fileno(),mode)
            os.fsync(out.fileno())
        os.replace(tmp,target)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)
def ignores(p,write=True):
    f=p/'.stignore';managed=p/'.stignore-remoteagents';marker=p/'.stfolder'
    for path in (f,managed,marker):safe(path)
    rules=(here/'stignore.txt').read_text(encoding='utf-8-sig').replace('\r','').encode('utf-8')
    old=f.read_bytes() if f.exists() else b''
    # Побайтово наш прежний шаблон: правила переехали в .stignore-remoteagents, остаётся один include. Всё прочее — пользователя.
    if hashlib.sha256(old).hexdigest() in PREVIOUS_TEMPLATES:old=b''
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
        write_atomic(target,content,marker)
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
CRON_LINE=b'* * * * * bash "$HOME/.local/share/remote-disk/server-disk.sh" bootstrap >/dev/null 2>&1'
def ensure_cron(enabled=True):
    try:
        old=subprocess.run(['crontab','-l'],capture_output=True,timeout=5)
        if old.returncode not in (0,1):return
        lines=old.stdout.splitlines(keepends=True)
        if enabled:
            if CRON_LINE in old.stdout.splitlines():return
            content=old.stdout+(b'\n' if old.stdout and not old.stdout.endswith(b'\n') else b'')+CRON_LINE+b'\n'
        else:
            content=b''.join(line for line in lines if line.rstrip(b'\r\n')!=CRON_LINE)
            if content==old.stdout:return
        subprocess.run(['crontab','-'],input=content,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=5)
    except (OSError,subprocess.SubprocessError):pass

def ensure_auto():
    # Bootstrap is also the installer/wizard and the old timer's entry point.
    # Update only changed unit files: running every 2 s must not reload/restart itself.
    def systemctl(*args):
        return subprocess.run(['systemctl','--user',*args],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=5).returncode==0
    try:
        if not systemctl('show-environment'):raise OSError('user systemd unavailable')
        units=Path.home()/'.config/systemd/user';safe(units);units.mkdir(parents=True,exist_ok=True)
        script=s/'server-disk.sh'
        if not script.is_file():raise ValueError('Сначала скопируйте server-disk.sh в ~/.local/share/remote-disk')
        contents={
            'remote-disk-folders.service':'[Unit]\nDescription=RemoteDisk folder discovery\n[Service]\nType=oneshot\n# Runs every 2 s: keep successes out of the journal, errors (stderr) stay visible as warnings.\nStandardOutput=null\nSyslogLevel=warning\nLogLevelMax=notice\nExecStart=/bin/bash "%h/.local/share/remote-disk/server-disk.sh" bootstrap\n',
            'remote-disk-folders.timer':'[Unit]\nDescription=Discover and accept RemoteDisk folders every 2s\n[Timer]\nOnStartupSec=2\nOnUnitInactiveSec=2\nAccuracySec=1\n[Install]\nWantedBy=timers.target\n'}
        stamp=s/'auto-units.sha256';safe(stamp)
        generation=hashlib.sha256(json.dumps(contents,sort_keys=True).encode()).hexdigest().encode()
        changed=not stamp.exists() or stamp.read_bytes()!=generation
        existed=(units/'remote-disk-folders.timer').exists()
        for name,content in contents.items():
            target=units/name;safe(target);content=content.encode('utf-8')
            if not target.exists() or target.read_bytes()!=content:
                write_atomic(target,content,units);changed=True
        if changed and not systemctl('daemon-reload'):raise OSError('systemd reload failed')
        if changed or not systemctl('is-enabled','--quiet','remote-disk-folders.timer') or not systemctl('is-active','--quiet','remote-disk-folders.timer'):
            if not systemctl('enable','--now','remote-disk-folders.timer'):raise OSError('systemd enable failed')
        if changed and existed and not systemctl('restart','remote-disk-folders.timer'):raise OSError('systemd restart failed')
        if not stamp.exists() or stamp.read_bytes()!=generation:write_atomic(stamp,generation,s)
    except (OSError,ValueError,subprocess.SubprocessError):
        ensure_cron();return
    # Remove only our own minute job after the fast timer is confirmed available.
    ensure_cron(False)
# Сбой одной папки (недопустимое имя, права доступа, ошибка REST, git не ответил) не должен лишать остальные папки обнаружения.
FOLDER_ERRORS=(ValueError,OSError,subprocess.SubprocessError)
def describe(e):return str(e) if isinstance(e,ValueError) else type(e).__name__+': '+str(e)
def skipped(name,e):print('RemoteDisk: '+name+': '+describe(e),file=sys.stderr)
def reconcile(api,identity):
    disk=Path.home()/'Disk';safe(disk)
    folders=api('config/folders');devices=[d['deviceID'] for d in api('config/devices') if d['deviceID']!=identity]
    reserved={};entries=[]
    for p in sorted(disk.iterdir()) if disk.exists() else []:
        try:
            if not p.is_dir() or p.is_symlink():continue
            folder_path(p.name)
            marker=incoming_marker(p)
            if marker.exists():
                incoming_id=marker.read_text(encoding='utf-8')
                if not incoming_id or incoming_id in reserved:raise ValueError('Повторный или пустой ID входящей папки')
                if any(f['path'].rstrip('/')==str(p) and f['id']!=incoming_id for f in folders):raise ValueError('ID входящей папки не совпадает с конфигурацией')
                reserved[incoming_id]=p
            entries.append(p)
        except FOLDER_ERRORS as e:skipped(p.name,e)
    # Принимаем прежде регистрации местных папок: даже ID, равный занятому label, не должен незаметно слить их данные.
    try:accept_pending(api,identity,folders,devices,reserved)
    except FOLDER_ERRORS as e:skipped('входящие папки',e)
    incoming_ids={p:i for i,p in reserved.items()}
    for p in entries:
        try:
            matches=[f for f in folders if f['path'].rstrip('/')==str(p)]
            if len(matches)>1:raise ValueError('Несколько ID для одной папки')
            current=matches[0] if matches else None
            if p in incoming_ids:
                # Не выдаём недопринятую папку за новый серверный проект. Нужен повтор предложения от известного peer.
                if not current:continue
                if incoming_ids[p]!=current['id']:raise ValueError('ID входящей папки не совпадает с конфигурацией')
            folder_id=current['id'] if current else p.name
            if any(f['id']==folder_id and f['path'].rstrip('/')!=str(p) for f in folders):raise ValueError('ID занят')
            if not current:
                current=new_folder(api,identity,folder_id,p)
            conflict_changed=current.get('maxConflicts')!=-1 or current.get('type')!='sendreceive' or current.get('fsWatcherDelayS')!=2 or not current.get('fsWatcherEnabled')
            current['type']='sendreceive'
            current['maxConflicts']=-1
            current['fsWatcherEnabled']=True
            current['fsWatcherDelayS']=2
            missing=[d for d in devices if not any(x['deviceID']==d for x in current['devices'])]
            ignores(p)
            # Исключения в Git — косметика (чистый git status): нет git или он завис — папку всё равно предлагаем.
            try:exclude_git(p)
            except FOLDER_ERRORS as e:skipped(p.name,e)
            if missing or not matches or conflict_changed:
                current['devices'] += [dict(deviceID=d) for d in missing]
                api('config/folders/'+urllib.parse.quote(folder_id,safe=''),'PUT',current)
                if not matches:folders.append(current)
        except FOLDER_ERRORS as e:skipped(p.name,e)

# Зависшие соединения устройства. Свой код, потому что у Syncthing нет настройки, которая сократила бы 300 с молчания
# (ReceiveTimeout — константа протокола), а отказ новым соединениям на это время ломает подключение компьютера.
# Когда у компьютера меняется сеть, туннель (sing-box/relay) рвётся молча: для сервера все
# соединения — это 127.0.0.1:<порт> → его слушающий порт, и локальные сокеты остаются «живыми». Пока Syncthing не признает их
# мёртвыми (нет данных 300 с, проверка раз в 150 с, то есть 5-7,5 минут), он отказывает новым соединениям того же устройства
# («уже есть нужное число»): клиент видит EOF при обмене Hello, а сервер пишет об отказе только на уровне DEBUG, причём такой
# отказ бывает и у здорового устройства (клиент периодически пробует лишнее соединение — замерено на стенде): по журналу
# зависание не отличить.
# Надёжный признак — молчание: по протоколу BEP живой peer шлёт по каждому соединению хотя бы пинг раз в 90 с (на 2.1.7 замерено
# 45-90,6 с), поэтому устройство, у которого ни одно соединение не получило ни байта дольше STALE_AFTER_S, зависло. Это один
# GET /rest/system/connections за запуск; что видели в прошлый раз — в connection-watch.json. Лечение: pause и сразу resume
# именно этого устройства (старые соединения закрываются, клиент подключается заново), не чаще раза в HEAL_COOLDOWN_S.
STALE_AFTER_S,HEAL_COOLDOWN_S=120,60
watch=s/'connection-watch.json'
def number(value):return isinstance(value,(int,float)) and not isinstance(value,bool)
def load_watch():
    # Битый или чужой файл — не повод ломать bootstrap: наблюдение просто начинается заново.
    try:data=json.loads(watch.read_text(encoding='utf-8'))
    except (OSError,ValueError):data={}
    return {k:data[k] if isinstance(data,dict) and isinstance(data.get(k),dict) else {} for k in ('devices','healed','resume')}
def save_watch(state):
    if not any(state.values()):
        watch.unlink(missing_ok=True);return
    data=json.dumps(state,sort_keys=True,separators=(',',':')).encode()
    if watch.exists() and watch.read_bytes()==data:return
    # Без fsync: состояние при сбое питания можно потерять, наблюдение тогда начнётся заново. Запись при трафике — раз в 2 с.
    watch.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(dir=watch.parent)
    try:
        with os.fdopen(fd,'wb') as out:out.write(data)
        os.replace(tmp,watch)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)
def signature(c):
    # Любое изменение (байты входящего, появилось или закрылось соединение) — признак жизни: молчание отсчитывается заново.
    parts=[c['primary']]+(c.get('secondary') or []) if 'primary' in c else [c]
    return ';'.join('%s|%s|%s'%(p.get('address'),p.get('startedAt'),p.get('inBytesTotal')) for p in parts)
def device_call(api,verb,device_id):api('system/'+verb+'?device='+urllib.parse.quote(device_id,safe=''),'POST')
def recycle_device(api,device_id):
    # pause закрывает все соединения устройства (асинхронно, обычно за 0,1 с), resume пускает клиента обратно.
    # Возобновляем при любом исходе ожидания и повторяем при сбое: устройство не должно остаться на паузе по нашей вине.
    device_call(api,'pause',device_id)
    try:
        deadline=time.monotonic()+3
        while api('system/connections')['connections'].get(device_id,{}).get('connected') and time.monotonic()<deadline:time.sleep(.2)
    finally:
        for attempt in range(3):
            try:device_call(api,'resume',device_id);break
            except FOLDER_ERRORS:
                if attempt==2:raise
                time.sleep(.5)
def device_label(api,device_id):
    try:name=api('config/devices/'+urllib.parse.quote(device_id,safe='')).get('name')
    except FOLDER_ERRORS:name=None
    # Имя задаёт другая сторона: управляющие символы не должны превратить одну строку журнала в несколько.
    name=re.sub(r'[\x00-\x1f\x7f]',' ',name).strip() if isinstance(name,str) else ''
    return (name+' ' if name else '')+'('+device_id[:7]+')'
def watch_connections(api,now=None):
    # Монотонные часы: перевод системного времени не выдаст живое устройство за молчащее. После перезагрузки сервера счётчик
    # начинается заново, и отметка «из будущего» просто сбрасывается (сигнатура соединений после перезапуска движка другая).
    now=time.monotonic() if now is None else now
    old=load_watch();stats=api('system/connections')['connections']
    resume=dict(old['resume']);devices={};healed={};stale=[]
    # Остаток прерванного лечения (сбой между pause и resume): поставленное нами на паузу устройство возобновляем.
    for device_id in list(resume):
        try:
            if stats.get(device_id,{}).get('paused'):device_call(api,'resume',device_id)
            del resume[device_id]
        except FOLDER_ERRORS as e:skipped(device_id[:7],e)
    # Время лечения хранится только пока действует пауза между лечениями; счётчик, начавшийся заново после перезагрузки, её не продлевает.
    for device_id,at in old['healed'].items():
        if number(at) and 0<=now-at<HEAL_COOLDOWN_S:healed[device_id]=at
    for device_id,c in sorted(stats.items()):
        if not c.get('connected') or c.get('paused'):continue
        sig=signature(c)
        before=old['devices'].get(device_id)
        since=before.get('since') if isinstance(before,dict) and before.get('sig')==sig else None
        if not number(since) or since>now:since=now
        devices[device_id]=dict(sig=sig,since=since)
        if now-since>=STALE_AFTER_S and device_id not in healed:stale.append((device_id,now-since))
    for device_id,silent in stale:
        label=device_id[:7]
        try:
            # Решение принято по снимку, а лечение других устройств и ответы REST занимают время: перед паузой сверяемся со
            # свежими данными. Устройство, которое успело ожить, отключиться или быть поставленным владельцем на паузу, не трогаем.
            fresh=api('system/connections')['connections'].get(device_id,{})
            if not fresh.get('connected') or fresh.get('paused') or signature(fresh)!=devices[device_id]['sig']:continue
            # Пометка до паузы: если запуск оборвётся посреди лечения, следующий вернёт устройство из паузы.
            resume[device_id]=now;save_watch(dict(devices=devices,healed=healed,resume=resume))
            label=device_label(api,device_id)
            recycle_device(api,device_id)
            del resume[device_id];healed[device_id]=now;devices[device_id]['since']=now
            print('RemoteDisk: '+label+': соединения молчат '+str(int(silent))+' с, устройство перезапущено через pause/resume',file=sys.stderr)
        except FOLDER_ERRORS as e:skipped(label,e)
    save_watch(dict(devices=devices,healed=healed,resume=resume))

def main():
    for path in (s,cfg,binary,s/'ports.json',s/'bootstrap.lock',s/'syncthing.log',s/'syncthing.pid',watch):safe(path)
    if action not in ('add-device','channel-config','bootstrap','install-auto'):raise ValueError('Неизвестная команда')
    payload=a[1] if len(a)==2 else None
    if payload=='--stdin':
        with os.fdopen(3,'r') as stream:payload=stream.read(8*1024*1024+1).replace('\r','').strip()
        if len(payload)>8*1024*1024:raise ValueError('Запрос слишком велик')
    data=json.loads(base64.b64decode(payload,validate=True)) if payload else {}
    if action=='install-auto':ensure_auto();print('{}');return
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
            with http.open(req,timeout=API_READ_TIMEOUT if method=='GET' else API_WRITE_TIMEOUT) as r:return json.loads(r.read() or b'{}')
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
        ensure_auto()
        if action=='add-device':
            device_id=data['deviceId']
            previous=next((d for d in api('config/devices') if d['deviceID']==device_id),None)
            device=dict(previous) if previous else api('config/defaults/device')
            device['deviceID']=device_id
            if not previous:device.update(name='RemoteDisk',addresses=['dynamic'],autoAcceptFolders=False)
            if 'deviceName' in data:device['name']=data['deviceName']
            if 'addresses' in data:device['addresses']=data['addresses']
            if device!=previous:api('config/devices/'+urllib.parse.quote(device_id,safe=''),'PUT',device)
            # Устройство уже зарегистрировано: сбой обнаружения папок не отменяет знакомство, cron повторит расшаривание.
            try:reconcile(api,identity)
            except FOLDER_ERRORS as e:print('RemoteDisk: устройство зарегистрировано, папки сервера пока не обработаны: '+describe(e),file=sys.stderr)
            print('{}');return
        # До reconcile: долгая запись папок не должна откладывать лечение, а сбой проверки не должен останавливать папки.
        try:watch_connections(api)
        except Exception as e:skipped('соединения устройств',e)
        reconcile(api,identity)
        print(json.dumps(dict(deviceId=identity,listen=ports['listen'])))
try:main()
except ValueError as e:print(str(e),file=sys.stderr);sys.exit(1)
except Exception:print('RemoteDisk: операция не выполнена',file=sys.stderr);sys.exit(1)
PY
