"""Loopback-only Clash WebSocket fixture. Append {stream, data} JSON lines to ws.jsonl.
The two subscriptions independently consume their stream; reconnects skip old records.
Only unmasked server text frames are needed by the real reader B.
"""
import base64
import hashlib
import json
import struct
import time
from urllib.parse import urlsplit


def frame(value):
    data = json.dumps(value).encode()
    n = len(data)
    return b'\x81' + (bytes([n]) if n < 126 else b'\x7e' + struct.pack('!H', n)
                      if n < 65536 else b'\x7f' + struct.pack('!Q', n)) + data


def websocket(handler, root, secret):
    if handler.path not in ('/logs?level=warn', '/connections?interval=1000'):
        handler.send_error(404)
        return
    if handler.headers.get('Authorization') != 'Bearer ' + secret:
        handler.send_error(401)
        return
    key = handler.headers['Sec-WebSocket-Key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
    handler.send_response(101)
    handler.send_header('Upgrade', 'websocket')
    handler.send_header('Connection', 'Upgrade')
    handler.send_header('Sec-WebSocket-Accept', base64.b64encode(hashlib.sha1(key.encode()).digest()).decode())
    handler.end_headers()
    stream = urlsplit(handler.path).path[1:]
    with (root / 'subscriptions.jsonl').open('a') as f:
        f.write(json.dumps(dict(stream=stream, at=time.time())) + '\n')
    queue = root / 'ws.jsonl'
    with queue.open() as f:
        f.seek(0, 2)
        try:
            while True:
                position = f.tell()
                line = f.readline()
                if not line.endswith('\n'):
                    f.seek(position)
                    time.sleep(.03)
                    continue
                item = json.loads(line)
                if item['stream'] == stream:
                    handler.connection.sendall(frame(item['data']))
        except (OSError, ConnectionError):
            pass
