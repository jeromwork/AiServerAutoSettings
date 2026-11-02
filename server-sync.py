#!/usr/bin/env python3
"""Nonroot sync operations; caller supplies only approved seed/source artifacts.
Never reads existing agent authentication. Run from an operator-owned deployment.
"""
import argparse, hashlib, json, os, re, shutil, stat, subprocess, sys, tempfile, time, zipfile
from pathlib import Path, PurePosixPath

DENIED = re.compile(r'(?i)^(\.env.*|env\.example|\.npmrc|\.pypirc|\.netrc|auth\.json|.*credential.*|.*token.*|.*secret.*|.*private.*|id_.*|\.git|\.tools|\.?ssh|\.codex|\.claude|node_modules|vendor|deps|dependencies|\.gradle|\.next|\.cache|\.stversions|\.stfolder|\.stignore|build|dist|target|obj|bin|\.dart_tool|\.nuxt|\.output|\.turbo|\.cxx|coverage|logs?|cache|caches|db|databases?|backups?|.*backup.*|.*dump.*|uploads?|storage|android-sdk|\.idea|\.vscode|local\.properties|google-services.*\.json|GoogleService-Info\.plist|config\.php)$')
DENIED_EXT = re.compile(r'(?i)\.(pem|key|keystore|jks|p8|p12|pfx|sqlite3?|db|db3|bak|backup|dump|log|zip|tar|gz|exe|dll|so|bin)$')
ALLOWED_EXT = re.compile(r'(?i)\.(php|js|mjs|cjs|jsx|ts|mts|cts|tsx|vue|json|lock|yaml|yml|xml|gradle|kts|kt|java|dart|css|scss|sass|less|html|md|txt|sql|graphql|gql|sh|ps1|bat|cmd|properties|toml|ini|png|jpg|jpeg|gif|webp|svg|woff2?|ttf)$')
GIT_SOURCE_EXT = re.compile(r'(?i)\.(py|go|rs|c|h|cpp|hpp|cs|rb|swift)$')
ALLOWED_NAMES = {'artisan','gradlew','Dockerfile','Makefile','.editorconfig','.gitattributes','.gitignore','.node-version'}

def ident(value):
    if not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,63}', value):
        raise ValueError('Invalid project/host ID')
    return value

def safe_relative(value, roots):
    if not isinstance(value,str):raise ValueError('Invalid manifest path')
    p = PurePosixPath(value)
    if any(c in value for c in '*?{}!#|\n\r\\\0') or p.is_absolute() or not p.parts or p.as_posix()!=value or any(x in ('', '.', '..') or ':' in x or DENIED.match(x) for x in p.parts) or DENIED_EXT.search(p.name):
        raise ValueError('Forbidden manifest path')
    if not any(r == '.' or value == r or value.startswith(r.rstrip('/') + '/') for r in roots):
        raise ValueError('Path outside allowlist')
    return p

def escape_ignore_path(value):
    """Literal route filenames such as [id].tsx are not glob character sets."""
    escape='|' if os.name=='nt' else '\\'
    return ''.join(escape+c if c in '[]' else c for c in value)

def unescape_ignore_path(value):
    escape='|' if os.name=='nt' else '\\'
    result=[];position=0
    while position<len(value):
        char=value[position]
        if char==escape:
            position+=1
            if position>=len(value) or value[position] not in '[]':raise ValueError('Unsafe ignore escape')
            char=value[position]
        elif char in '[]':raise ValueError('Wildcard include path forbidden')
        result.append(char);position+=1
    return ''.join(result)

def policy(manifest):
    mode=manifest.get('scopeMode','roots')
    if mode not in ('roots','git','folder'):raise ValueError('Unknown scope mode')
    roots=manifest['allowedRoots']
    if not isinstance(roots,list) or not roots or len(set(roots))!=len(roots):raise ValueError('Invalid allowed roots')
    if mode in ('git','folder') and roots!=['.']:raise ValueError('Whole-root scope requires one workspace root')
    if mode=='git':
        paths=manifest.get('gitPaths')
        if not isinstance(paths,list) or not paths or len(set(paths))!=len(paths):raise ValueError('Invalid Git paths')
        for path in paths:safe_relative(path,roots)
        if 'files' in manifest and set(paths)!={f['path'] for f in manifest['files']}:raise ValueError('Git seed paths mismatch')
    elif mode=='folder':
        for file in manifest.get('files',[]):
            safe_relative(file['path'],roots)
            if not source_name(file['path'],True):raise ValueError('Folder scope requires safe source files')
    else:
        for value in roots:safe_relative(value,roots)
    return mode,roots

