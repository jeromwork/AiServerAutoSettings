#!/usr/bin/env python3
"""Nonroot sync operations; caller supplies only approved seed/source artifacts.
Never reads existing agent authentication. Run from an operator-owned deployment.
"""
import argparse, hashlib, json, os, re, shutil, stat, subprocess, sys, tempfile, zipfile
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
    if any(c in value for c in '*?[]{}!#\n\r\\\0') or p.is_absolute() or not p.parts or p.as_posix()!=value or any(x in ('', '.', '..') or ':' in x or DENIED.match(x) for x in p.parts) or DENIED_EXT.search(p.name):
        raise ValueError('Forbidden manifest path')
    if not any(r == '.' or value == r or value.startswith(r.rstrip('/') + '/') for r in roots):
        raise ValueError('Path outside allowlist')
    return p

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
                with archive.open(entry) as src, target.open('xb') as dst:
                    while True:
                        chunk=src.read(1024*1024)
                        if not chunk:break
                        dst.write(chunk)
                if digest(target)!=record['sha256']: raise ValueError('Seed hash mismatch')
        # Exclusive final creation; no replacement of an existing project.
        destination.mkdir(mode=0o700)
        try:
            for child in stage.iterdir(): child.rename(destination/child.name)
        except Exception:
            raise ValueError('Partial seed: inspect new destination; existing folders untouched')
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
                value=line[2:];safe_relative(value,roots)
                if not source_name(value,mode in ('git','folder')) and value not in seed_manifest.get('gitPaths',[]):raise ValueError('Unsafe announced path')
                if mode in ('git','folder') and value not in paths and os.path.lexists(root/value):continue
                announced.add(value)
        lines=[]
        for value in sorted(announced):
            if any(c in value for c in '*?[]{}!#\n\r\\'):raise ValueError('Unsafe ignore path')
            lines.append('!/'+value)
        lines.append('*')
        ignore.write_text('\n'.join(lines)+'\n','utf-8')
    import uuid
    result={'schema':1,'projectId':args.project,'hostId':args.host,'snapshotId':uuid.uuid4().hex,'allowedRoots':roots,'files':files}
    if mode=='git':result.update(scopeMode='git',gitPaths=seed_manifest['gitPaths'])
    elif mode=='folder':result['scopeMode']='folder'
    # Snapshot is metadata, outside the replicated source tree.
    output=Path(args.output).absolute();check_parents(output)
    if output == root or root in output.parents:raise ValueError('Snapshot output must be outside source')
    output.write_text(json.dumps(result,separators=(',',':')),'utf-8')
    print(json.dumps({'ok':True,'snapshotId':result['snapshotId'],'fileCount':len(files)}))

def main():
    p=argparse.ArgumentParser();p.add_argument('action',choices=['seed','snapshot']);p.add_argument('--base',required=True);p.add_argument('--project',required=True);p.add_argument('--host',required=True);p.add_argument('--manifest',required=True);p.add_argument('--archive');p.add_argument('--output');p.add_argument('--refresh-ignores',action='store_true')
    args=p.parse_args();ident(args.project);ident(args.host)
    if os.getuid()==0:raise ValueError('Run as nonroot managed user')
    if args.action=='seed':seed(args)
    else:snapshot(args)
if __name__=='__main__':
    try:main()
    except Exception as exc:
        print(json.dumps({'ok':False,'reason':str(exc)}));sys.exit(1)
