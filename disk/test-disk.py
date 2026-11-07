#!/usr/bin/env python3
"""Isolated real-engine acceptance; uses production PS policy and server bootstrap."""
import importlib.util,json,os,subprocess,tempfile,time,sys
from pathlib import Path
# The shared scenario library is read-only; never create caches outside disk/tmp.
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('acceptance',HERE.parent/'test-two-way-sync.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class DiskFixture(m.Fixture):
    def __init__(self,root,archive,policy):
        import urllib.request,xml.etree.ElementTree as ET
        self.root=root;self.archive=archive;self.sides=[]
        self.http=urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.envs=[]
        for i in range(2):
            home=root/f'home-{i}';home.mkdir()
            env=dict(os.environ,HOME=str(home));self.envs.append(env)
            result=subprocess.run(['bash',str(HERE/'server-disk.sh'),'bootstrap','--archive',str(archive)],env=env,capture_output=True,text=True,check=True,timeout=30)
            data=json.loads(result.stdout)
            state=home/'.local/share/remote-disk'
            side=dict(directory=home,workspace=home/'Disk'/'test',state=state,gui=data['gui'],key=data['apiKey'],identity=data['deviceId'],env=env,listen=data['listen'],reverse=data['reverse'])
            self.sides.append(side)
            side['workspace'].mkdir(parents=True)
            (side['workspace']/f'initial-{i}.txt').write_text(f'initial-{i}')
            tree=ET.parse(state/'config.xml');opt=tree.find('options')
            for n in ('globalAnnounceEnabled','localAnnounceEnabled','relaysEnabled','natEnabled','crashReportingEnabled'):
                m.require(opt.findtext(n)=='false',f'external networking: {n}')
            m.require(opt.findtext('listenAddress')==f"tcp://127.0.0.1:{data['listen']}",'listener')
            m.require(tree.findtext('gui/address')==f"127.0.0.1:{data['gui']}",'GUI listener')
        for i,s in enumerate(self.sides):
            peer=self.sides[1-i];s['peer']=peer['identity']
            self.api(s,'config/devices/'+s['peer'],'PUT',dict(deviceID=s['peer'],addresses=[f"tcp://127.0.0.1:{peer['listen']}"],autoAcceptFolders=False,paused=True))
            f=dict(policy['folder']);f.update(id='ra-'+m.PROJECT,path=str(s['workspace']),devices=[dict(deviceID=s['identity']),dict(deviceID=s['peer'])])
            self.api(s,'config/folders/'+f['id'],'PUT',f)
            # Same as RemoteDisk: local file or remote REST while paused.
            self.api(s,'db/ignores?folder='+f['id'],'POST',dict(ignore=policy['ignores']))
            got=self.api(s,'config/folders/'+f['id'])
            m.require(got['paused'] and got['versioning']['type']=='','paused without versioning')
    def call(self,s,action,**kwargs):
        if action=='health':
            connections=self.api(s,'system/connections')['connections']
            return dict(connected=connections.get(s['peer'],{}).get('connected',False))
        if action=='resume':return self.api(s,'config/folders/ra-'+m.PROJECT,'PATCH',dict(paused=False))
        if action=='stop':return self.api(s,'system/shutdown','POST')
        raise ValueError(action)
    def start(self,s):
        result=subprocess.run(['bash',str(HERE/'server-disk.sh'),'bootstrap','--archive',str(self.archive)],env=s['env'],capture_output=True,text=True,check=True,timeout=30)
        m.require(json.loads(result.stdout)['deviceId']==s['identity'],'identity changed')
        s['stopped']=False
    def k5(self):
        # Do not dial a peer before both sides trust each other and have indexed their
        # initial files: an early rejected connection otherwise enters dial backoff.
        for side in self.sides:self.start(side)
        for side in self.sides:self.call(side,'resume')
        self.wait(lambda:all((lambda db:db['state']=='idle' and db['localFiles']>=1)(self.api(side,'db/status?folder=ra-'+m.PROJECT)) for side in self.sides),'initial local scans before connection')
        for side in self.sides:self.api(side,'config/devices/'+side['peer'],'PATCH',dict(paused=False))
        self.wait(lambda:all(self.call(side,'health')['connected'] for side in self.sides),'bilateral initial connection')
        self.wait(lambda:all(self.both(f'initial-{i}.txt',f'initial-{i}') for i in range(2)) and self.settled(),'initial union and indexed convergence')
        m.require(all(not list((side['workspace']/'.stversions').rglob('*')) for side in self.sides),'initial files archived/deleted')
    def k7(self):
        a,b=self.sides
        self.wait(lambda:self.call(a,'health')['connected'],'before disconnect')
        self.call(b,'stop');time.sleep(1)
        self.wait(lambda:not self.call(a,'health')['connected'],'offline')
        (a['workspace']/'recovery-a.txt').write_text('A');(b['workspace']/'recovery-b.txt').write_text('B')
        self.start(b)
        self.wait(lambda:self.both('recovery-a.txt','A') and self.both('recovery-b.txt','B') and self.call(a,'health')['connected'],'restart recovery')
    def k2(self):
        for i,side in enumerate(self.sides):
            name=f'edit-delete-{i}.txt';(side['workspace']/name).write_text('original')
            self.scan();self.wait(lambda:self.both(name,'original'),'original')
            (side['workspace']/name).write_text('changed-content')
            self.scan();self.wait(lambda:self.both(name,'changed-content'),'edit')
            (side['workspace']/name).unlink();self.scan()
            self.wait(lambda:all(not (s['workspace']/name).exists() for s in self.sides),'delete')
        m.require(all(not (s['workspace']/'.stversions').exists() for s in self.sides),'version directory created')

    def resolve_cases(self):
        from urllib.parse import quote
        server,client=self.sides
        for winner in ('server','client','server-edited'):
            name='race-'+winner+'.txt';(server['workspace']/name).write_text('base')
            self.scan();self.wait(lambda:self.both(name,'base') and self.settled(),'conflict base')
            self.pause_link(True)
            now=time.time()-30
            for i,side in enumerate(self.sides):
                text='canonical-server-bytes' if i==0 else 'competing-client-bytes'
                p=side['workspace']/name;p.write_text(text)
                stamp=now+(10 if (i==0)==(winner=='server') else 0);os.utime(p,(stamp,stamp));self.scan(side)
            def offline_scanned():
                return self.settled() and all((lambda info:info.get('modifiedBy')==side['identity'][:7] and info.get('size')==len('canonical-server-bytes'))(self.api(side,'db/file?folder=ra-'+m.PROJECT+'&file='+quote(name))['local']) for side in self.sides)
            self.wait(offline_scanned,'both local edits indexed before reconnect');self.pause_link(False)
            def conflicts_present():
                for side in self.sides:
                    copies=list(side['workspace'].glob('race-'+winner+'.sync-conflict-*'))
                    if not copies:return False
                    for copy in copies:
                        info=self.api(side,'db/file?folder=ra-'+m.PROJECT+'&file='+quote(copy.name)).get('local',{})
                        if info.get('size')!=22 or not info.get('version') or info.get('modifiedBy') in (None,'','AAAAAAA'):return False
                return self.settled()
            self.wait(conflicts_present,'conflict copies replicated (real puller backoff)',limit=180)
            copies=list(server['workspace'].glob('race-'+winner+'.sync-conflict-*'))
            for copy in copies:
                info=self.api(server,'db/file?folder=ra-'+m.PROJECT+'&file='+quote(copy.name))['local']
                expected=server['identity'][:7] if winner!='server' else client['identity'][:7]
                m.require(info['modifiedBy']==expected,'losing copy provenance differs: '+str(dict(case=winner,actual=info['modifiedBy'],expected=expected,server=server['identity'][:7],client=client['identity'][:7],copy=copy.name,canonicalCopy=(copy.read_text()=='canonical-server-bytes'),serverMain=(server['workspace']/name).read_text()=='canonical-server-bytes')))
                suffix=copy.name.split('.sync-conflict-',1)[1].split('-')[2].split('.')[0]
                expected_winner=server if winner=='server' else client
                m.require(suffix==expected_winner['identity'][:7],'v2.1.7 suffix is not the incoming winner')
            directories=[{str(p.relative_to(s['workspace'])) for p in s['workspace'].rglob('*') if p.is_dir()} for s in self.sides]
            import base64
            data=base64.b64encode(json.dumps(dict(name='test')).encode()).decode()
            if winner=='server-edited':
                (server['workspace']/name).write_text('canonical-server-bytes')
                self.scan(server)
            resolved={}
            retryable=('Conflict provenance not yet indexed; retry','Server edit not yet indexed; retry','Server file changed during conflict resolution; retry')
            def resolve_indexed():
                result=subprocess.run(['bash',str(HERE/'server-disk.sh'),'resolve',data],env=server['env'],capture_output=True,text=True,timeout=30)
                if result.returncode==0:
                    resolved['actions']=json.loads(result.stdout)['actions'];return True
                diagnostic=result.stderr
                for side in self.sides:diagnostic=diagnostic.replace(side['key'],'[redacted]')
                resolved['error']=diagnostic[-1500:]
                # Production also retries these explicit safety refusals on its next tick.
                m.require(any(reason in diagnostic for reason in retryable),'resolver failed: '+resolved['error'])
                return False
            try:self.wait(resolve_indexed,'resolver waits for indexed, unchanged files',limit=60)
            except AssertionError as exc:raise AssertionError(str(exc)+' '+resolved.get('error','')) from exc
            actions=resolved['actions']
            expected_action='discard-client' if winner=='server' else ('discard-obsolete-server' if winner=='server-edited' else 'restore-server')
            m.require(actions and all(x['action']==expected_action for x in actions),'wrong conflict resolution action')
            self.scan();self.wait(lambda:self.both(name,'canonical-server-bytes') and all(not list(s['workspace'].glob('*.sync-conflict-*')) for s in self.sides) and self.settled(),'canonical server convergence',limit=180)
            for i,side in enumerate(self.sides):
                m.require({str(p.relative_to(side['workspace'])) for p in side['workspace'].rglob('*') if p.is_dir()}==directories[i],'resolver created extra directories')
            journal=(server['state']/'conflicts.jsonl').read_text()
            m.require('canonical-server-bytes' not in journal and 'competing-client-bytes' not in journal,'conflict log leaked contents')
            print('PASS real conflict '+winner+' wins: '+expected_action+', canonical server bytes on both peers, no copies or extra directories',flush=True)

    def k3(self):
        # Sample production status continuously during the real concurrent-edit scenario.
        side=self.sides[0];config=self.root/'sampler.json';stop=self.root/'sampler.stop';output=self.root/'sampler-results.json'
        config.write_text(json.dumps(dict(gui=side['gui'],key=side['key'],serverId=side['peer'],folders=[dict(id='ra-'+m.PROJECT,name='legacy',path=str(side['workspace']),remotePath='/legacy')])) )
        script=self.root/'sample.ps1'
        script.write_text("""param($Library,$ConfigPath,$Stop,$Output)
. $Library -LibraryOnly
$data=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
$script:Config=$data;$script:LocalKey=$data.key;$script:RemoteKey=''
$states=New-Object 'System.Collections.Generic.List[string]'
$deadline=[DateTime]::UtcNow.AddSeconds(600)
while(-not (Test-Path -LiteralPath $Stop) -and [DateTime]::UtcNow -lt $deadline){
    foreach($row in @(Get-DiskSnapshot)){$states.Add($row.state)}
    [IO.File]::WriteAllText($Output,($states.ToArray()|ConvertTo-Json -Compress))
    Start-Sleep -Milliseconds 70
}
""")
        with (self.root/'sampler.stderr').open('wb') as err:
            process=subprocess.Popen([str(Path.home()/'.cache/pwsh-test/pwsh'),'-NoProfile','-File',str(script),str(HERE/'RemoteDisk.ps1'),str(config),str(stop),str(output)],stdout=subprocess.DEVNULL,stderr=err)
            try:
                self.resolve_cases()
                self.wait(lambda:output.exists() and 'conflict' in json.loads(output.read_text()),'production status sees real conflict')
            finally:
                stop.touch()
                try:process.wait(timeout=10)
                except subprocess.TimeoutExpired:process.terminate();process.wait(timeout=5)
        m.require(process.returncode==0,'status sampler failed: '+(self.root/'sampler.stderr').read_text())
        states=json.loads(output.read_text())
        m.require('error' not in states and 'conflict' in states,'false conflict status: '+str(sorted(set(states))))
        print('PASS real conflict status: continuous production REST sampling includes conflict, no error',flush=True)

    def close(self):
        for s in self.sides:
            try:self.call(s,'stop')
            except Exception:pass
            # Only PIDs in our temporary HOME, with /proc ownership check.
            pid=int((s['state']/'syncthing.pid').read_text())
            try:
                if str(s['state']).encode() in Path(f'/proc/{pid}/cmdline').read_bytes():os.kill(pid,15)
            except (FileNotFoundError,ProcessLookupError):pass


class MultiFixture(DiskFixture):
    """Three engines, actual production attachment operations, isolated reverse TCP forwards."""
    def __init__(self, root, archive, policy):
        import urllib.request
        self.root=root;self.archive=archive;self.policy=policy;self.sides=[];self.proxies=[]
        self.http=urllib.request.build_opener(urllib.request.ProxyHandler({}))
        for i in range(3):
            home=root/f'home-{i}';home.mkdir()
            env=dict(os.environ,HOME=str(home))
            data=self.server(env,'bootstrap','--archive',str(archive))
            self.sides.append(dict(directory=home,state=home/'.local/share/remote-disk',
                gui=data['gui'],key=data['apiKey'],identity=data['deviceId'],listen=data['listen'],env=env))
        self.server_side,self.a,self.b=self.sides
        self.name='project';self.fid=self.identity(self.name)
        self.repo=self.server_side['directory']/'Disk'/self.name
        self.repo.mkdir(parents=True)
        self.git(self.repo,'init','-b','main')
        (self.repo/'tracked.txt').write_text('base')
        self.git(self.repo,'add','tracked.txt')
        self.git(self.repo,'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','fixture')
        self.raw_origin='https://synthetic-user:synthetic-token@code.example/owner/repo.git?auth=synthetic-query'
        self.git(self.repo,'remote','add','origin',self.raw_origin)
        self.worktree=self.repo.parent/'feature'
        self.git(self.repo,'worktree','add','-b','feature',str(self.worktree))
        self.external_tree=root/'outside-disk-worktree'
        self.git(self.repo,'worktree','add','-b','external',str(self.external_tree))
        self.git(self.repo,'update-ref','refs/remotes/origin/main','HEAD')
        self.git(self.repo,'branch','--set-upstream-to=origin/main','main')
        (self.external_tree/'outside-change.txt').write_text('untracked outside')
        (self.external_tree/'tracked.txt').write_text('external commit')
        self.git(self.external_tree,'add','tracked.txt')
        self.git(self.external_tree,'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','external')
        self.git(self.external_tree,'mv','tracked.txt','renamed.txt')
        (self.external_tree/'new-dir').mkdir()
        for name in ('one.txt','two.txt'):(self.external_tree/'new-dir'/name).write_text('untracked')
        (self.repo.parent/'plain').mkdir();(self.repo.parent/'plain'/'note.txt').write_text('plain')
        for i,side in enumerate((self.a,self.b),1):
            side['deviceName']=f'client-{i}';side['workspace']=root/f'client-{i}-arbitrary-path';side['workspace'].mkdir()
            side['reverse']=self.command('device-port',side['deviceName'])['reverse']
            self.proxy(side['reverse'],side['listen'])
            self.api(side,'config/devices/'+self.server_side['identity'],'PUT',dict(deviceID=self.server_side['identity'],addresses=[],autoAcceptFolders=False))
        m.require(self.a['reverse']!=self.b['reverse'],'reverse ports must differ')
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=4) as pool:
            ports=list(pool.map(lambda _:self.command('device-port',self.a['deviceName'])['reverse'],range(6)))
        m.require(set(ports)=={self.a['reverse']},'reverse port not stable/atomic')
        for side in self.sides:
            log=side['state']/'syncthing.log'
            m.require(log.stat().st_uid==os.getuid() and os.access(log,os.R_OK),'SSH user cannot read engine journal')
        print('PASS reverse ports: distinct clients, stable allocation, actual loopback forwards',flush=True)

    @staticmethod
    def identity(name):
        import hashlib
        return 'disk-'+hashlib.sha256(('folder:'+name).encode()).hexdigest()[:24]

    @staticmethod
    def server(env,*args,check=True):
        result=subprocess.run(['bash',str(HERE/'server-disk.sh'),*args],env=env,capture_output=True,text=True,timeout=30)
        if not check:return result
        m.require(result.returncode==0,'server command failed: '+result.stderr[-1000:])
        return json.loads(result.stdout)

    def command(self,*args,check=True):return self.server(self.server_side['env'],*args,check=check)

    @staticmethod
    def payload(data):
        import base64
        return base64.b64encode(json.dumps(data).encode()).decode()

    @staticmethod
    def git(path,*args):
        result=subprocess.run(['git','-C',str(path),*args],capture_output=True,text=True,check=True)
        return result.stdout.strip()

    def proxy(self,port,target):
        import socketserver,socket,select,threading
        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                try:
                    with socket.create_connection(('127.0.0.1',target),timeout=2) as other:
                        sockets=[self.request,other]
                        while True:
                            ready,_,_=select.select(sockets,[],[],.5)
                            for source in ready:
                                data=source.recv(262144)
                                if not data:return
                                (other if source is self.request else self.request).sendall(data)
                except (OSError,ConnectionError):pass
        class Server(socketserver.ThreadingTCPServer):
            allow_reuse_address=True;daemon_threads=True
        proxy=Server(('127.0.0.1',port),Handler)
        self.proxies.append(proxy);threading.Thread(target=proxy.serve_forever,daemon=True).start()

    def attach(self,side,name=None,local=None,merge=False,check=True):
        name=name or self.name;local=local or side['workspace'];fid=self.identity(name)
        data=dict(name=name,ignores=self.policy['ignores'],folder=self.policy['folder'],deviceId=side['identity'],
                  deviceName=side['deviceName'],localHasFiles=any(local.iterdir()),merge=merge)
        result=self.command('attach',self.payload(data),check=check)
        if not check:return result
        folder=dict(self.policy['folder'],id=fid,label=name,path=str(local),devices=[dict(deviceID=side['identity']),dict(deviceID=self.server_side['identity'])])
        self.api(side,'config/folders/'+fid,'PUT',folder)
        self.api(side,'db/ignores?folder='+fid,'POST',dict(ignore=self.policy['ignores']))
        self.api(side,'config/folders/'+fid,'PATCH',dict(paused=False))
        return result

    def scan_all(self,fid=None):
        for side in self.sides:
            try:self.api(side,'db/scan?folder='+(fid or self.fid),'POST')
            except Exception:pass

    def same(self,name,content,locals=None):
        roots=locals or [self.repo,self.a['workspace'],self.b['workspace']]
        return all((p/name).is_file() and (p/name).read_text()==content for p in roots)

    def status(self,side,name='project',wait=0):
        app=side['directory']/'appdata'/'RemoteDisk';(app/'state').mkdir(parents=True,exist_ok=True)
        import shutil
        shutil.copyfile(side['state']/'config.xml',app/'state'/'config.xml')
        fid=self.identity(name)
        folders=self.api(side,'config/folders');folder=next(f for f in folders if f['id']==fid)
        (app/'config.json').write_text(json.dumps(dict(schema=1,gui=side['gui'],serverId=self.server_side['identity'],
            folders=[dict(id=fid,name=name,path=folder['path'],remotePath=str(self.repo.parent/name))])))
        (app/'server-folders.json').write_text(json.dumps(self.command('list')))
        env=dict(os.environ,LOCALAPPDATA=str(app.parent),COMPUTERNAME=side['deviceName'])
        result=subprocess.run([str(Path.home()/'.cache/pwsh-test/pwsh'),'-NoProfile','-File',str(HERE/'RemoteDisk.ps1'),
            '-Command','status','-Remote',name,'-Wait',str(wait)],capture_output=True,text=True,env=env,timeout=wait+20)
        m.require(result.returncode in (0,1),'status execution: '+result.stderr[-1500:])
        m.require(bool(result.stdout.strip()),'status produced no JSON: '+result.stderr[-1800:])
        return result.returncode,json.loads(result.stdout)

    def metadata_checks(self):
        listing=self.command('list');by_name={f['name']:f for f in listing}
        m.require(set(by_name)=={'project','feature','plain'},'list all first-level directories')
        m.require(by_name['project']['id']==self.fid and by_name['project']['branch']=='main','list id and branch')
        m.require(by_name['feature']['worktree'] and not by_name['project']['worktree'],'worktree flag')
        m.require(by_name['plain']['origin']=='' and by_name['plain']['branch']=='' and by_name['plain']['hasFiles'],'folder without git')
        m.require('synthetic-token' not in json.dumps(listing) and 'synthetic-query' not in json.dumps(listing) and 'synthetic-user' not in json.dumps(listing),'list credential leak')
        trees={x['path']:x for x in by_name['project']['worktrees']}
        m.require(trees[str(self.repo)]['connectable'] and trees[str(self.worktree)]['connectable'] and not trees[str(self.external_tree)]['connectable'],'worktree connectability')
        m.require(trees[str(self.external_tree)]['uncommittedFiles']==4 and trees[str(self.external_tree)]['unpushedCommits']==1,'external worktree counts')
        m.require(by_name['project']['uncommittedFiles']==0 and by_name['project']['unpushedCommits']==0,'main counts')
        print('PASS worktree list: inside/outside Disk, connectability, exact dirty-file and unpushed-commit counts',flush=True)
        # Real PowerShell log writer must scrub the same URL before JSONL is written.
        script=self.root/'redaction.ps1';journal=self.root/'redaction.jsonl'
        script.write_text(". '"+str(HERE/'RemoteDisk.ps1')+"' -LibraryOnly\n$script:LogFile='"+str(journal)+"';$script:HostName='fixture';$script:LocalKey='';$script:RemoteKey=''\nWrite-DiskLog 'origin' '"+self.raw_origin+"'\n")
        subprocess.run([str(Path.home()/'.cache/pwsh-test/pwsh'),'-NoProfile','-File',str(script)],check=True,capture_output=True)
        m.require('synthetic-token' not in journal.read_text() and 'synthetic-query' not in journal.read_text(),'journal leaked URL token')
        # Foreign ignore must fail without making a server folder, even on first attachment.
        bad=self.root/'foreign';bad.mkdir();(bad/'local.txt').write_text('local')
        result=self.attach(self.a,local=bad,check=False)
        m.require(result.returncode!=0 and '-Merge' in result.stderr,'nonempty attach without merge accepted')
        m.require(not (self.repo/'.stignore').exists() and self.api(self.server_side,'config/folders')==[],'refusal altered remote folder/config')
        new=self.repo.parent/'foreign';new.mkdir();(new/'.stignore').write_text('custom')
        result=self.attach(self.a,name='foreign',check=False)
        m.require(result.returncode!=0 and (new/'.stignore').read_text()=='custom' and not (new/'.stfolder').exists(),'foreign ignore changed')
        print('PASS list/origin/id: main clone, worktree, no-git, credentials absent from JSON and real journal; merge/foreign-ignore refusals unchanged',flush=True)

    def transfer_checks(self):
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=2) as pool:list(pool.map(self.attach,(self.a,self.b)))
        self.wait(lambda:self.same('tracked.txt','base'),'server to both empty clients')
        folder=self.api(self.server_side,'config/folders/'+self.fid)
        m.require(not folder['paused'] and len(folder['devices'])==3,'second client paused/lost device')
        (self.a['workspace']/'from-a.txt').write_text('A to B');self.scan_all()
        self.wait(lambda:self.same('from-a.txt','A to B'),'client A through server to B')
        (self.b['workspace']/'from-b.txt').write_text('B to A');self.scan_all()
        self.wait(lambda:self.same('from-b.txt','B to A'),'client B through server to A')
        self.attach(self.a,merge=True)
        m.require(len(self.api(self.server_side,'config/folders'))==1 and len(self.api(self.server_side,'config/folders/'+self.fid)['devices'])==3,'reconnect duplicated folder/device')
        code,rows=self.status(self.b,wait=30)
        m.require(rows[0]['uncommittedFiles']==2 and rows[0]['unpushedCommits']==0,'production status Git counts: '+str(rows))
        m.require('locked' in rows[0] and rows[0]['locked'] is None,'Linux must not pretend NTFS verified')
        m.require(code==0 and rows[0]['state']=='synced' and rows[0]['serverConnected'],'connected status not synced: '+str(rows))
        print('PASS three Syncthing 2.1.7: server -> both clients, A -> server -> B and B -> server -> A, repeat attachment has one folder',flush=True)
        self.command('detach',self.payload(dict(name=self.name,deviceId=self.a['identity'])))
        self.api(self.a,'config/folders/'+self.fid,'DELETE')
        folder=self.api(self.server_side,'config/folders/'+self.fid)
        m.require(len(folder['devices'])==2 and not folder['paused'] and self.repo.exists(),'detach affected remaining devices/files')
        (self.b['workspace']/'after-detach.txt').write_text('still connected');self.scan_all()
        self.wait(lambda:self.same('after-detach.txt','still connected',[self.repo,self.b['workspace']]),'remaining client after detach')
        print('PASS disconnect A: server folder/files and B preserved; B continues transferring',flush=True)

    def worktree_checks(self):
        target=self.root/'worktree-client';target.mkdir();self.attach(self.b,'feature',target)
        self.wait(lambda:(target/'tracked.txt').exists(),'worktree file transfer')
        m.require(not (target/'.git').exists(),'worktree .git file transferred')
        # Also verify exclusion in an ordinary git clone, including conflicts and versions.
        for repo in (self.repo,self.worktree):
            (repo/'sample.sync-conflict-test.txt').write_text('conflict')
        self.scan_all(self.identity('feature'))
        status=self.git(self.worktree,'status','--porcelain','--untracked-files=all')
        m.require(status=='','worktree git sees service files: '+status)
        main_status=self.git(self.repo,'status','--porcelain','--untracked-files=all')
        m.require(all(not any(x in line for x in ('.stignore','.stfolder','.stversions','sync-conflict')) for line in main_status.splitlines()),'clone sees service files')
        (target/'tracked.txt').write_text('client edit');self.api(self.b,'db/scan?folder='+self.identity('feature'),'POST')
        self.wait(lambda:(self.worktree/'tracked.txt').read_text()=='client edit','worktree client edit to server')
        m.require(self.git(self.worktree,'status','--porcelain','--untracked-files=all')=='M tracked.txt','client edit is not ordinary git change')
        exclude=Path(self.git(self.worktree,'rev-parse','--git-path','info/exclude'))
        if not exclude.is_absolute():exclude=self.worktree/exclude
        text=exclude.read_text()
        for line in ('.stignore','.stfolder','.stversions','*.sync-conflict-*'):m.require(text.splitlines().count(line)==1,'exclude duplicates')
        print('PASS clone + git worktree: simultaneous folders, content delivered, .git file absent, service/conflict files ignored, client edit is M tracked.txt',flush=True)

    def upload_check(self):
        local=self.root/'upload-client';local.mkdir();(local/'public.txt').write_text('first upload')
        # Execute production Add-DiskFolder in pwsh against real local/server REST.
        # Only SSH is replaced by bash in the isolated server HOME; no Windows APIs run.
        config=self.root/'upload-config.json'
        config.write_text(json.dumps(dict(schema=1,gui=self.b['gui'],remoteGui=self.server_side['gui'],
            deviceName=self.b['deviceName'],folders=[],contextMenu=False)))
        script=self.root/'upload.ps1'
        script.write_text("""param($Library,$ServerScript,$ConfigPath,$ServerHome,$LocalPath,$LocalKey,$RemoteKey,$LocalId,$PeerId)
. $Library -LibraryOnly
$script:ConfigFile=$ConfigPath;$script:Config=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
$script:LocalKey=$LocalKey;$script:RemoteKey=$RemoteKey;$script:LocalId=$LocalId;$script:PeerId=$PeerId
$script:LogFile=$ConfigPath+'.jsonl';$script:HostName='upload-fixture'
function Invoke-DiskServer($Action,$Data){
    $args=@($ServerScript,$Action)
    if($null -ne $Data){$args+=([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Data|ConvertTo-Json -Depth 30 -Compress))))}
    $saved=$env:HOME
    try{$env:HOME=$ServerHome;$text=& bash @args;if($LASTEXITCODE){throw 'isolated server command failed'};ConvertFrom-Json -InputObject ($text -join "`n")}finally{$env:HOME=$saved}
}
Add-DiskFolder $LocalPath 'upload'
""")
        # Keys stay in a private temporary input file, not process arguments.
        secrets=self.root/'upload-input.json'
        secrets.write_text(json.dumps(dict(LocalKey=self.b['key'],RemoteKey=self.server_side['key'],LocalId=self.b['identity'],PeerId=self.server_side['identity'])))
        text=script.read_text().replace('$LocalKey,$RemoteKey,$LocalId,$PeerId)', '$Secrets)')
        text=text.replace('. $Library -LibraryOnly', ". $Library -LibraryOnly\n$inputData=Get-Content -LiteralPath $Secrets -Raw|ConvertFrom-Json\n$LocalKey=$inputData.LocalKey;$RemoteKey=$inputData.RemoteKey;$LocalId=$inputData.LocalId;$PeerId=$inputData.PeerId")
        script.write_text(text)
        result=subprocess.run([str(Path.home()/'.cache/pwsh-test/pwsh'),'-NoProfile','-File',str(script),str(HERE/'RemoteDisk.ps1'),
            str(HERE/'server-disk.sh'),str(config),str(self.server_side['directory']),str(local),str(secrets)],capture_output=True,text=True,timeout=40)
        m.require(result.returncode==0,'production Add-DiskFolder failed: '+result.stderr[-1200:])
        target=self.repo.parent/'upload'
        self.wait(lambda:(target/'public.txt').exists() and (target/'public.txt').read_text()=='first upload','new server folder from nonempty client')
        code,rows=self.status(self.b,wait=30)
        m.require(code==0 and rows[0]['state']=='synced','post-upload status')
        self.api(self.b,'config/folders/'+self.fid,'PATCH',dict(paused=True))
        code,rows=self.status(self.b)
        m.require(code!=0 and rows[0]['state']=='paused','paused production status: '+str(rows))
        self.api(self.b,'config/folders/'+self.fid,'PATCH',dict(paused=False))
        print('PASS production Add-DiskFolder: nonempty client -> new server folder, no Git required; production paused status exits nonzero',flush=True)

    def compatibility_checks(self):
        name='legacy';p=self.repo.parent/name;p.mkdir();(p/'legacy.txt').write_text('old')
        old_id='disk-old-random-fixture'
        folder=dict(self.policy['folder'],id=old_id,path=str(p),devices=[dict(deviceID=self.server_side['identity'])])
        self.api(self.server_side,'config/folders/'+old_id,'PUT',folder)
        data=dict(name=name,ignores=self.policy['ignores'],folder=self.policy['folder'],deviceId=self.b['identity'],
            deviceName=self.b['deviceName'],localHasFiles=False,merge=False)
        result=self.command('attach',self.payload(data))
        m.require(result['id']==old_id,'legacy ID renamed')
        got=self.api(self.server_side,'config/folders/'+old_id)
        m.require(got['paused'] and len(got['devices'])==2,'existing pause/device state lost')
        listing=self.command('list');m.require(next(f for f in listing if f['name']==name)['id']==old_id,'list lost legacy ID')
        m.require(sum(f['path'].rstrip('/')==str(p) for f in self.api(self.server_side,'config/folders'))==1,'legacy path duplicated')
        self.command('detach',self.payload(dict(name=name,id=old_id,deviceId=self.b['identity'])))
        m.require(len(self.api(self.server_side,'config/folders/'+old_id)['devices'])==1 and (p/'legacy.txt').read_text()=='old','legacy detach removed folder/files')
        print('PASS legacy ID: existing server index reused without rename/duplicate; pause preserved; detach keeps files; engine journals readable by SSH user',flush=True)

    def offline_check(self):
        self.api(self.server_side,'system/shutdown','POST')
        self.wait(lambda:not self.api(self.b,'system/connections')['connections'].get(self.server_side['identity'],{}).get('connected',False),'server disconnect')
        code,rows=self.status(self.b,wait=1)
        m.require(code!=0 and rows[0]['state']=='offline' and rows[0]['remainingBytes']==0,'false offline success: '+str(rows))
        print('PASS production status CLI: synced exits 0; disconnected server with 0 remaining bytes is offline and exits 1 (-Wait included)',flush=True)

    def close(self):
        super().close()
        for proxy in getattr(self,'proxies',[]):proxy.shutdown();proxy.server_close()
