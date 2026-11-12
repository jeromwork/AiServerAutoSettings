#!/usr/bin/env python3
"""Deterministic allowlisted ZIP and atomic local publication; Python standard library only."""
import argparse
import glob
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent

def safe_version(value):
    if not re.fullmatch(r'[0-9][A-Za-z0-9._-]{0,79}', value) or '..' in value or value.endswith('.'):
        raise ValueError('Недопустимая версия')
    return value

def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

def put_atomic(path, data, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    fd, temp = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(temp, mode)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)

PINS = ROOT / 'build/bundle-binaries.json'
MAX_BINARY = 256 * 1024 * 1024

def binary_cache():
    return Path(os.environ.get('REMOTEAGENTS_BINARY_CACHE') or Path.home() / '.cache/remoteagents-build/binaries')

def pinned(pins=None):
    data = json.loads(Path(pins or PINS).read_text(encoding='utf-8-sig'))
    rows = data.get('binaries') or []
    for row in rows:
        if not re.fullmatch(r'https://[^\s]+', row['url']) or not re.fullmatch(r'[0-9a-f]{64}', row['sha256']) \
                or not re.fullmatch(r'[0-9a-f]{64}', row['memberSha256']) or not re.fullmatch(r'[a-z][a-z0-9/._-]{0,120}', row['target']) or '..' in row['target']:
            raise ValueError('Неверная запись build/bundle-binaries.json: ' + row.get('name', '?'))
    return rows

def archive_path(row, cache=None):
    return Path(cache or binary_cache()) / Path(row['url'].rsplit('/', 1)[1]).name

def fetch(pins=None, cache=None):
    """Download each pinned archive once; anything with another SHA-256 is deleted and refused."""
    import urllib.request
    for row in pinned(pins):
        path = archive_path(row, cache)
        if path.exists() and digest(path) == row['sha256']:
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        temp = path.with_name(path.name + '.part')
        try:
            with urllib.request.urlopen(row['url'], timeout=60) as response, open(temp, 'wb') as out:
                total = 0
                for chunk in iter(lambda: response.read(1024 * 1024), b''):
                    total += len(chunk)
                    if total > MAX_BINARY:
                        raise ValueError('Слишком большой файл: ' + row['url'])
                    out.write(chunk)
        except OSError as e:
            raise SystemExit('Не удалось скачать ' + row['name'] + ' (' + row['url'] + '): ' + str(e) +
                             '. Положите проверенный архив в ' + str(path) + ' или повторите с доступом к сети.')
        if digest(temp) != row['sha256']:
            temp.unlink()
            raise SystemExit('SHA-256 ' + row['name'] + ' не совпал с build/bundle-binaries.json — файл удалён, сборка остановлена.')
        os.replace(temp, path)
        print('verified', path)

def binary_contents(pins=None, cache=None):
    """Pinned third-party binaries for the EXE's initial bundle; both hashes are checked again here."""
    result = {}
    for row in pinned(pins):
        path = archive_path(row, cache)
        if not path.exists():
            raise ValueError('Нет ' + row['name'] + ' в кэше сборки (' + str(path) + '): выполните «python3 build/bundle.py fetch»')
        if digest(path) != row['sha256']:
            raise ValueError('SHA-256 архива ' + row['name'] + ' не совпал с build/bundle-binaries.json')
        with zipfile.ZipFile(path) as z:
            info = z.getinfo(row['member'])
            if info.file_size > MAX_BINARY:
                raise ValueError('Слишком большой файл ' + row['member'])
            data = z.read(info)
        if hashlib.sha256(data).hexdigest() != row['memberSha256']:
            raise ValueError('SHA-256 ' + row['member'] + ' не совпал с build/bundle-binaries.json')
        result[row['target']] = data
    return result