def source_name(value,git_mode=False):
    return bool(ALLOWED_EXT.search(value) or (git_mode and GIT_SOURCE_EXT.search(value)) or PurePosixPath(value).name in ALLOWED_NAMES)

def git_command(directory,root,*arguments,input=None):
    # Ambient Git config, hooks, fsmonitor and external excludes cannot change scope.
    environment={k:v for k,v in os.environ.items() if not k.startswith('GIT_')}
    environment.update(GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL=os.devnull)
    command=['git','-c','core.hooksPath='+os.devnull,'-c','core.fsmonitor=false','-c','core.excludesFile='+os.devnull,'--git-dir='+str(directory)]
    if arguments[0]!='init':command.append('--work-tree='+str(root))
    command.extend(arguments)
    result=subprocess.run(command,input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=environment)
    if result.returncode not in (0,1) or (result.returncode==1 and arguments[0]!='check-ignore'):raise ValueError('Git scope operation failed')
    return result.stdout

def git_scope(manifest,manifest_path,root):
    if not shutil.which('git'):raise ValueError('Git mode requires Git; install it before connecting')
    directory=Path(manifest_path).absolute().parent/('.git-scope-'+ident(manifest['projectId'])+'-'+ident(manifest['hostId']))
    check_parents(directory)
    if directory==root or root in directory.parents:raise ValueError('Git metadata must be outside workspace')
    # The index contains only public seed path names and an empty blob, never contents.
    if not directory.exists():
        directory.mkdir(mode=0o700)
        try:
            git_command(directory,root,'init','--bare','--template=',str(directory))
            blob=git_command(directory,root,'hash-object','-w','--stdin',input=b'').decode().strip()
            records=b''.join(('100644 '+blob+'\t'+path).encode('utf-8')+b'\0' for path in manifest['gitPaths'])
            git_command(directory,root,'update-index','-z','--index-info',input=records)
        except Exception:
            raise ValueError('Git scope initialization failed; inspect new metadata directory')
    for base,dirs,names in os.walk(directory,followlinks=False):
        for name in dirs+names:
            if (Path(base)/name).is_symlink():raise ValueError('Symlink Git metadata forbidden')
    tracked=set(git_command(directory,root,'ls-files','--cached','-z').decode('utf-8').rstrip('\0').split('\0'))
    if tracked!=set(manifest['gitPaths']):raise ValueError('Git scope index mismatch')
    return directory,tracked

def nested_repository(root,path):
    return any(os.path.lexists(parent/'.git') for parent in [path.parent,*path.parent.parents] if parent==root or root in parent.parents)

def scope_files(root,manifest,manifest_path):
    mode,roots=policy(manifest)
    whole_root=mode in ('git','folder')
    if whole_root and os.path.lexists(root/'.git'):raise ValueError('Workspace Git metadata forbidden')
    directory,tracked=git_scope(manifest,manifest_path,root) if mode=='git' else (None,set())
    candidates=[]
    for allowed in roots:
        start=root if allowed=='.' else root/allowed;check_parents(start)
        def approved_walk():
            for base,dirs,names in os.walk(start,followlinks=False):
                if whole_root and os.path.lexists(Path(base)/'.git'):
                    dirs[:]=[];continue
                for name in dirs+names:
                    if not DENIED.match(name) and (Path(base)/name).is_symlink():raise ValueError('Symlink forbidden')
                dirs[:]=[name for name in dirs if not DENIED.match(name)]
                for name in names:yield Path(base)/name
        for path in ([start] if start.is_file() else approved_walk()):
            relative=path.relative_to(root).as_posix()
            if path.is_symlink():raise ValueError('Symlink forbidden')
            if any(DENIED.match(part) for part in PurePosixPath(relative).parts) or DENIED_EXT.search(path.name):continue
            if not path.is_file() or (relative not in tracked and not source_name(relative,whole_root)):continue
            safe_relative(relative,roots)
            candidates.append(relative)
    if mode=='git':
        # Check only already screened paths: Git must not traverse dependencies or
        # read .gitignore files inside denied trees. Repository rules remain live.
        fresh=sorted(set(candidates)-tracked)
        payload=b''.join(value.encode('utf-8')+b'\0' for value in fresh)
        ignored=set(git_command(directory,root,'check-ignore','--no-index','-z','--stdin',input=payload).decode('utf-8').rstrip('\0').split('\0')) if fresh else set()
        candidates=[value for value in candidates if value not in ignored and not nested_repository(root,root/value)]
    return sorted(set(candidates))

def check_parents(path):
    for node in [path, *path.parents]:
        if node.is_symlink():
            raise ValueError('Symlink path forbidden')

