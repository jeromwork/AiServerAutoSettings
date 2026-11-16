#!/usr/bin/env python3
"""Compile the package-free Disk harness with SDK Roslyn, without MSBuild/restore startup.

DiskTests.csproj is also buildable with dotnet build. Read its actual source/resource
inventory here, so the fast build cannot silently omit a new production file.
"""
import glob
import hashlib
import json
import os
from pathlib import Path
import subprocess
import xml.etree.ElementTree as E

HERE = Path(__file__).resolve().parent
project = HERE / 'tests/DiskTests.csproj'
dotnet = Path(os.environ.get('DOTNET', str(Path.home() / '.dotnet/dotnet'))).resolve()


def latest(directory):
    return max(directory.iterdir(), key=lambda p: tuple(int(x) for x in p.name.split('.')))


sdk = latest(dotnet.parent / 'sdk')
refs = latest(dotnet.parent / 'packs/Microsoft.NETCore.App.Ref') / 'ref/net10.0'
runtime = latest(dotnet.parent / 'shared/Microsoft.NETCore.App')
sources, resources = [], []
for item in E.parse(project).getroot().iter():
    if item.tag not in ('Compile', 'EmbeddedResource'):
        continue
    files = sorted(Path(p).resolve() for p in glob.glob(str(project.parent / item.attrib['Include'])))
    if not files:
        raise SystemExit('Missing harness input: ' + item.attrib['Include'])
    if item.tag == 'Compile':
        sources.extend(files)
    else:
        resources.extend((p, item.attrib['LogicalName'].replace('%(Filename)', p.stem).replace('%(Extension)', p.suffix)) for p in files)

out = project.parent / 'bin/Release/net10.0'
dll = out / 'DiskTests.dll'
stamp = out / 'disk-build.sha256'
digest = hashlib.sha256()
for p in [Path(__file__), project, *sources, *(p for p, _ in resources)]:
    digest.update(str(p).encode() + b'\0' + p.read_bytes())
digest.update(str((sdk, refs, runtime)).encode())
signature = digest.hexdigest()
if not (dll.is_file() and stamp.is_file() and stamp.read_text() == signature):
    out.mkdir(parents=True, exist_ok=True)
    stamp.unlink(missing_ok=True)
    subprocess.run([str(dotnet), str(sdk / 'Roslyn/bincore/csc.dll'), '-nologo', '-target:exe',
        '-langversion:7.3', '-define:PORTABLE_TEST;DISK_FAST', '-nowarn:SYSLIB0014,SYSLIB0057,CA1416',
        '-out:' + str(dll), *('-r:' + str(p) for p in sorted(refs.glob('*.dll'))),
        *('-resource:' + str(p) + ',' + name for p, name in resources), *map(str, sources)], check=True)
    (out / 'DiskTests.runtimeconfig.json').write_text(json.dumps({'runtimeOptions': {
        'tfm': 'net10.0', 'framework': {'name': 'Microsoft.NETCore.App', 'version': runtime.name}}}))
    stamp.write_text(signature)
    print('Disk C#: compiled current sources/resources', flush=True)
else:
    print('Disk C#: source/resource hash unchanged', flush=True)
