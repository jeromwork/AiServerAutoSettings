#!/usr/bin/env python3
"""Actual Syncthing peers + the production PS selection module; no live user state."""
import importlib.util
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import time
import xml.etree.ElementTree as E
spec=importlib.util.spec_from_file_location('disk_tests',Path(__file__).with_name('test-disk.py'))
t=importlib.util.module_from_spec(spec);spec.loader.exec_module(t)
ps=str(Path.home()/'.cache/pwsh-test/pwsh')
checks=0

def check(value,reason):
    global checks
    t.require(value,reason);checks+=1

try:
    with tempfile.TemporaryDirectory(prefix='disk-selective-') as temp:
        root=Path(temp)
        archive=Path('/tmp/remote-disk-release-zP80am/syncthing-linux-amd64-v2.1.7.tar.gz')
        for i in range(2):
            home=root/str(i);home.mkdir()
            side=dict(home=home,env=dict(os.environ,HOME=str(home)),state=home/'.local/share/remote-disk',folder=home/'Disk/project')
            t.SIDES.append(side)
            result=t.run(['bash',str(t.HERE/'server-disk.sh'),'bootstrap','--archive',str(archive)],side['env'])
            side.update(json.loads(result.stdout))
            for name in ('server-disk.sh','stignore.txt','stignore-previous.sha256'):shutil.copyfile(t.HERE/name,side['state']/name)
            config=E.parse(side['state']/'config.xml')
            side.update(gui=config.findtext('gui/address').rsplit(':',1)[1],key=config.findtext('gui/apikey'))
        a,b=t.SIDES
        for side,peer in ((a,b),(b,a)):
            t.server(side,'add-device',dict(deviceId=peer['deviceId'],addresses=[f"tcp://127.0.0.1:{peer['listen']}"]))
            side['folder'].mkdir(parents=True)
            side['id']=t.server(side,'attach',dict(name='project',deviceId=peer['deviceId']))['id']
        local=root/'appdata/RemoteDisk';(local/'state').mkdir(parents=True)
        (local/'state/config.xml').write_bytes((b['state']/'config.xml').read_bytes())
        env=dict(os.environ,LOCALAPPDATA=str(local.parent),HOME=str(b['home']))
        common=str(t.HERE/'Disk.Common.ps1').replace("'","''")
        helper=str(t.HERE/'server-disk.sh').replace("'","''")
        # Real SSH endpoint is replaced by a local process with the disposable server HOME.
        source=f'''$ErrorActionPreference='Stop'
. '{common}'
$script:DiskHome='{local}'
Read-DiskState
function Invoke-DiskSsh($Command,[switch]$Direct,[string]$InputText='',[string]$OutputFile='') {{
    $old=$env:HOME
    try {{
        $env:HOME='{a['home']}'
        Invoke-DiskProcess 'bash' @('-c',$Command) -InputText $InputText
    }}finally{{$env:HOME=$old}}
}}
$folder=Invoke-DiskApi 'config/folders/{b['id']}'
Set-ProjectSelection $folder $Chosen
'''
        script=root/'apply.ps1'
        def apply(paths,ok=True):
            script.write_text('\ufeffparam([string[]]$Chosen)\n'+source)
            command="& '"+str(script)+"' -Chosen @("+','.join("'"+p.replace("'","''")+"'" for p in paths)+")"
            return t.run([ps,'-NoProfile','-NonInteractive','-Command',command],env,ok=ok,limit=30)
        # Apply partial selection before files exist locally.
        apply(['src/deep','one.txt','x[a]{b}.txt'])
        values={'src/deep/chosen.txt':'selected','src/sibling.txt':'only-server','other.txt':'only-server','one.txt':'one','x[a]{b}.txt':'literal','src/deep/.env':'secret','src/deep/node_modules/a.js':'generated'}
        for name,value in values.items():
            f=a['folder']/name;f.parent.mkdir(parents=True,exist_ok=True);f.write_text(value)
        t.api(a,'db/scan?folder='+a['id'],'POST')
        t.wait(lambda: all((b['folder']/n).exists() for n in ('src/deep/chosen.txt','one.txt','x[a]{b}.txt')) and t.settled(),'partial transfer')
        check((b['folder']/'src').is_dir() and not (b['folder']/'src/sibling.txt').exists(),'selected child preserves only parent, no siblings')
        check(not (b['folder']/'other.txt').exists(),'unselected root excluded')
        check(not (b['folder']/'src/deep/.env').exists() and not (b['folder']/'src/deep/node_modules').exists(),'mandatory exclusions before includes')
        check((b['folder']/'x[a]{b}.txt').read_text()=='literal','literal glob chars in real engine')
        tree=json.loads(t.run(['bash',str(t.HERE/'server-disk.sh'),'tree','project/src/deep'],a['env']).stdout)
        check(any(x['path']=='project/src/deep/chosen.txt' for x in tree['entries']) and not any(x['path'].endswith('.env') for x in tree['entries']),'SSH tree excludes secret entries')
        # One-level inventory must still preserve an unchecked local-only file on Apply.
        (b['folder']/'only-here.txt').write_text('never sent')
        apply(['src/deep','one.txt','x[a]{b}.txt'])
        check((b['folder']/'only-here.txt').read_text()=='never sent','remote missing receipt retains unchecked local-only content')
        check(not (a['folder']/'only-here.txt').exists(),'unchecked local-only file stays ignored')
        # Disable the peer and create a newer local version: absolutely no deletion.
        t.api(b,'config/devices/'+a['deviceId'],'PATCH',dict(paused=True))
        t.wait(lambda:not t.api(b,'system/connections')['connections'].get(a['deviceId'],{}).get('connected'),'disconnected')
        (b['folder']/'one.txt').write_text('new local data')
        t.api(b,'db/scan?folder='+b['id'],'POST')
        refused=apply(['src/deep'],ok=False)
        check(refused.returncode!=0 and (b['folder']/'one.txt').read_text()=='new local data','unsynced local edit retained')
        check((a['folder']/'one.txt').read_text()=='one','server copy unchanged by refused deselection')
        t.api(b,'config/devices/'+a['deviceId'],'PATCH',dict(paused=False))
        t.wait(lambda:(a['folder']/'one.txt').read_text()=='new local data' and t.settled(),'new local version reached server')
        # Fresh completion can lag folder idle, so wait explicitly before deletion.
        t.wait(lambda:t.api(a,'db/completion?folder='+a['id']+'&device='+b['deviceId'])['completion']==100,'remote completion')
        apply(['src/deep'])
        check(not (b['folder']/'one.txt').exists() and not (b['folder']/'x[a]{b}.txt').exists(),'verified deselection frees local files')
        t.api(b,'db/scan?folder='+b['id'],'POST')
        t.wait(t.settled,'post-deselection scan')
        check((a['folder']/'one.txt').read_text()=='new local data' and (a['folder']/'x[a]{b}.txt').exists(),'deletion never propagated to server')
        apply(['src/deep'])
        check((b['folder']/'src/deep/chosen.txt').exists(),'repeat selection safe')
        apply(['.'])
        t.wait(lambda:(b['folder']/'other.txt').exists() and (b['folder']/'one.txt').exists(),'reselect download')
        check((b['folder']/'one.txt').read_text()=='new local data','reselection restores current server version')
        print(f'OK: {checks} selective checks with two real Syncthing 2.1.7 peers')
finally:
    t.stop_engines()