def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''): h.update(chunk)
    return h.hexdigest()

_last_progress = 0.0
def progress(stage,message,done=0,total=-1,files=-1,count=-1,force=False):
    global _last_progress
    now=time.monotonic()
    if not force and now-_last_progress < 1:return
    _last_progress=now
    print('REMOTEAGENTS_PROJECT_PROGRESS='+json.dumps(dict(stage=stage,message=message,doneBytes=done,totalBytes=total,doneFiles=files,totalFiles=count)),file=sys.stderr,flush=True)

def publish_directory(stage,destination):
    """One atomic publication; even a racing empty destination is not replaced."""
    if sys.platform.startswith('linux'):
        import ctypes
        libc=ctypes.CDLL(None,use_errno=True)
        if libc.renameat2(-100,os.fsencode(stage),-100,os.fsencode(destination),1):
            code=ctypes.get_errno();raise OSError(code,os.strerror(code))
    elif os.name=='nt':os.rename(stage,destination)
    else:raise ValueError('Exclusive seed publication requires Linux or Windows')

def seed_status(args):
    manifest=Path(args.manifest);check_parents(manifest)
    receipt_path=manifest.parent/'seed-receipt.json';check_parents(receipt_path)
    receipt=json.loads(receipt_path.read_text('utf-8'))
    if receipt.get('projectId')!=args.project or receipt.get('hostId')!=args.host or receipt.get('manifestHash')!=digest(manifest):raise ValueError('Seed receipt identity mismatch')
    destination=Path(args.base).absolute()/ident(args.project);check_parents(destination)
    if not destination.is_dir():raise ValueError('Completed seed destination is missing')
    print('seeded')

def seed(args):
    base=Path(args.base).absolute(); check_parents(base)
    destination=base/ident(args.project)
    if destination.exists(): raise ValueError('Seed destination exists; refusing overwrite')
    manifest=json.loads(Path(args.manifest).read_text('utf-8-sig'))
    if manifest['projectId'] != args.project or manifest['hostId'] != args.host: raise ValueError('Manifest identity mismatch')
    mode,roots=policy(manifest)
    files=manifest['files']; expected={f['path']:f for f in files}
    if len(expected)!=len(files) or not files: raise ValueError('Empty/duplicate manifest')
    base.mkdir(parents=True,exist_ok=True)
    total=sum(f['size'] for f in files);done=0;finished=0
    progress('extract','Распаковываем и проверяем проект на сервере',0,total,0,len(files),True)
    with tempfile.TemporaryDirectory(prefix='.seed-',dir=base) as temporary:
        stage=Path(temporary)
        with zipfile.ZipFile(args.archive) as archive:
            entries=archive.infolist()
            if len(entries)!=len(files) or len({i.filename for i in entries})!=len(entries): raise ValueError('Archive manifest mismatch')
            for entry in entries:
                relative=safe_relative(entry.filename,roots)
                mode=entry.external_attr >> 16
                if stat.S_ISLNK(mode) or entry.is_dir(): raise ValueError('Archive link/directory rejected')
                record=expected.get(entry.filename)
                if not record or record['size']!=entry.file_size: raise ValueError('Archive size mismatch')
                target=stage.joinpath(*relative.parts);target.parent.mkdir(parents=True,exist_ok=True)
                checksum=hashlib.sha256()
                with archive.open(entry) as src, target.open('xb') as dst:
                    while True:
                        chunk=src.read(1024*1024)
                        if not chunk:break
                        dst.write(chunk);checksum.update(chunk);done+=len(chunk)
                        progress('extract','Распаковываем и проверяем проект на сервере',done,total,finished,len(files))
                if checksum.hexdigest()!=record['sha256']: raise ValueError('Seed hash mismatch')
                finished+=1
        # No half-filled public workspace after an interrupted extraction.
        publish_directory(stage,destination)
    receipt=Path(args.manifest).absolute().parent/'seed-receipt.json';check_parents(receipt)
    create_json(receipt,dict(projectId=args.project,hostId=args.host,manifestHash=digest(Path(args.manifest))))
    progress('extract','Серверная копия распакована и проверена',total,total,len(files),len(files),True)
    print(json.dumps({'ok':True,'projectId':args.project,'hostId':args.host,'destination':str(destination),'fileCount':len(files)}))

