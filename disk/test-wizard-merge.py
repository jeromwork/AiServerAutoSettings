#!/usr/bin/env python3
"""First merge of two populated folders using real Syncthing, no Windows or live SSH."""
import importlib.util,json,os,shutil,tempfile,time,xml.etree.ElementTree as E
from pathlib import Path
spec=importlib.util.spec_from_file_location('disk_stand',Path(__file__).with_name('test-disk.py'))
t=importlib.util.module_from_spec(spec);spec.loader.exec_module(t)
archive=Path('/tmp/remote-disk-release-zP80am/syncthing-linux-amd64-v2.1.7.tar.gz')
checks=0
def check(value,label):
    global checks
    t.require(value,label);checks+=1
try:
    with tempfile.TemporaryDirectory(prefix='wizard-initial-merge-') as tmp:
        root=Path(tmp)
        for i in range(2):
            home=root/str(i);home.mkdir()
            side=dict(home=home,env=dict(os.environ,HOME=str(home)),state=home/'.local/share/remote-disk',folder=home/'Disk/project')
            t.SIDES.append(side)
            side.update(json.loads(t.run(['bash',str(t.HERE/'server-disk.sh'),'bootstrap','--archive',str(archive)],side['env']).stdout))
            for name in ('server-disk.sh','stignore.txt','legacy-ignores.sha256'):shutil.copyfile(t.HERE/name,side['state']/name)
            xml=E.parse(side['state']/'config.xml');side.update(gui=xml.findtext('gui/address').rsplit(':',1)[1],key=xml.findtext('gui/apikey'))
            side['folder'].mkdir(parents=True)
            (side['folder']/'same-name.txt').write_text('initial-server' if i==0 else 'initial-local')
            stamp=time.time()-60+i*5;os.utime(side['folder']/'same-name.txt',(stamp,stamp))
            (side['folder']/('only-server.txt' if i==0 else 'only-local.txt')).write_text('server' if i==0 else 'local')
            (side['folder']/'identical.txt').write_text('same bytes')
            (side['folder']/'.env').write_text('private-'+str(i))
        a,b=t.SIDES
        for side,peer in ((a,b),(b,a)):
            t.server(side,'add-device',dict(deviceId=peer['deviceId'],addresses=[f"tcp://127.0.0.1:{peer['listen']}"]))
            t.api(side,'config/devices/'+peer['deviceId'],'PATCH',dict(paused=True))
            side['id']=t.server(side,'attach',dict(name='project',deviceId=peer['deviceId'],localHasFiles=True,merge=True))['id']
            t.api(side,'db/scan?folder='+side['id'],'POST')
        t.wait(lambda:all(t.api(s,'db/status?folder='+s['id'])['localFiles']==3 for s in t.SIDES),'initial populated scans')
        for side,peer in ((a,b),(b,a)):t.api(side,'config/devices/'+peer['deviceId'],'PATCH',dict(paused=False))
        def merged():
            for side in t.SIDES:
                files=[side['folder']/'same-name.txt',*side['folder'].glob('same-name.sync-conflict-*')]
                if {p.read_text() for p in files if p.exists()}!={'initial-server','initial-local'}:return False
                if not all((side['folder']/n).exists() for n in ('only-server.txt','only-local.txt')):return False
            return t.settled()
        t.wait(merged,'first merge keeps initial conflicting versions')
        check(merged(),'both original versions retained and propagated')
        check(all((s['folder']/'identical.txt').read_text()=='same bytes' for s in t.SIDES),'identical initial file reused')
        check(all((s['folder']/'only-server.txt').read_text()=='server' and (s['folder']/'only-local.txt').read_text()=='local' for s in t.SIDES),'union transferred both directions')
        check(all((s['folder']/'.env').read_text()=='private-'+str(i) for i,s in enumerate(t.SIDES)),'secrets remain local')
        check(all(t.api(s,'config/folders/'+s['id'])['maxConflicts']==-1 for s in t.SIDES),'conflict copies have no automatic count limit')
        print(f'OK: {checks} initial merge checks with two real Syncthing 2.1.7 peers')
finally:t.stop_engines()
