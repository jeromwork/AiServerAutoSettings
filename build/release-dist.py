#!/usr/bin/env python3
"""Offline preparation and bounded SSH publication; no server credentials or fixed hostnames."""
import argparse
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
product = sys.argv[2]
channel = sys.argv[3]
if channel not in ('main', 'test'): raise ValueError('Invalid channel')
# A test build may only land in .../dist-test, a main build never there (it would switch clients for good).
norm = str(root).rstrip('/')
while norm.endswith('/.'): norm = norm[:-2].rstrip('/')
if (channel == 'test') != norm.endswith('/dist-test'): raise ValueError('Channel does not match destination')
if product not in ('RemoteAgents',): raise ValueError('Invalid product')
root.mkdir(parents=True, exist_ok=True)
with (root / '.publish.lock').open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    with tempfile.TemporaryDirectory(prefix='.incoming-', dir=root) as tmp:
        stage = pathlib.Path(tmp)
        total = 0
        with tarfile.open(fileobj=sys.stdin.buffer, mode='r|') as archive:
            for member in archive:
                name = pathlib.PurePosixPath(member.name)
                if member.isdir() and str(name) in ('agents',): continue
                if not member.isfile() or len(name.parts) != 2 or name.parts[0] not in ('agents',) or name.parts[1] in ('.', '..'):
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
        for folder, product in [('agents', product)]:
            src = stage / folder
            m = json.loads((src / 'manifest.json').read_text())
            if m['product'] != product or m['configSchema'] != 1 or m.get('channel') != channel or pathlib.PurePath(m['file']).name != m['file']: raise ValueError('Invalid manifest')
            if sha(src / m['file']) != m['sha256'] or (src / m['file']).stat().st_size != m['size'] or sha(src / (product + '.exe')) != m['launcher']['sha256']:
                raise ValueError('Release SHA-256 mismatch')
            manifests.append(m)
        # Check immutable payload before publishing the manifest.
        for folder, m in zip(('agents',), manifests):
            dest = root
            dest.mkdir(exist_ok=True)
            if (dest / m['file']).exists() and sha(dest / m['file']) != m['sha256']: raise ValueError('Version is immutable')
        for folder, m in zip(('agents',), manifests):
            src = stage / folder
            dest = root
            for name in (m['file'], m['product'] + '.exe', 'manifest.json'):
                os.chmod(src / name, 0o644)
                os.replace(src / name, dest / name)
            if sha(dest / m['file']) != m['sha256'] or sha(dest / (m['product'] + '.exe')) != m['launcher']['sha256']:
                raise ValueError('Published SHA-256 mismatch')
            if json.loads((dest / 'manifest.json').read_text()) != m: raise ValueError('Published manifest mismatch')
            print(m['product'], m['version'], m['sha256'])
'''

def check_product(product):
    if product not in ('RemoteAgents',):
        raise ValueError('Invalid product')

def check_channel(channel):
    if channel not in ('main', 'test'):
        raise ValueError('Invalid channel')

def metadata(stage, output, commit, product='RemoteAgents', channel='main'):
    check_product(product)
    check_channel(channel)
    stage = Path(stage)
    manifests = [json.loads((stage / p / 'manifest.json').read_text()) for p in ('agents',)]
    if any(m['product'] != product for m in manifests):
        raise ValueError('Prepared release product mismatch')
    if any(m.get('channel') != channel for m in manifests):
        raise ValueError('Prepared release channel mismatch')
    data = {'version': manifests[0]['version'], 'commit': commit, 'channel': channel,
            'sha256': {m['product'] + '.exe': m['launcher']['sha256'] for m in manifests}}
    Path(output).write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')

def verify(output, commit, product='RemoteAgents', channel='main'):
    check_product(product)
    check_channel(channel)
    output = Path(output)
    info = json.loads((output / 'release-info.json').read_text())
    if info.get('channel') != channel:
        raise ValueError('Prepared release channel mismatch')
    if info['commit'] != commit:
        raise ValueError('Prepared release commit mismatch')
    if set(info['sha256']) != {product + '.exe'}:
        raise ValueError('Prepared release product mismatch')
    for archive in ('bundle.zip',):
        exe = (output / (product + '.exe')).read_bytes()
        if hashlib.sha256(exe).hexdigest() != info['sha256'][product + '.exe']:
            raise ValueError('Prepared release EXE mismatch')
        with zipfile.ZipFile(output / archive) as bundle:
            if bundle.read('bundle-version.txt').decode('utf-8-sig').strip() != info['version'] or bundle.read(product + '.exe') != exe:
                raise ValueError('Prepared release bundle mismatch')

def command(dist, product='RemoteAgents', channel='main'):
    check_product(product)
    check_channel(channel)
    return 'python3 -c ' + shlex.quote(REMOTE) + ' ' + shlex.quote(dist) + ' ' + shlex.quote(product) + ' ' + shlex.quote(channel)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('metadata', 'verify', 'command'):
        p = sub.add_parser(name)
        p.add_argument('--product', choices=('RemoteAgents',), default='RemoteAgents')
        p.add_argument('--channel', choices=('main', 'test'), default='main')
        if name == 'command':
            p.add_argument('dist')
        else:
            p.add_argument('directory')
            if name == 'metadata':
                p.add_argument('output')
            p.add_argument('commit')
    args = parser.parse_args()
    if args.command == 'command':
        print(command(args.dist, args.product, args.channel))
    elif args.command == 'verify':
        verify(args.directory, args.commit, args.product, args.channel)
    else:
        metadata(args.directory, args.output, args.commit, args.product, args.channel)