def snapshot(args):
    root=Path(args.base).absolute()/ident(args.project);check_parents(root)
    seed_manifest=json.loads(Path(args.manifest).read_text('utf-8-sig'))
    if seed_manifest['projectId']!=args.project or seed_manifest['hostId']!=args.host:raise ValueError('Identity mismatch')
    mode,roots=policy(seed_manifest)
    paths=scope_files(root,seed_manifest,args.manifest)
    files=[{'path':value,'size':(root/value).stat().st_size,'sha256':digest(root/value)} for value in paths]
    if args.refresh_ignores:
        # Approved roots are fixed in the seed policy. Only currently safe source
        # paths can be newly announced; secrets and generated trees stay excluded.
        # Keep safe previously announced paths until their deletion tombstones
        # propagate. Ignoring a deleted path first would strand the peer's copy.
        ignore=root/'.stignore';check_parents(ignore)
        announced={file['path'] for file in files}
        if ignore.exists():
            if not ignore.is_file() or ignore.stat().st_size > 4*1024*1024:raise ValueError('Unsafe ignore state')
            for line in ignore.read_text('utf-8').splitlines():
                if line == '*':continue
                # Initial configuration also has deny patterns. Import only
                # exact include entries; never carry arbitrary ignore rules.
                if not line.startswith('!/'):continue
                value=unescape_ignore_path(line[2:]);safe_relative(value,roots)
                if not source_name(value,mode in ('git','folder')) and value not in seed_manifest.get('gitPaths',[]):raise ValueError('Unsafe announced path')
                if mode in ('git','folder') and value not in paths and os.path.lexists(root/value):continue
                announced.add(value)
        lines=[]
        for value in sorted(announced):
            safe_relative(value,roots)
            lines.append('!/'+escape_ignore_path(value))
        lines.append('*')
        # Syncthing must never observe an empty/half-written ignore policy.
        # Stage outside the synchronized source, then replace on the same FS.
        temporary=None
        try:
            with tempfile.NamedTemporaryFile(mode='w',encoding='utf-8',dir=root.parent,prefix='.sync-ignore-',delete=False) as stream:
                temporary=Path(stream.name);stream.write('\n'.join(lines)+'\n');stream.flush();os.fsync(stream.fileno())
            os.replace(temporary,ignore)
        finally:
            if temporary is not None:temporary.unlink(missing_ok=True)
    import uuid
    result={'schema':1,'projectId':args.project,'hostId':args.host,'snapshotId':uuid.uuid4().hex,'allowedRoots':roots,'files':files}
    if mode=='git':result.update(scopeMode='git',gitPaths=seed_manifest['gitPaths'])
    elif mode=='folder':result['scopeMode']='folder'
    # Snapshot is metadata, outside the replicated source tree.
    output=Path(args.output).absolute();check_parents(output)
    if output == root or root in output.parents:raise ValueError('Snapshot output must be outside source')
    output.write_text(json.dumps(result,separators=(',',':')),'utf-8')
    print(json.dumps({'ok':True,'snapshotId':result['snapshotId'],'fileCount':len(files)}))


def project_record(base, project):
    return Path(base).absolute().parent/'.remote-agents-projects'/ident(project)/'project.json'


def create_json(path, data):
    """Publish complete metadata exclusively, without replacing another binding."""
    temporary=None
    try:
        with tempfile.NamedTemporaryFile(mode='w',encoding='utf-8',dir=path.parent,prefix='.registration-',delete=False) as stream:
            temporary=Path(stream.name);json.dump(data,stream);stream.flush();os.fsync(stream.fileno())
        os.link(temporary,path)
    finally:
        if temporary is not None:temporary.unlink(missing_ok=True)


def projects(args):
    """Only explicit installer registrations, never infer identity from folder names."""
    directory=Path(args.base).absolute().parent/'.remote-agents-projects';check_parents(directory)
    result=[]
    if directory.exists():
        for path in sorted(directory.glob('*/project.json')):
            check_parents(path)
            data=json.loads(path.read_text('utf-8'))
            if project_record(args.base,data['projectId'])!=path:raise ValueError('Catalog identity mismatch')
            root=Path(args.base).absolute()/data['projectId'];check_parents(root)
            if root.is_dir():
                label_path=path.parent/'label.json';check_parents(label_path)
                label=json.loads(label_path.read_text('utf-8')) if label_path.exists() else {}
                result.append({'projectId':data['projectId'],'displayName':label.get('name',data['projectId']),'scopeMode':data['manifest'].get('scopeMode','allowlist'),'allowedRoots':data['manifest']['allowedRoots'],'serverPath':str(root)})
    print(json.dumps({'projects':result}))


