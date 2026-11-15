#!/usr/bin/env python3
"""Real generated rules + sing-box + local verified DoH/proxy; run only in netns."""
import http.server
import json
from pathlib import Path
import select
import shutil
import socket
import socketserver
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


def receive(sock, count):
    data = b''
    while len(data) < count:
        part = sock.recv(count - len(data))
        if not part:
            raise EOFError(data)
        data += part
    return data


class DnsIntegration(unittest.TestCase):
    def test_direct_doh_and_uncached_tunneled_probe(self):
        with tempfile.TemporaryDirectory(prefix='vpn-dns-test-') as tmp:
            tmp = Path(tmp)
            cert, key = tmp/'cert.pem', tmp/'key.pem'
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                            '-subj', '/CN=127.0.0.1', '-addext', 'subjectAltName=IP:127.0.0.1',
                            '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
            evidence = dict(dns=0, connects=0, broken=False)

            class Https(http.server.BaseHTTPRequestHandler):
                def log_message(self, *args):
                    pass

                def do_POST(self):
                    query = self.rfile.read(int(self.headers['Content-Length']))
                    evidence['dns'] += 1
                    end = 12
                    while query[end]:
                        end += query[end] + 1
                    end += 5
                    # A valid, long-lived answer. The probe must still query on every attempt.
                    answer = query[:2] + struct.pack('!HHHHH', 0x8182 if evidence['broken'] else 0x8180,
                                                     1, 0 if evidence['broken'] else 1, 0, 0) + query[12:end]
                    if not evidence['broken']:
                        answer += b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 3600, 4) + socket.inet_aton('127.0.0.1')
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/dns-message')
                    self.send_header('Content-Length', str(len(answer)))
                    self.end_headers()
                    self.wfile.write(answer)

                def do_GET(self):
                    self.send_response(204)
                    self.end_headers()

            class Proxy(socketserver.BaseRequestHandler):
                def handle(self):
                    request = b''
                    while b'\r\n\r\n' not in request:
                        request += self.request.recv(4096)
                    destination = request.split(b' ')[1].decode()
                    evidence['connects'] += 1
                    host, port = destination.rsplit(':', 1)
                    with socket.create_connection((host, int(port)), timeout=2) as upstream:
                        self.request.sendall(b'HTTP/1.1 200 Connection established\r\n\r\n')
                        peers = [self.request, upstream]
                        while True:
                            ready, _, _ = select.select(peers, [], [], 2)
                            if not ready:
                                return
                            for peer in ready:
                                data = peer.recv(65536)
                                if not data:
                                    return
                                (upstream if peer is self.request else self.request).sendall(data)

            https = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Https)
            tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            tls.load_cert_chain(cert, key)
            https.socket = tls.wrap_socket(https.socket, server_side=True)
            proxy = socketserver.ThreadingTCPServer(('127.0.0.1', 0), Proxy)
            proxy.daemon_threads = True
            for server in (https, proxy):
                threading.Thread(target=server.serve_forever, daemon=True).start()
            process = None
            try:
                port = https.server_port
                script = tmp/'generate.ps1'
                # Test the production generator, retaining its rule order and DNS options.
                script.write_text(". '" + str(ROOT/'transport/Transport.Common.ps1') + "'\n" + f'''
$settings=[pscustomobject]@{{Vpn=[pscustomobject]@{{checkUrl='https://check.invalid:{port}/';dnsServer='127.0.0.1'}}}}
$paths=@{{Candidates=@(@{{tag='path';enabled=$true}});Outbounds=@([pscustomobject]@{{type='http';tag='path';server='127.0.0.1';server_port={proxy.server_address[1]}}})}}
New-VpnTunConfig $settings $paths 'path' @('127.0.0.0/8') 'lo'|ConvertTo-Json -Depth 50
''', encoding='utf-8-sig')
                output = subprocess.check_output([str(Path.home()/'.cache/pwsh-test/pwsh'), '-NoProfile', '-File', str(script)], timeout=20)
                cfg = json.loads(output.decode('utf-8-sig'))
                with socket.socket() as reserve:
                    reserve.bind(('127.0.0.1', 0))
                    listen = reserve.getsockname()[1]
                # Windows TUN is unavailable here; substitute only the ingress.
                cfg['inbounds'] = [dict(type='mixed', tag='vpn-tun', listen='127.0.0.1', listen_port=listen)]
                cfg['log'] = dict(level='debug')
                protected = cfg['dns']['servers'][1]
                protected['server_port'] = port
                protected['tls']['certificate_path'] = str(cert)
                cfg['route']['rules'][2]['strategy'] = 'ipv4_only'
                # Unencrypted bootstrap must never supply the site's/probe's answer.
                cfg['dns']['servers'][0]['server'] = '127.0.0.2'
                config = tmp/'config.json'
                config.write_text(json.dumps(cfg))
                subprocess.run([shutil.which('sing-box'), 'check', '-c', str(config)], check=True, capture_output=True)
                with (tmp/'core.log').open('w+') as log:
                    process = subprocess.Popen([shutil.which('sing-box'), 'run', '-c', str(config)], stdout=log, stderr=log)
                    for _ in range(100):
                        try:
                            with socket.create_connection(('127.0.0.1', listen), timeout=.1):
                                break
                        except OSError:
                            time.sleep(.02)
                    else:
                        self.fail('sing-box did not listen')

                    def probe():
                        with socket.create_connection(('127.0.0.1', listen), timeout=1) as sock:
                            sock.settimeout(1)
                            sock.sendall(b'\x05\x01\x00')
                            self.assertEqual(receive(sock, 2), b'\x05\x00')
                            sock.sendall(b'\x05\x01\x00\x01' + socket.inet_aton('198.18.0.1') + struct.pack('!H', port))
                            header = receive(sock, 4)
                            if header[1] != 0:
                                return False
                            receive(sock, 6 if header[3] == 1 else 18)
                            context = ssl.create_default_context(cafile=str(cert))
                            with context.wrap_socket(sock, server_hostname='127.0.0.1') as stream:
                                stream.sendall(b'GET / HTTP/1.1\r\nHost: check.invalid\r\nConnection: close\r\n\r\n')
                                return b'204' in stream.recv(256)

                    self.assertTrue(probe())
                    first = evidence['dns']
                    self.assertGreater(first, 0)
                    self.assertTrue(probe())
                    self.assertGreater(evidence['dns'], first, 'probe cannot use a cached successful DNS answer')
                    self.assertEqual(evidence['connects'], 2, 'both probes must use the selected path before CIDR exclusions')
                    evidence['broken'] = True
                    began = time.monotonic()
                    try:
                        success = probe()
                    except (EOFError, OSError, ssl.SSLError):
                        success = False
                    self.assertFalse(success, 'a live HTTPS destination cannot hide a failing protected DNS')
                    self.assertLess(time.monotonic() - began, .8)
                    self.assertEqual(evidence['connects'], 2, 'DNS failure must not fall back to UDP or a direct probe')
            finally:
                if process:
                    process.terminate()
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                for server in (https, proxy):
                    server.shutdown()
                    server.server_close()


if __name__ == '__main__':
    unittest.main()
