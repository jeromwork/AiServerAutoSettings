#!/usr/bin/env python3
"""Isolated stand: authenticated CONNECT proxy + TLS IP oracle. No host install."""
import base64
import http.server
import select
import socket
import socketserver
import ssl
import threading
from pathlib import Path

class Origin(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'8.8.8.8\n')
    def log_message(self, *args):
        pass

class Connect(socketserver.StreamRequestHandler):
    def handle(self):
        first = self.rfile.readline().decode().strip()
        headers = {}
        while True:
            line = self.rfile.readline().decode().strip()
            if not line:
                break
            k, _, v = line.partition(':'); headers[k.lower()] = v.strip()
        if headers.get('proxy-authorization') != 'Basic ' + base64.b64encode(b'fixture:PROXY_SENTINEL').decode():
            self.wfile.write(b'HTTP/1.1 407 Proxy Authentication Required\r\n\r\n'); return
        target = first.split()[1]
        if target != '11.123.45.67:8443':
            self.wfile.write(b'HTTP/1.1 403 Forbidden\r\n\r\n'); return
        with socket.create_connection(('127.0.0.1', 8443)) as peer:
            self.wfile.write(b'HTTP/1.1 200 Connection established\r\n\r\n'); self.wfile.flush()
            with Path('/run/proxy-connections').open('a') as log:
                log.write('CONNECT ip-oracle\n')
            for _ in range(10000):
                ready, _, _ = select.select([self.connection, peer], [], [], 30)
                if not ready:
                    return
                for source in ready:
                    data = source.recv(65536)
                    if not data:
                        return
                    (peer if source is self.connection else self.connection).sendall(data)

origin = http.server.ThreadingHTTPServer(('0.0.0.0', 8443), Origin)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain('/run/origin.crt', '/run/origin.key')
origin.socket = ctx.wrap_socket(origin.socket, server_side=True)
threading.Thread(target=origin.serve_forever, daemon=True).start()
with socketserver.ThreadingTCPServer(('0.0.0.0', 3128), Connect) as server:
    server.daemon_threads = True; server.serve_forever()