def project_shortcut(base,project,name,shortcuts=None):
    root=Path(base).absolute()/ident(project);check_parents(root)
    if not root.is_dir():raise ValueError('Missing server workspace')
    record=project_record(base,project);label_path=record.parent/'label.json';check_parents(label_path)
    record.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    if label_path.exists():name=json.loads(label_path.read_text('utf-8'))['name']
    if not isinstance(name,str) or not name or any(c in name for c in '/\\\r\n\0'):raise ValueError('Invalid project display name')
    directory=Path(shortcuts) if shortcuts is not None else Path(base).absolute()
    check_parents(directory);directory.mkdir(mode=0o700,parents=True,exist_ok=True)
    readable=name.strip().strip('.').encode('utf-8')[:180].decode('utf-8','ignore') or 'project'
    alias=directory/readable
    if os.path.lexists(alias) and not (alias.is_symlink() and os.readlink(alias)==str(root)):
        alias=directory/(readable+'--'+project[2:10])
    if alias.is_symlink():
        if os.readlink(alias)!=str(root):raise ValueError('Project shortcut points elsewhere')
    elif os.path.lexists(alias):raise ValueError('Project shortcut destination exists')
    else:alias.symlink_to(root,target_is_directory=True)
    if not label_path.exists():create_json(label_path,{'name':name,'shortcut':str(alias)})
    return alias


def register_project(args):
    manifest_path=Path(args.manifest).absolute();check_parents(manifest_path)
    manifest=json.loads(manifest_path.read_text('utf-8-sig'));policy(manifest)
    marker=json.loads((manifest_path.parent/'configured.json').read_text('utf-8'))
    if any(record['projectId']!=args.project or record['hostId']!=args.host for record in (manifest,marker)):
        raise ValueError('Configured subscription identity mismatch')
    root=Path(args.base).absolute()/ident(args.project);check_parents(root)
    if not root.is_dir():raise ValueError('Missing server workspace')
    path=project_record(args.base,args.project);check_parents(path)
    if path.exists():
        data=json.loads(path.read_text('utf-8'))
        expected=dict(data['manifest']);expected['hostId']=args.host
        if expected!=manifest:raise ValueError('Shared project scope mismatch')
    else:
        path.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        create_json(path,{'projectId':args.project,'manifest':manifest})
    name=getattr(args,'name',None)
    if getattr(args,'name_base64',None):
        import base64
        name=base64.b64decode(args.name_base64,validate=True).decode('utf-8')
    if name:project_shortcut(args.base,args.project,name)
    print('{"ok":true}')


def attach(args):
    """Export existing server policy for another receive-only host; no seed IO."""
    path=project_record(args.base,args.project);check_parents(path)
    data=json.loads(path.read_text('utf-8'));manifest=dict(data['manifest']);policy(manifest)
    if data['projectId']!=args.project or manifest['projectId']!=args.project:raise ValueError('Catalog identity mismatch')
    root=Path(args.base).absolute()/ident(args.project);check_parents(root)
    if not root.is_dir():raise ValueError('Missing server workspace')
    manifest['hostId']=ident(args.host)
    output=Path(args.manifest).absolute();check_parents(output)
    if output==root or root in output.parents:raise ValueError('Subscription metadata must be outside source')
    if output.exists():
        if json.loads(output.read_text('utf-8-sig'))!=manifest:raise ValueError('Existing subscription policy mismatch')
    else:
        create_json(output,manifest)
    print(json.dumps({'ok':True,'projectId':args.project,'hostId':args.host,'manifest':manifest}))

def main():
    p=argparse.ArgumentParser();p.add_argument('action',choices=['seed','seed-status','snapshot','projects','register','attach']);p.add_argument('--base',required=True);p.add_argument('--project');p.add_argument('--host');p.add_argument('--manifest');p.add_argument('--archive');p.add_argument('--output');p.add_argument('--refresh-ignores',action='store_true')
    p.add_argument('--name')
    p.add_argument('--name-base64')
    args=p.parse_args()
    if os.getuid()==0:raise ValueError('Run as nonroot managed user')
    if args.action=='projects':projects(args);return
    ident(args.project);ident(args.host)
    # One metadata/snapshot writer per server project, shared by all subscriptions.
    import fcntl
    locks=Path(args.base).absolute().parent/'.remote-agents-project-locks';check_parents(locks);locks.mkdir(mode=0o700,parents=True,exist_ok=True)
    lock=locks/(args.project+'.lock');check_parents(lock)
    with lock.open('a') as stream:
        fcntl.flock(stream,fcntl.LOCK_EX)
        {'seed':seed,'seed-status':seed_status,'snapshot':snapshot,'register':register_project,'attach':attach}[args.action](args)
if __name__=='__main__':
    try:main()
    except Exception as exc:
        print(json.dumps({'ok':False,'reason':str(exc)}));sys.exit(1)
