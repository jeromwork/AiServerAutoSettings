"""Signed UI data only: never execute release contents or install scripts."""
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

from happier_web_common import ADDON, atomic, private_dir, read_json

SOURCE = Path(__file__).resolve().parent
GITHUB = 'https://api.github.com/repos/happier-dev/happier/releases'
VERSION = r'ui-web-v(\d+\.\d+\.\d+)'


def inject(index):
    # Re-running injection is safe, but reject an upstream collision with our URL.
    tag = '<script src="' + ADDON + '"></script>'
    index = index.replace(tag, '')
    if ADDON in index:
        raise ValueError('unexpected addon markup')
    head = re.search(r'<head\b[^>]*>', index, re.I)
    if not head or re.search(r'<script\b', index[:head.end()], re.I):
        raise ValueError('unsupported UI head')
    result = index[:head.end()] + tag + index[head.end():]
    if not re.search(r'</head\s*>', result, re.I) or not re.search(r'<script\b[^>]*src=', index, re.I):
        raise ValueError('UI bundle missing')
    return result


def verify_signature(checksums, signature):
    result = subprocess.run(['node', str(SOURCE / 'happier_web_verify.cjs'), str(checksums), str(signature)],
                            capture_output=True, timeout=20)
    if result.returncode:
        raise ValueError('release signature rejected')


def verify_sha(archive, checksums):
    entries = {}
    for line in Path(checksums).read_text().splitlines():
        match = re.fullmatch(r'([a-fA-F0-9]{64}) [ *](\S+)', line)
        if not match or match[2] in entries:
            raise ValueError('invalid checksums')
        entries[match[2]] = match[1].lower()
    with Path(archive).open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else None
        if digest is None:
            h = hashlib.sha256()
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                h.update(block)
            digest = h.hexdigest()
    if entries.get(Path(archive).name) != digest:
        raise ValueError('archive SHA256 rejected')


def extract(archive, dest):
    """Validate the entire table before writing anything. No tarfile.extract()."""
    with tarfile.open(archive, 'r:gz') as tar:
        members = tar.getmembers()
        if not members or len(members) > 30000 or sum(m.size for m in members) > 1024 * 1024 * 1024:
            raise ValueError('archive limits')
        seen, roots = set(), set()
        for member in members:
            name = member.name.rstrip('/')
            parts = name.split('/')
            if (not name or name.startswith('/') or '\\' in name or
                    any(p in ('', '.', '..') for p in parts) or
                    any(ord(c) < 32 for c in name) or not (member.isfile() or member.isdir()) or name in seen):
                raise ValueError('unsafe archive entry')
            seen.add(name); roots.add(parts[0])
        if len(roots) != 1:
            raise ValueError('expected one release root')
        root = roots.pop()
        for member in members:
            parts = PurePosixPath(member.name).parts[1:]
            target = dest.joinpath(*parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True, mode=0o700)
            else:
                if not parts:
                    raise ValueError('release root must be directory')
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                with tar.extractfile(member) as src, target.open('xb') as out:
                    shutil.copyfileobj(src, out)
                target.chmod(0o600)
    if not (dest / 'index.html').is_file():
        raise ValueError('index missing')


def release_path(base, link='current'):
    pointer = base / link
    if not pointer.is_symlink():
        return None
    target = pointer.resolve()
    if target.parent != (base / 'releases').resolve() or not re.fullmatch(VERSION, target.name):
        return None
    return target if (target / 'web/index.html').is_file() else None


def switch(base, link, target):
    tmp = base / ('.' + link + '-next')
    tmp.unlink(missing_ok=True)
    tmp.symlink_to('releases/' + target.name)
    os.replace(tmp, base / link)


def smoke(base, release):
    # Exercise the actual handler before publishing the pointer, on ephemeral loopback.
    from happier_web import make_server
    import threading
    server = make_server(base, port=0, release=release)
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open('http://127.0.0.1:%s/' % server.server_port, timeout=5) as response:
            html = response.read().decode()
            if html.count(ADDON) != 1 or html.index(ADDON) > html.lower().index('</head>'):
                raise ValueError('UI smoke check failed')
        with opener.open('http://127.0.0.1:%s%s' % (server.server_port, ADDON), timeout=5) as response:
            if b'__HAPPIER_WEB_RUNTIME_CONFIG__' not in response.read():
                raise ValueError('addon smoke check failed')
    finally:
        server.shutdown(); server.server_close(); thread.join()


