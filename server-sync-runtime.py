#!/usr/bin/env python3
"""Own Syncthing state only. No existing credentials or project contents read."""
import argparse,importlib.util,json,os,re,subprocess,sys,urllib.request,xml.etree.ElementTree as ET
from pathlib import Path

def main():
    p=argparse.ArgumentParser();p.add_argument('action',choices=['identity','configure','start','resume','stop','health','scan']);p.add_argument('--state',required=True);p.add_argument('--binary',required=True);p.add_argument('--project',required=True);p.add_argument('--host',required=True);p.add_argument('--workspace',required=True);p.add_argument('--manifest');p.add_argument('--peer');p.add_argument('--listen',type=int,required=True);p.add_argument('--tunnel',type=int,required=True);p.add_argument('--gui',type=int,required=True)
    a=p.parse_args()
    if os.getuid()==0:raise ValueError('Nonroot required')
    for value in (a.project,a.host):
        if not re.fullmatch('[a-z0-9][a-z0-9_-]{0,63}',value):raise ValueError('Invalid identity')
    if any(not 1024<=x<=65535 for x in (a.listen,a.tunnel,a.gui)) or len({a.listen,a.tunnel,a.gui})!=3:raise ValueError('Invalid ports')
    state=Path(a.state).absolute()
    if any(x.is_symlink() for x in (state,*state.parents)):raise ValueError('Symlink state')
    state.mkdir(mode=0o700,parents=True,exist_ok=True);os.chmod(state,0o700)
    config=state/'config.xml'
    if not config.exists():subprocess.run([a.binary,'generate','--home',str(state)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    tree=ET.parse(config);root=tree.getroot();local=root.find('device').attrib['id']
    if a.action=='identity':print(json.dumps({'deviceId':local}));return
    if a.action=='configure':
        if not re.fullmatch('[A-Z2-7-]{63}',a.peer or ''):raise ValueError('Peer ID required')
        marker=state/'configured.json'
        if marker.exists():raise ValueError('Already configured; refusing reset')
        manifest=json.loads(Path(a.manifest).read_text('utf-8-sig'))
        if manifest['projectId']!=a.project or manifest['hostId']!=a.host:raise ValueError('Manifest identity mismatch')
        workspace=Path(a.workspace).absolute()
        if not workspace.is_dir() or any(x.is_symlink() for x in (workspace,*workspace.parents)):raise ValueError('Invalid seeded workspace')
        def put(parent,name,value):
            node=parent.find(name)
            if node is None:node=ET.SubElement(parent,name)
            node.text=str(value)
        for folder in list(root.findall('folder')):root.remove(folder)
        options=root.find('options')
        for name in ('globalAnnounceEnabled','localAnnounceEnabled','relaysEnabled','natEnabled','startBrowser','crashReportingEnabled'):put(options,name,'false')
        put(options,'autoUpgradeIntervalH','0');put(options,'urAccepted','-1');put(options,'listenAddress',f'tcp://127.0.0.1:{a.listen}');put(root.find('gui'),'address',f'127.0.0.1:{a.gui}')
        peer=ET.SubElement(root,'device',{'id':a.peer,'name':'approved-peer'});put(peer,'address',f'tcp://127.0.0.1:{a.tunnel}');put(peer,'autoAcceptFolders','false')
        folder=ET.SubElement(root,'folder',{'id':'ra-'+a.project,'path':str(workspace),'type':'sendonly','paused':'true','rescanIntervalS':'60','fsWatcherEnabled':'true'})
        for value in (local,a.peer):ET.SubElement(folder,'device',{'id':value})
        # Share seed/snapshot policy; Git metadata stays outside the source tree.
        spec=importlib.util.spec_from_file_location('sync_policy',Path(__file__).with_name('server-sync.py'))
        policy=importlib.util.module_from_spec(spec);spec.loader.exec_module(policy)
        policy.policy(manifest)
        ignores=['(?i).env*','(?i)env.example','(?i)*credential*','(?i)*token*','(?i)*secret*','(?i)*private*','.git','.tools','.ssh','.codex','.claude','node_modules','vendor','.gradle','.next','build','dist','storage','cache','logs','uploads','local.properties','(?i)*.pem','(?i)*.key','(?i)*.keystore','(?i)*.jks','(?i)*.p8','(?i)*.p12','(?i)google-services*.json','(?i)GoogleService-Info.plist','auth.json','config.php']
        for file in manifest['files']:
            path=file['path']
            policy.safe_relative(path,manifest['allowedRoots']);policy.check_parents(workspace/path)
            if policy.nested_repository(workspace,workspace/path):raise ValueError('Nested Git repository forbidden')
            ignores.append('!/'+path)
        if manifest.get('scopeMode')=='git':policy.git_scope(manifest,a.manifest,workspace)
        ignores.append('*');policy.check_parents(workspace/'.stignore');(workspace/'.stignore').write_text('\n'.join(ignores)+'\n','utf-8')
        tree.write(config,encoding='utf-8',xml_declaration=True);os.chmod(config,0o600)
        marker.write_text(json.dumps({'projectId':a.project,'hostId':a.host,'peer':a.peer}),'utf-8')
        print(json.dumps({'ok':True,'deviceId':local,'paused':True}));return
    if not (state/'configured.json').exists():raise ValueError('Not configured')
    if a.action=='start':os.execv(a.binary,[a.binary,'serve','--home',str(state),'--no-browser','--no-restart','--no-upgrade'])
    key=root.find('gui/apikey').text
    def request(route,method='GET',body=None):
        data=None if body is None else json.dumps(body).encode()
        req=urllib.request.Request(f'http://127.0.0.1:{a.gui}/rest/'+route,data=data,method=method,headers={'X-API-Key':key,'Content-Type':'application/json'})
        with urllib.request.urlopen(req,timeout=10) as response:
            raw=response.read();return json.loads(raw) if raw else {}
    if a.action=='resume':request('config/folders/ra-'+a.project,'PATCH',{'paused':False});print('{"ok":true}')
    elif a.action=='stop':request('system/shutdown','POST',{});print('{"ok":true}')
    elif a.action=='scan':request('db/scan?folder=ra-'+a.project,'POST');print('{"ok":true}')
    else:
        status=request('db/status?folder=ra-'+a.project);connections=request('system/connections')
        print(json.dumps({'connected':connections['connections'].get(a.peer,{}).get('connected',False),'state':status['state'],'needTotalItems':status['needTotalItems'],'pullErrors':status['pullErrors'],'sequence':status['sequence']}))
if __name__=='__main__':
    try:main()
    except Exception:print('{"ok":false,"reason":"Sync runtime operation failed; inspect nonsecret state and ports"}');sys.exit(1)
