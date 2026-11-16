#!/usr/bin/env python3
"""Offline preparation and bounded SSH publication; no server credentials or fixed hostnames."""
import hashlib
import json
from pathlib import Path
import shlex
import sys
import zipfile

# Same code runs over SSH and in tests. Payload first, manifest last, then disk readback.
REMOTE = r'''
import fcntl, hashlib, json, os, pathlib, sys, tarfile, tempfile
root = pathlib.Path(sys.argv[1]).expanduser()
root.mkdir(parents=True, exist_ok=True)
with (root / '.publish.lock').open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    with tempfile.TemporaryDirectory(prefix='.incoming-', dir=root) as tmp:
        stage = pathlib.Path(tmp)
        total = 0
        with tarfile.open(fileobj=sys.stdin.buffer, mode='r|') as archive:
            for member in archive:
                name = pathlib.PurePosixPath(member.name)
                if member.isdir() and str(name) in ('agents', 'vpn'): continue
                if not member.isfile() or len(name.parts) != 2 or name.parts[0] not in ('agents', 'vpn') or name.parts[1] in ('.', '..'):
                    raise ValueError('Invalid release path')
                total += member.size
                if total > 2 * 1024**3: raise ValueError('Release too large')
                dest = stage.joinpath(*name.parts)
                dest.parent.mkdir(exist_ok=True)
                with archive.extractfile(member) as source, dest.open('xb') as output:
                    import shutil
                    shutil.copyfileobj(source, output)
        manifests = []
        sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
        for folder, product in [('agents', 'RemoteAgents'), ('vpn', 'RemoteVPN')]:
            src = stage / folder
            m = json.loads((src / 'manifest.json').read_text())
            if m['product'] != product or m['configSchema'] != 1 or pathlib.PurePath(m['file']).name != m['file']: raise ValueError('Invalid manifest')
            if sha(src / m['file']) != m['sha256'] or (src / m['file']).stat().st_size != m['size'] or sha(src / (product + '.exe')) != m['launcher']['sha256']:
                raise ValueError('Release SHA-256 mismatch')
            manifests.append(m)
        if manifests[0]['version'] != manifests[1]['version']: raise ValueError('Mixed release versions')
        # Check immutability for BOTH products before publishing either manifest.
        for folder, m in zip(('agents', 'vpn'), manifests):
            dest = root if folder == 'agents' else root / 'vpn'
            dest.mkdir(exist_ok=True)
            if (dest / m['file']).exists() and sha(dest / m['file']) != m['sha256']: raise ValueError('Version is immutable')
        for folder, m in zip(('agents', 'vpn'), manifests):
            src = stage / folder
            dest = root if folder == 'agents' else root / 'vpn'
            for name in (m['file'], m['product'] + '.exe', 'manifest.json'):
                os.chmod(src / name, 0o644)
                os.replace(src / name, dest / name)
            if sha(dest / m['file']) != m['sha256'] or sha(dest / (m['product'] + '.exe')) != m['launcher']['sha256']:
                raise ValueError('Published SHA-256 mismatch')
            if json.loads((dest / 'manifest.json').read_text()) != m: raise ValueError('Published manifest mismatch')
            print(m['product'], m['version'], m['sha256'])
'''

def metadata(stage, output, commit):
    stage = Path(stage)
    manifests = [json.loads((stage / p / 'manifest.json').read_text()) for p in ('agents', 'vpn')]
    if manifests[0]['version'] != manifests[1]['version']:
        raise ValueError('Mixed release versions')
    data = {'version': manifests[0]['version'], 'commit': commit,
            'sha256': {m['product'] + '.exe': m['launcher']['sha256'] for m in manifests}}
    Path(output).write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')

def verify(output, commit):
    output = Path(output)
    info = json.loads((output / 'release-info.json').read_text())
    if info['commit'] != commit:
        raise ValueError('Prepared release commit mismatch')
    for product, archive in [('RemoteAgents', 'bundle.zip'), ('RemoteVPN', 'vpn-bundle.zip')]:
        exe = (output / (product + '.exe')).read_bytes()
        if hashlib.sha256(exe).hexdigest() != info['sha256'][product + '.exe']:
            raise ValueError('Prepared release EXE mismatch')
        with zipfile.ZipFile(output / archive) as bundle:
            if bundle.read('bundle-version.txt').decode('utf-8-sig').strip() != info['version'] or bundle.read(product + '.exe') != exe:
                raise ValueError('Prepared release bundle mismatch')

if __name__ == '__main__':
    if sys.argv[1] == 'command':
        print('python3 -c ' + shlex.quote(REMOTE) + ' ' + shlex.quote(sys.argv[2]))
    elif sys.argv[1] == 'verify':
        verify(*sys.argv[2:])
    elif sys.argv[1] == 'metadata':
        metadata(*sys.argv[2:])
    else:
        raise SystemExit(2)
