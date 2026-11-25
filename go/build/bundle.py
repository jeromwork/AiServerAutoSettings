"""Build the offline payload; downloads happen here, never in the application."""
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import urllib.request
import zipfile


here = Path(__file__).resolve().parent
goos, arch, out = sys.argv[1:4]
out = Path(out)
cache = out / 'cache'
cache.mkdir(parents=True, exist_ok=True)
old_cache = Path(os.environ.get('RA_LAB_CACHE', str(Path.home() / '.cache/ra-lab')))
files = {}
modes = {}
spec = json.loads((here / 'bundle.json').read_text())


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fetch(url, name, want):
    path = cache / name
    candidates = [path, old_cache / ('bin-' + want)]
    for candidate in candidates:
        if candidate.is_file():
            data = candidate.read_bytes()
            if sha(data) == want:
                return data
    print('Скачивание: ' + url, flush=True)
    with urllib.request.urlopen(url, timeout=300) as response:
        data = response.read()
    if sha(data) != want:
        raise ValueError('SHA-256 не совпал: ' + name)
    path.with_suffix(path.suffix + '.part').write_bytes(data)
    path.with_suffix(path.suffix + '.part').replace(path)
    return data


def members(data):
    if zipfile.is_zipfile(io.BytesIO(data)):
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            return {n: archive.read(n) for n in archive.namelist() if not n.endswith('/')}
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
        return {m.name: archive.extractfile(m).read() for m in archive if m.isfile()}


def put(target, data, executable=False):
    files[target] = data
    modes[target] = 0o755 if executable else 0o644


def package(name, url, digest, executable):
    content = members(fetch(url, url.rsplit('/', 1)[-1], digest))
    member = next(n for n in content if n.rsplit('/', 1)[-1] == executable)
    put(executable, content[member], True)
    for rel, data in content.items():
        if rel.rsplit('/', 1)[-1].upper() in ('LICENSE', 'LICENSE.TXT', 'COPYING'):
            put('licenses/' + name + '/' + rel.rsplit('/', 1)[-1], data)


# Windows pins and the shared rule set are the v2 lab/bundle.json payload.
for item in spec['binaries']:
    if item.get('os', goos) != goos:
        continue
    raw = fetch(item['url'], 'bin-' + item['sha256'], item['sha256'])
    content = members(raw) if item.get('member') else {}
    data = content[item['member']] if content else raw
    if sha(data) != item['memberSha256']:
        raise ValueError('SHA-256 файла не совпал: ' + item['target'])
    put(item['target'], data, item['target'].endswith('.exe'))
    if item.get('license'):
        put('licenses/' + item['name'] + '/' + item['license'].rsplit('/', 1)[-1],
            content[item['license']])

if goos != 'windows':
    version = spec['sing-box']['version']
    base = 'https://github.com/SagerNet/sing-box/releases/download/v' + version + '/'
    name = 'sing-box-' + version + '-' + goos + '-' + arch + '.tar.gz'
    package('sing-box', base + name, spec['sing-box']['sha256'][goos + '-' + arch], 'sing-box')

version = spec['syncthing']['version']
base = 'https://github.com/syncthing/syncthing/releases/download/v' + version + '/'
platform = 'macos' if goos == 'darwin' else goos
suffix = '.tar.gz' if goos == 'linux' else '.zip'
name = 'syncthing-' + platform + '-' + arch + '-v' + version + suffix
package('syncthing', base + name, spec['syncthing']['sha256'][goos + '-' + arch],
        'syncthing.exe' if goos == 'windows' else 'syncthing')

if goos == 'windows':
    put('disk-explorer.exe', (out / 'explorer/disk-explorer.exe').read_bytes(), True)

manifest = {rel: sha(data) for rel, data in sorted(files.items())}
put('bin-manifest.json', (json.dumps(manifest, sort_keys=True, indent=1) + '\n').encode())
target = out / 'bin.zip'
with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as archive:
    for rel, data in sorted(files.items()):
        info = zipfile.ZipInfo(rel, (1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.create_system = 3
        info.external_attr = (0o100000 | modes[rel]) << 16
        archive.writestr(info, data, compresslevel=9)
print('bin.zip: %d байт, SHA-256 %s' % (target.stat().st_size, sha(target.read_bytes())))