def install(base, tag, archive, checksums, signature, keep=2):
    if not re.fullmatch(VERSION, tag):
        raise ValueError('unsupported UI version')
    verify_signature(checksums, signature)
    verify_sha(archive, checksums)
    releases = private_dir(base / 'releases')
    old = release_path(base)
    dest = releases / tag
    if old == dest:
        return False
    with tempfile.TemporaryDirectory(prefix='.staging-', dir=base) as tmp:
        stage = Path(tmp); web = private_dir(stage / 'web')
        extract(archive, web)
        index = web / 'index.html'
        atomic(index, inject(index.read_text()))
        # Stale precompressed index would skip the injected script.
        for suffix in ('.gz', '.br'):
            (web / ('index.html' + suffix)).unlink(missing_ok=True)
        for path in (archive, checksums, signature):
            shutil.copyfile(path, stage / Path(path).name)
        atomic(stage / 'release.json', json.dumps({'uiVersion': tag, 'installedAt': __import__('time').time()}))
        smoke(base, stage)
        # An orphan of an interrupted install is never a serving release.
        if dest == release_path(base, 'previous'):
            # Re-publish a previously verified release after rollback only when
            # its web tree still equals the freshly verified archive + injection.
            import filecmp
            wanted = {p.relative_to(web) for p in web.rglob('*') if p.is_file()}
            existing = dest / 'web'
            if wanted != {p.relative_to(existing) for p in existing.rglob('*') if p.is_file()} or any(
                    (existing / name).is_symlink() or not filecmp.cmp(web / name, existing / name, shallow=False) for name in wanted):
                raise ValueError('retained release differs from signed data')
        else:
            if dest.exists():
                shutil.rmtree(dest)
            os.replace(stage, dest)
        if old:
            switch(base, 'previous', old)
        switch(base, 'current', dest)
    # Keep current + previous even if a caller supplies an invalid retention count.
    retained = {dest, old}
    candidates = sorted((p for p in releases.iterdir() if re.fullmatch(VERSION, p.name) and p.is_dir() and not p.is_symlink()),
                        key=lambda p: read_json(p / 'release.json', {}).get('installedAt', 0), reverse=True)
    for candidate in candidates:
        if len(retained - {None}) >= max(2, keep):
            break
        retained.add(candidate)
    for path in candidates:
        if path not in retained:
            shutil.rmtree(path)
    return True


def download(url, dest, limit):
    if not url.startswith('https://'):
        raise ValueError('HTTPS required')
    req = urllib.request.Request(url, headers={'User-Agent': 'RemoteAgents-HappierWeb', 'Accept': 'application/vnd.github+json'})
    with urllib.request.urlopen(req, timeout=90) as response, dest.open('xb') as out:
        if not response.url.startswith('https://'):
            raise ValueError('HTTPS redirect required')
        count = 0
        for chunk in iter(lambda: response.read(1024 * 1024), b''):
            count += len(chunk)
            if count > limit:
                raise ValueError('download too large')
            out.write(chunk)


def update(base, keep=2, mirror=None):
    private_dir(base)
    with (base / 'update.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        for pattern in ('.staging-*', '.download-*'):
            for abandoned in base.glob(pattern):
                if abandoned.is_dir() and not abandoned.is_symlink():
                    shutil.rmtree(abandoned)
        if mirror:
            # Offline signed mirror for acceptance tests/air-gapped installs. Same pin/checks.
            directory = Path(mirror)
            checks = sorted(directory.glob('checksums-happier-ui-web-v*.txt'))
            choices = []
            for path in checks:
                match = re.fullmatch(r'checksums-happier-ui-web-v(\d+\.\d+\.\d+)\.txt', path.name)
                if match:
                    choices.append((tuple(map(int, match[1].split('.'))), path))
            if not choices:
                raise ValueError('signed mirror empty')
            _, checksums = max(choices)
            version = checksums.name[len('checksums-happier-ui-web-v'):-4]
            return install(base, 'ui-web-v' + version, directory / ('happier-ui-web-v' + version + '-web-any.tar.gz'),
                           checksums, Path(str(checksums) + '.minisig'), keep)
        with tempfile.TemporaryDirectory(prefix='.download-', dir=base) as tmp:
            stage = Path(tmp)
            found = []
            # UI tags share the repository with CLI releases; /latest is not a UI channel.
            for page in range(1, 21):
                listing = stage / ('releases-%s.json' % page)
                download(GITHUB + '?per_page=100&page=' + str(page), listing, 16 * 1024 * 1024)
                items = json.loads(listing.read_text())
                for item in items:
                    if not item.get('prerelease') and not item.get('draft') and re.fullmatch(VERSION, item.get('tag_name', '')):
                        found.append(item)
                if found or len(items) < 100:
                    break
            if not found:
                raise ValueError('stable UI release not found')
            latest = max(found, key=lambda x: x.get('published_at', ''))
            tag = latest['tag_name']; version = re.fullmatch(VERSION, tag)[1]
            if release_path(base) == base / 'releases' / tag:
                return False
            names = ['happier-ui-web-v' + version + '-web-any.tar.gz', 'checksums-happier-ui-web-v' + version + '.txt']
            names.append(names[1] + '.minisig')
            assets = {a['name']: a['browser_download_url'] for a in latest['assets']}
            # Authenticate checksums before spending bandwidth on the archive.
            for name in names[1:]:
                download(assets[name], stage / name, 2 * 1024 * 1024)
            verify_signature(stage / names[1], stage / names[2])
            download(assets[names[0]], stage / names[0], 512 * 1024 * 1024)
            return install(base, tag, *(stage / n for n in names), keep=keep)


def rollback(base):
    with (base / 'update.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        previous, current = release_path(base, 'previous'), release_path(base)
        if not previous:
            raise ValueError('no previous release')
        smoke(base, previous)
        switch(base, 'current', previous)
        if current:
            switch(base, 'previous', current)
