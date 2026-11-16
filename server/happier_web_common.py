"""Shared private state; custom serving is needed for retained chunks and the head add-on."""
import json
import os
from pathlib import Path
import tempfile
from urllib.parse import urlsplit

ADDON = '/_remoteagents/addon.js'
BASE = '.local/share/remoteagents-happier-web'


def private_dir(path):
    path = Path(path)
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError('symlink state directory')
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)
    return path


def atomic(path, data):
    path = Path(path)
    private_dir(path.parent)
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as out:
            os.fchmod(out.fileno(), 0o600)
            out.write(data.encode() if isinstance(data, str) else data)
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp, path)
    finally:
        Path(tmp).unlink(missing_ok=True)


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return default


def settings(home=None):
    home = Path(home or Path.home())
    item = read_json(home / '.config/remoteagents/happier-web.json', {})
    return dict(port=item.get('port', 47831), keepReleases=item.get('keepReleases', 2),
                keepChats=item.get('keepChats', 8), quotas=item.get('quotas', {}), serverUrl=item.get('serverUrl'))


def server_origin(value):
    if not isinstance(value, str):
        raise ValueError('invalid Happier server URL')
    parsed = urlsplit(value)
    if (parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username is not None or
            parsed.password is not None or parsed.query or parsed.fragment or parsed.path not in ('', '/') or
            any(ord(c) < 33 for c in value)):
        raise ValueError('invalid Happier server URL')
    parsed.port  # validate port syntax and range
    return parsed.scheme + '://' + parsed.netloc


def resolve_server_url(home, configured=None):
    if configured is not None:
        return server_origin(configured)
    native = read_json(Path(home) / '.happier/settings.json', {})
    if isinstance(native, dict):
        servers = native.get('servers')
        active = native.get('activeServerId') or 'cloud'
        profile = servers.get(active) if isinstance(servers, dict) and isinstance(active, str) else None
        if isinstance(profile, dict):
            try:
                return server_origin(profile.get('serverUrl'))
            except ValueError:
                pass
    return 'https://api.happier.dev'