def make(version, outdir, launcher=None, product="RemoteAgents", binaries=False):
    safe_version(version)
    outdir = Path(outdir).resolve()
    outdir.mkdir(parents=True, exist_ok=True)
    contents = {}
    for raw in (ROOT / 'build/bundle-files.txt').read_text(encoding='utf-8-sig').splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        optional = line.startswith('?')
        line = line.lstrip('?')
        source, _, target = line.partition(' => ')
        matches = sorted(glob.glob(str(ROOT / source)))
        if not matches and not optional:
            raise ValueError('Нет обязательного файла: ' + source)
        for filename in matches:
            p = Path(filename)
            if not p.is_file() or p.is_symlink() or ROOT not in p.resolve().parents:
                raise ValueError('Требуется обычный файл внутри репозитория: ' + source)
            name = target or p.relative_to(ROOT).as_posix()
            if p.suffix.lower() in ('.exe', '.zip', '.dll', '.key', '.pem'):
                raise ValueError('Скачанные бинарники и секреты не включаются: ' + name)
            data = p.read_bytes()
            # Every cross-system text payload is normalized at this single packaging boundary.
            data = data.replace(b'\r\n', b'\n').replace(b'\r', b'\n')
            if p.suffix.lower() == '.ps1' and not data.startswith(b'\xef\xbb\xbf'):
                data = b'\xef\xbb\xbf' + data  # Windows PowerShell 5.1 must read Cyrillic as UTF-8.
            if name in contents:
                raise ValueError('Повтор файла: ' + name)
            contents[name] = data
    if product == 'RemoteVPN':
        # Both products ship shared setup; only runtime supervision differs.
        contents['components.json'] = (ROOT/'build/components-vpn.json').read_bytes()
        contents['product.txt'] = b'RemoteVPN\n'
    if binaries:
        for name, data in binary_contents().items():
            if name in contents:
                raise ValueError('Повтор файла: ' + name)
            contents[name] = data
    contents['bundle-version.txt'] = (version + '\n').encode()
    if launcher:
        contents['RemoteAgents.exe'] = Path(launcher).read_bytes()
    contents['bundle-files.txt'] = ('\n'.join(sorted(contents)) + '\n').encode()
    fd, temp = tempfile.mkstemp(prefix='.bundle-', dir=outdir)
    os.close(fd)
    dest = outdir / (version + '.zip')
    try:
        with zipfile.ZipFile(temp, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
            for name, data in sorted(contents.items()):
                info = zipfile.ZipInfo(name, date_time=(2020, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = (stat.S_IFREG | (0o755 if name.endswith('.sh') else 0o644)) << 16
                z.writestr(info, data)
        os.chmod(temp, 0o644)
        os.replace(temp, dest)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)
    print(dest)
    return dest

def attach_launcher(archive, launcher, output):
    # Preserve the exact modules embedded in EXE even if another task edits transport during compilation.
    archive, output = Path(archive), Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix='.ota-', dir=output.parent)
    os.close(fd)
    try:
        with zipfile.ZipFile(archive) as source, zipfile.ZipFile(temp, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as dest:
            # SSH/OTA updates never carry the embedded third-party binaries: the first run copied them
            # out of the initial bundle (transport-bin), an update must stay small.
            pinned_targets = {row['target'] for row in pinned()}
            names = (set(source.namelist()) - pinned_targets) | {'RemoteAgents.exe'}
            for name in sorted(names):
                if name == 'RemoteAgents.exe':
                    data = Path(launcher).read_bytes()
                elif name == 'bundle-files.txt':
                    data = ('\n'.join(sorted(names - {'bundle-files.txt'})) + '\n').encode()
                else:
                    data = source.read(name)
                info = zipfile.ZipInfo(name, date_time=(2020, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = (stat.S_IFREG | (0o755 if name.endswith('.sh') else 0o644)) << 16
                dest.writestr(info, data)
        os.chmod(temp, 0o644)
        os.replace(temp, output)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)
    print(output)
    return output

def file_version(exe):
    # FileVersion in the managed PE resource; no Windows runtime is needed.
    raw = exe
    marker = 'FileVersion\0'.encode('utf-16le')
    at = raw.find(marker)
    if at < 0:
        raise ValueError('У EXE нет FileVersion')
    rest = raw[at + len(marker):]
    for offset in (0, 2):
        text = rest[offset:offset+128].decode('utf-16le', errors='ignore').split('\0', 1)[0]
        if re.fullmatch(r'\d+\.\d+\.\d+\.\d+', text):
            return text
    raise ValueError('Не удалось прочитать FileVersion')

def publish(archive, dest, minimum='1.0.0', launcher=None):
    safe_version(minimum)
    archive = Path(archive).resolve()
    dest = Path(dest).expanduser().resolve()
    dest.mkdir(parents=True, exist_ok=True, mode=0o755)
    os.chmod(dest, 0o755)
    with zipfile.ZipFile(archive) as z:
        version = safe_version(z.read('bundle-version.txt').decode('utf-8-sig').strip())
        json.loads(z.read('components.json').decode('utf-8-sig'))
        embedded_exe = z.read('RemoteAgents.exe') if 'RemoteAgents.exe' in z.namelist() else None
    manifest = dict(version=version, file=version+'.zip', sha256=digest(archive), size=archive.stat().st_size, minLauncher=minimum)
    if embedded_exe:
        manifest['launcher'] = dict(version=file_version(embedded_exe), sha256=hashlib.sha256(embedded_exe).hexdigest())
    data = archive.read_bytes()
    target = dest / manifest['file']
    # A version URL is immutable: concurrent clients must never get different content for it.
    if target.exists() and digest(target) != manifest['sha256']:
        raise ValueError('Версия уже опубликована с другим содержимым')
    put_atomic(target, data)
    if launcher:
        exe = Path(launcher).read_bytes()
        put_atomic(dest / 'RemoteAgents.exe', exe)
    # Readers see the new manifest only after every payload is in place.
    put_atomic(dest / 'manifest.json', (json.dumps(manifest, ensure_ascii=False, indent=2)+'\n').encode())
    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    return manifest

def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest='command', required=True)
    b = sub.add_parser('make')
    b.add_argument('version'); b.add_argument('outdir'); b.add_argument('--launcher'); b.add_argument('--product', choices=['RemoteAgents','RemoteVPN'], default='RemoteAgents')
    b.add_argument('--binaries', action='store_true', help='embed pinned binaries of build/bundle-binaries.json (EXE only)')
    sub.add_parser('fetch')
    a = sub.add_parser('attach')
    a.add_argument('archive'); a.add_argument('launcher'); a.add_argument('output')
    d = sub.add_parser('publish')
    d.add_argument('archive'); d.add_argument('dest', nargs='?', default=str(Path.home()/'.local/share/remote-agents/dist'))
    d.add_argument('--min-launcher', default='1.0.0'); d.add_argument('--launcher')
    a = p.parse_args()
    if a.command == 'make':
        make(a.version, a.outdir, a.launcher, a.product, a.binaries)
    elif a.command == 'fetch':
        fetch()
    elif a.command == 'attach':
        attach_launcher(a.archive, a.launcher, a.output)
    else:
        publish(a.archive, a.dest, a.min_launcher, a.launcher)

if __name__ == '__main__':
    main()
