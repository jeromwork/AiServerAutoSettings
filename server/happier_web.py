#!/usr/bin/env python3
"""Loopback UI service; stdlib only. Releases are inert, signed upstream data."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import mimetypes
import os
from pathlib import Path
import re
import shutil
import sys
import threading
from urllib.parse import unquote, urlsplit

# -I deliberately removes the script directory; this directory is root-owned in production.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from happier_web_common import ADDON, BASE, read_json, settings, resolve_server_url
from happier_web_release import release_path

MIME = {'.js':'text/javascript', '.mjs':'text/javascript', '.wasm':'application/wasm', '.json':'application/json',
        '.css':'text/css', '.svg':'image/svg+xml', '.woff':'font/woff', '.woff2':'font/woff2',
        '.html':'text/html; charset=utf-8', '.webmanifest':'application/manifest+json'}


def hashed(name):
    return bool(re.search(r'(?:^|[./_-])[0-9a-fA-F]{8,}(?=[./_-]|$)', name))


def encodings(header):
    result = {}
    for item in header.split(','):
        bits = item.strip().lower().split(';')
        try:
            quality = float(next((p.strip()[2:] for p in bits[1:] if p.strip().startswith('q=')), '1'))
        except ValueError:
            quality = 0
        result[bits[0]] = quality if 0 <= quality <= 1 else 0
    return result


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # No untrusted request paths or private data in the journal.

    def do_HEAD(self):
        self.do_GET()

    def start_reply(self, length, mime, cache='no-store', encoding=None, vary=False, status=200):
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(length))
        self.send_header('Cache-Control', cache)
        self.send_header('X-Content-Type-Options', 'nosniff')
        if encoding:
            self.send_header('Content-Encoding', encoding)
        if vary:
            self.send_header('Vary', 'Accept-Encoding')
        self.end_headers()

    def reply(self, data, mime, cache='no-store', encoding=None, vary=False, status=200):
        self.start_reply(len(data), mime, cache, encoding, vary, status)
        if self.command != 'HEAD':
            self.wfile.write(data)

    def fail(self):
        self.reply(b'Not found\n', 'text/plain', status=404)

    def do_GET(self):
        try:
            self.serve()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except (OSError, ValueError):
            self.fail()

    def serve(self):
        base = self.server.base
        active = self.server.release or release_path(base)
        path = unquote(urlsplit(self.path).path, errors='strict')
        if any(c in path for c in ('\\', '\x00')) or any(p in ('.', '..') for p in path.split('/')) or path.startswith('//'):
            return self.fail()
        if path == '/_remoteagents/health':
            version = read_json(active / 'release.json', {}).get('uiVersion') if active else None
            return self.reply(json.dumps(dict(ok=bool(version), uiVersion=version)).encode(), 'application/json', status=200 if version else 503)
        if path == '/_remoteagents/quotas':
            data = read_json(base / 'state/quotas.json', dict(schema=1, accounts=[]))
            return self.reply(json.dumps(data, ensure_ascii=False).encode(), 'application/json')
        if path == ADDON:
            script = Path(__file__).with_name('happier_web_addon.js').read_text()
            script = script.replace('__REMOTEAGENTS_KEEP_CHATS__', str(self.server.keep_chats))
            endpoint = resolve_server_url(self.server.home, self.server.server_url) if self.server.home else (self.server.server_url or 'https://api.happier.dev')
            script = script.replace('__REMOTEAGENTS_SERVER_URL__', json.dumps(endpoint, ensure_ascii=True))
            return self.reply(script.encode(), 'text/javascript; charset=utf-8')
        if not active or path.startswith(('/_remoteagents/', '/api/')) or path == '/_remoteagents':
            return self.fail()
        name = path.lstrip('/') or 'index.html'
        roots = [active / 'web']
        if hashed(name):
            roots += [p / 'web' for p in sorted((base / 'releases').glob('ui-web-v*')) if p != active and p.is_dir() and not p.is_symlink()]
        selected = None
        for root in roots:
            candidate = root / name
            # Do not serve symlinked files or symlinked parent directories.
            if candidate.is_file() and not any(p.is_symlink() for p in (candidate, *(root / p for p in candidate.relative_to(root).parents))):
                if candidate.resolve().is_relative_to(root.resolve()):
                    selected = candidate
                    break
        if selected is None:
            if '.' not in Path(name).name and not name.startswith(('assets/', '_expo/', 'vendor/', 'monaco/', 'icons/')):
                selected = active / 'web/index.html'; name = 'index.html'
            else:
                return self.fail()
        if selected.is_symlink() or (active / 'web').is_symlink() or not selected.is_file():
            return self.fail()
        mime = MIME.get(selected.suffix, mimetypes.guess_type(selected.name)[0] or 'application/octet-stream')
        quality = encodings(self.headers.get('Accept-Encoding', ''))
        encoding = None
        # Index and addon must never use an unpatched upstream sidecar.
        if name != 'index.html':
            choices = sorted(((quality.get(e, quality.get('*', 0)), e, s) for e, s in [('br', '.br'), ('gzip', '.gz')]), reverse=True)
            for q, e, suffix in choices:
                sidecar = Path(str(selected) + suffix)
                if q > 0 and sidecar.is_file() and not sidecar.is_symlink():
                    selected, encoding = sidecar, e
                    break
        cache = 'public, max-age=31536000, immutable' if hashed(name) else 'no-store'
        with selected.open('rb') as stream:
            self.start_reply(os.fstat(stream.fileno()).st_size, mime, cache, encoding, vary=True)
            if self.command != 'HEAD':
                shutil.copyfileobj(stream, self.wfile, 64 * 1024)


def make_server(base, port=47831, keep_chats=8, release=None, server_url=None, home=None):
    server = ThreadingHTTPServer(('127.0.0.1', port), Handler)
    server.base, server.keep_chats, server.release = Path(base), keep_chats, release
    server.server_url, server.home = server_url, home
    return server


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['serve', 'update', 'rollback', 'check', 'installed'])
    parser.add_argument('--release-dir', help='local mirror, signature and SHA256 still required')
    args = parser.parse_args()
    base = Path.home() / BASE
    options = settings()
    if args.command == 'serve':
        from happier_web_quotas import Poller
        poller = Poller(Path.home(), base / 'state/quotas.json', options['quotas'])
        threading.Thread(target=poller.run, daemon=True).start()
        server = make_server(base, options['port'], options['keepChats'], server_url=options['serverUrl'], home=Path.home())
        try:
            server.serve_forever()
        finally:
            poller.stop.set(); server.server_close()
    elif args.command in ('check', 'installed'):
        # Local integrity/readiness only; no directory writes in plan/status.
        current = release_path(base)
        if not current or not (current / 'web/index.html').read_text().count(ADDON) == 1:
            raise ValueError('UI not installed')
        if args.command == 'installed':
            return
        import urllib.request
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open('http://127.0.0.1:%s/_remoteagents/health' % options['port'], timeout=3) as response:
            data = json.load(response)
            if data != dict(ok=True, uiVersion=read_json(current / 'release.json', {})['uiVersion']):
                raise ValueError('UI health failed')
    else:
        from happier_web_release import update, rollback
        if args.command == 'rollback':
            rollback(base)
        else:
            update(base, options['keepReleases'], args.release_dir or os.environ.get('REMOTEAGENTS_HAPPIER_WEB_RELEASE_DIR'))


if __name__ == '__main__':
    try:
        main()
    except Exception:
        raise SystemExit('Happier Web: operation failed; private details hidden')
