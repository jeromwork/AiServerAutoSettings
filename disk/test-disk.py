#!/usr/bin/env python3
"""Isolated real-engine acceptance; uses production PS policy and server bootstrap."""
import importlib.util,json,os,subprocess,tempfile,time,sys
from pathlib import Path
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
            self.api(s,'config/devices/'+s['peer'],'PUT',dict(deviceID=s['peer'],addresses=[f"tcp://127.0.0.1:{peer['listen']}"],autoAcceptFolders=False))
            f=dict(policy['folder']);f.update(id='ra-'+m.PROJECT,path=str(s['workspace']),devices=[dict(deviceID=s['identity']),dict(deviceID=s['peer'])])
            self.api(s,'config/folders/'+f['id'],'PUT',f)
            # Same as RemoteDisk: local file or remote REST while paused.
            self.api(s,'db/ignores?folder='+f['id'],'POST',dict(ignore=policy['ignores']))
            got=self.api(s,'config/folders/'+f['id'])
            m.require(got['paused'] and got['versioning']['params']=={'keep':'2147483647','cleanoutDays':'30'},'paused retention')
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
    def k7(self):
        a,b=self.sides
        self.wait(lambda:self.call(a,'health')['connected'],'before disconnect')
        self.call(b,'stop');time.sleep(1)
        self.wait(lambda:not self.call(a,'health')['connected'],'offline')
        (a['workspace']/'recovery-a.txt').write_text('A');(b['workspace']/'recovery-b.txt').write_text('B')
        self.start(b)
        self.wait(lambda:self.both('recovery-a.txt','A') and self.both('recovery-b.txt','B') and self.call(a,'health')['connected'],'restart recovery')
    def close(self):
        for s in self.sides:
            try:self.call(s,'stop')
            except Exception:pass
            # Only PIDs in our temporary HOME, with /proc ownership check.
            pid=int((s['state']/'syncthing.pid').read_text())
            try:
                if str(s['state']).encode() in Path(f'/proc/{pid}/cmdline').read_bytes():os.kill(pid,15)
            except (FileNotFoundError,ProcessLookupError):pass

def main():
    policy=json.loads(Path(sys.argv[2]).read_text(encoding='utf-8-sig'))
    with tempfile.TemporaryDirectory(prefix='remote-disk-test-') as temp:
        fixture=DiskFixture.__new__(DiskFixture);fixture.sides=[]
        try:
            fixture.__init__(Path(temp),Path(sys.argv[1]),policy)
            for n in (5,1,2,3,4,6,7):
                getattr(fixture,'k'+str(n))();print('PASS '+m.LABELS[n],flush=True)
        finally:fixture.close()
if __name__=='__main__':main()