def log_delivery_checks():
    """Real PS transport and receiver, replacing only SSH/network with a local process."""
    pwsh=Path.home()/'.cache/pwsh-test/pwsh'
    with tempfile.TemporaryDirectory(prefix='remote-disk-logs-') as temp:
        root=Path(temp);server=root/'server';server.mkdir()
        counter=root/'ssh-count';fail=root/'fail';shim=root/'ssh.py'
        shim.write_text("""#!/usr/bin/env python3
import os,sys,subprocess
from pathlib import Path
root=Path(__file__).parent
with (root/'ssh-count').open('a') as f:f.write('1\\n')
data=sys.stdin.buffer.read()
if (root/'fail').exists():
    print('synthetic token=do-not-leak',file=sys.stderr);sys.exit(44)
result=subprocess.run(['bash','-c',sys.argv[-1]],input=data,env=dict(os.environ,HOME=str(root/'server')))
sys.exit(result.returncode)
""")
        shim.chmod(0o700)
        driver=root/'send.ps1'
        driver.write_text("""param($Library,$DataRoot,$Transport,$DeviceName)
. $Library -LibraryOnly
$script:DiskHome=$DataRoot;$script:Queue=Join-Path $DataRoot 'logs/queue'
[void][IO.Directory]::CreateDirectory($script:Queue)
$script:HostName=$DeviceName;$script:LocalKey='';$script:RemoteKey=''
$script:LogFile=Join-Path $DataRoot 'logs/delivery.jsonl'
$script:Connection=[pscustomobject]@{sshExecutable=$Transport;arguments=@('fixture.invalid')}
Send-DiskLogs
""")
        clients={name:root/name for name in ('client-a','client-b')}
        for name,home in clients.items():
            logs=home/'logs';logs.mkdir(parents=True)
            for i in range(3):(logs/f'session-{i}.jsonl').write_text(json.dumps(dict(stage='test',message=f'{name}-{i}'))+'\n')
        def count():return counter.read_text().count('1') if counter.exists() else 0
        def send(name):
            result=subprocess.run([str(pwsh),'-NoProfile','-File',str(driver),'-Library',str(HERE/'RemoteDisk.ps1'),'-DataRoot',str(clients[name]),'-Transport',str(shim),'-DeviceName',name],capture_output=True,text=True,timeout=25)
            m.require(result.returncode==0,'log cycle failed: '+result.stderr[-1500:])
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=2) as pool:list(pool.map(send,clients))
        m.require(count()==2,'expected one SSH for three changed files per computer')
        remote=server/'.local/share/remote-disk/logs'
        for name,home in clients.items():
            for file in (home/'logs').glob('*.jsonl'):m.require((remote/name/file.name).read_bytes()==file.read_bytes(),'multi-host log contents changed')
            m.require(not (home/'logs/delivery.jsonl').exists(),'successful delivery wrote its own journal')
            m.require(not list((home/'logs/queue').glob('*')),'acknowledged batch remains queued')
        before=count();send('client-a');send('client-b')
        m.require(count()==before,'unchanged persisted sessions caused SSH after process restart')
        local=clients['client-a']/'logs/session-0.jsonl'
        stamp=local.stat().st_mtime
        local.write_text(local.read_text().replace('client-a-0','client-a-X'))
        os.utime(local,(stamp,stamp+1));send('client-a')
        m.require(count()==before+1 and (remote/'client-a'/local.name).read_bytes()==local.read_bytes(),'same-size changed file not delivered')
        os.utime(local,(stamp,stamp+2));send('client-a')
        m.require(count()==before+2,'mtime-only modification not delivered')
        # Interrupted delivery is durable, and a later source write cannot alter its snapshot.
        local.write_text('{"stage":"test","message":"offline snapshot"}\n');fail.touch();send('client-a')
        pending=clients['client-a']/'logs/queue/pending.json'
        snapshot=pending.read_bytes();send('client-a')
        m.require(pending.read_bytes()==snapshot,'retry changed the pending snapshot')
        journal=clients['client-a']/'logs/delivery.jsonl'
        m.require('do-not-leak' not in journal.read_text(),'SSH failure leaked named secret')
        local.write_text('{"stage":"test","message":"written while offline"}\n')
        fail.unlink();send('client-a')
        m.require(not pending.exists() and 'offline snapshot' in (remote/'client-a'/local.name).read_text(),'retry not acknowledged atomically')
        send('client-a');send('client-a');before=count();send('client-a')
        m.require(count()==before and (remote/'client-a'/local.name).read_bytes()==local.read_bytes(),'successful delivery self-feeds, or concurrent source edit lost')
        # Cleanup applies to old/start-only/empty sessions on both sides without touching other hosts.
        for base in (clients['client-a']/'logs',remote/'client-a'):
            (base/'session-empty.jsonl').write_text('')
            (base/'session-start.jsonl').write_text('{"stage":"start"}\n')
            old=base/'session-old.jsonl';old.write_text('{"stage":"test"}\n');os.utime(old,(time.time()-8*86400,)*2)
        local.write_text('{"stage":"test","message":"retention trigger"}\n');send('client-a')
        for base in (clients['client-a']/'logs',remote/'client-a'):
            m.require(all(not (base/f'session-{kind}.jsonl').exists() for kind in ('empty','start','old')),'retention left old/empty session')
        m.require((remote/'client-b/session-0.jsonl').exists(),'retention removed another computer journal')
        print('PASS real journal transport/receiver: two computers, one SSH batches changes, persisted no-op after restart, size/mtime detection, durable failed retry/ack, no success feedback or secret, seven-day/empty cleanup on both sides',flush=True)

def main():
    log_delivery_checks()
    m.LABELS[2]='K2 edits/deletions both directions; no version directories'
    m.LABELS[3]='K3 server resolves both conflict winners without copies or extra directories'
    policy=json.loads(Path(sys.argv[2]).read_text(encoding='utf-8-sig'))
    with tempfile.TemporaryDirectory(prefix='remote-disk-test-') as temp:
        fixture=DiskFixture.__new__(DiskFixture);fixture.sides=[]
        try:
            fixture.__init__(Path(temp),Path(sys.argv[1]),policy)
            for n in (5,1,2,3,4,6,7):
                getattr(fixture,'k'+str(n))();print('PASS '+m.LABELS[n],flush=True)
        finally:fixture.close()
    with tempfile.TemporaryDirectory(prefix='remote-disk-multi-') as temp:
        fixture=MultiFixture.__new__(MultiFixture);fixture.sides=[];fixture.proxies=[]
        try:
            fixture.__init__(Path(temp),Path(sys.argv[1]),policy)
            fixture.metadata_checks();fixture.transfer_checks();fixture.upload_check();fixture.worktree_checks();fixture.compatibility_checks();fixture.offline_check()
        finally:fixture.close()
if __name__=='__main__':main()
