#!/usr/bin/env python3
"""One-time HTTP download link for a handout ZIP (EXE + config).

Why own code: the owner wants a plain link to click instead of PowerShell; the
standard http.server cannot serve a file exactly once or expire. Kept minimal.

The link opens a small page with a «Скачать» button: chat apps that fetch the
link for a preview only get the page, so the file itself is not consumed.
After one complete download (or on expiry) the server exits and deletes the file.
"""
import argparse, html, http.server, os, secrets, sys, threading, time, urllib.parse

def main():
    p = argparse.ArgumentParser(description='одноразовая ссылка на скачивание')
    p.add_argument('file')
    p.add_argument('--host', required=True, help='публичный адрес сервера для ссылки')
    p.add_argument('--port', type=int, default=18080)
    p.add_argument('--minutes', type=int, default=60)
    p.add_argument('--keep', action='store_true', help='не удалять файл после скачивания')
    a = p.parse_args()
    path = os.path.abspath(a.file); name = os.path.basename(path); size = os.path.getsize(path)
    token = secrets.token_urlsafe(18); done = threading.Event()

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def deny(self):
            self.send_response(404); self.send_header('Content-Length', '0'); self.end_headers()
        def do_GET(self):
            route = urllib.parse.urlsplit(self.path).path
            if done.is_set(): return self.deny()
            if route == '/' + token:
                body = ('<!doctype html><meta charset="utf-8"><title>RemoteAgents</title>'
                        '<body style="font-family:sans-serif;margin:3em">'
                        '<h2>RemoteAgents</h2><p>Архив с программой и конфигом. Ссылка одноразовая.</p>'
                        '<p><a href="/' + token + '/' + urllib.parse.quote(name) + '" style="font-size:1.4em">Скачать '
                        + html.escape(name) + ' (' + str(size // (1024 * 1024)) + ' МБ)</a></p>').encode()
                self.send_response(200); self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body); return
            if route != '/' + token + '/' + urllib.parse.quote(name) and urllib.parse.unquote(route) != '/' + token + '/' + name:
                return self.deny()
            self.send_response(200); self.send_header('Content-Type', 'application/zip')
            self.send_header('Content-Disposition', 'attachment; filename="' + name + '"')
            self.send_header('Content-Length', str(size)); self.end_headers()
            sent = 0
            try:
                with open(path, 'rb') as f:
                    while True:
                        chunk = f.read(65536)
                        if not chunk: break
                        self.wfile.write(chunk); sent += len(chunk)
            except (BrokenPipeError, ConnectionResetError):
                return  # interrupted: the link stays valid until expiry
            if sent == size:
                print('скачано полностью', flush=True); done.set()

    server = http.server.ThreadingHTTPServer(('0.0.0.0', a.port), H)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print('http://%s:%d/%s' % (a.host, a.port, token), flush=True)
    done.wait(a.minutes * 60)
    if not done.is_set(): print('срок ссылки истёк', flush=True)
    time.sleep(2); server.shutdown()
    if not a.keep:
        try: os.remove(path)
        except OSError: pass

if __name__ == '__main__':
    sys.exit(main())
