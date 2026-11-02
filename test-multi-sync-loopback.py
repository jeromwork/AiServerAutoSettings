#!/usr/bin/env python3
"""Linux-only real pinned Syncthing: two subscriptions, one synthetic source.

Receivers run Linux binaries, so this does not claim Windows/SSH/model acceptance.
All listeners are loopback; no existing Syncthing configuration is used.
"""
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

HERE=Path(__file__).resolve().parent


def run(*values):
    result=subprocess.run([str(x) for x in values],check=True,capture_output=True,text=True,timeout=60)
    return json.loads(result.stdout)


def main():
    if os.name!='posix' or os.getuid()==0:raise ValueError('Run on Linux as a nonroot test user')
    workers=[]
    with tempfile.TemporaryDirectory(prefix='ra-multi-sync-') as temporary:
        root=Path(temporary);base=root/'projects';base.mkdir()
        binary=root/'bin/syncthing'
        subprocess.run(['bash',str(HERE/'server-install-sync.sh'),str(binary.parent)],check=True,timeout=120)
        sockets=[];ports=[]
        for _ in range(8):
            sock=socket.socket();sock.bind(('127.0.0.1',0));sockets.append(sock);ports.append(sock.getsockname()[1])
        for sock in sockets:sock.close()
        source=b'first server seed'
        manifest={'schema':1,'projectId':'p-shared','hostId':'home','scopeMode':'folder','allowedRoots':['.'],'files':[{'path':'app.js','size':len(source),'sha256':hashlib.sha256(source).hexdigest()}]}
        for host in ('home','laptop'):(root/host).mkdir()
        first=root/'home/seed-manifest.json';first.write_text(json.dumps(manifest),'utf-8')
        archive=root/'home/seed.zip'
        with zipfile.ZipFile(archive,'w') as stream:stream.writestr('app.js',source)
        def sync(action,host,**kwargs):
            args=[sys.executable,HERE/'server-sync.py',action,'--base',base,'--project','p-shared','--host',host,'--manifest',root/host/'seed-manifest.json']
            for key,value in kwargs.items():
                args.append('--'+key.replace('_','-'))
                if value is not True:args.append(value)
            return run(*args)
        sync('seed','home',archive=archive)
        workspace=base/'p-shared'
        def runtime(worker,action,**kwargs):
            args=[sys.executable,HERE/'server-sync-runtime.py',action,'--state',worker['state'],'--binary',binary,'--project','p-shared','--host',worker['host'],'--workspace',worker['workspace'],'--listen',str(worker['listen']),'--tunnel',str(worker['peerPort']),'--gui',str(worker['gui'])]
            for key,value in kwargs.items():args+=['--'+key,str(value)]
            return args
        def api(worker,route,method='GET',body=None):
            key=ET.parse(worker['state']/'config.xml').getroot().find('gui/apikey').text
            request=urllib.request.Request('http://127.0.0.1:'+str(worker['gui'])+'/rest/'+route,data=None if body is None else json.dumps(body).encode(),method=method,headers={'X-API-Key':key,'Content-Type':'application/json'})
            with urllib.request.urlopen(request,timeout=3) as response:
                raw=response.read();return json.loads(raw) if raw else {}
        def scan():
            for host in ('home','laptop'):
                sync('snapshot',host,output=root/host/'snapshot.json',refresh_ignores=True)
            for worker in workers:api(worker,'db/scan?folder=ra-p-shared','POST')
        def await_state(predicate):
            deadline=time.monotonic()+30
            while time.monotonic()<deadline:
                if predicate():return
                if any(worker['process'].poll() is not None for worker in workers):raise AssertionError('Fixture worker exited')
                time.sleep(.15)
            raise AssertionError('Loopback sync state did not converge')
        try:
            for index,host in enumerate(('home','laptop')):
                sender={'state':root/host,'host':host,'workspace':workspace,'listen':ports[index*4],'peerPort':ports[index*4+2],'gui':ports[index*4+1]}
                if host=='laptop':
                    (workspace/'app.js').write_text('server newer before attach','utf-8')
                    sync('attach',host);sync('attach',host)
                replica=root/(host+'-replica');replica.mkdir()
                receiver={'state':root/(host+'-receiver'),'host':host,'workspace':replica,'listen':ports[index*4+2],'peerPort':ports[index*4],'gui':ports[index*4+3]}
                sid=run(*runtime(sender,'identity'))['deviceId'];rid=run(*runtime(receiver,'identity'))['deviceId']
                run(*runtime(sender,'configure',manifest=root/host/'seed-manifest.json',peer=rid))
                sync('register',host)
                run(*runtime(receiver,'configure',manifest=root/host/'seed-manifest.json',peer=sid))
                tree=ET.parse(receiver['state']/'config.xml');tree.getroot().find('folder').set('type','receiveonly');tree.write(receiver['state']/'config.xml')
                (replica/'.stignore').write_text('(?i).env*\nnode_modules\n!/**\n*\n','utf-8')
                for worker in (sender,receiver):
                    worker['log']=(root/(host+('-send.log' if worker is sender else '-receive.log'))).open('wb')
                    worker['process']=subprocess.Popen([str(x) for x in runtime(worker,'start')],stdout=worker['log'],stderr=subprocess.STDOUT)
                    workers.append(worker)
                    deadline=time.monotonic()+10
                    while True:
                        try:api(worker,'config/folders/ra-p-shared','PATCH',{'paused':False});break
                        except Exception:
                            if time.monotonic()>deadline:raise
                            time.sleep(.1)
            replicas=[root/(host+'-replica') for host in ('home','laptop')]
            def both_text(name,text):
                return all((replica/name).is_file() and (replica/name).read_text('utf-8')==text for replica in replicas)
            scan();await_state(lambda:both_text('app.js','server newer before attach'))
            route=workspace/'routes/[id].tsx';route.parent.mkdir();route.write_text('literal bracket route','utf-8')
            scan();await_state(lambda:both_text('routes/[id].tsx','literal bracket route'))
            route.write_text('updated bracket route','utf-8');scan();await_state(lambda:both_text('routes/[id].tsx','updated bracket route'))
            route.unlink();scan();await_state(lambda:all(not (replica/'routes/[id].tsx').exists() for replica in replicas))
            (workspace/'added.ts').write_text('server addition','utf-8');(workspace/'.env').write_text('synthetic excluded fixture','utf-8')
            scan();await_state(lambda:both_text('added.ts','server addition'))
            assert all(not (replica/'.env').exists() for replica in replicas)
            (workspace/'app.js').unlink();scan();await_state(lambda:all(not (replica/'app.js').exists() for replica in replicas))
            assert archive.is_file() and not (root/'laptop/seed.zip').exists()
            print('PASS: real pinned Syncthing, two send-only subscriptions sharing one source, two receive-only Linux replicas, attach/rerun, newer server preservation, additions/deletions and secret exclusion. Windows/SSH/model acceptance remains pending.')
        finally:
            for worker in workers:
                try:api(worker,'system/shutdown','POST',{})
                except Exception:pass
            for worker in workers:
                try:worker['process'].wait(timeout=5)
                except subprocess.TimeoutExpired:worker['process'].kill();worker['process'].wait(timeout=5)
                worker['log'].close()


if __name__=='__main__':main()
