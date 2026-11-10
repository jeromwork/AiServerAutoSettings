#!/usr/bin/env python3
"""Foreground SSH session broker. Secret arrives once via stdin, never argv/disk."""
import argparse
import json
import os
import select
import socket
import stat
import sys
import time
from server_node_catalog import matches

MAX = 262144


def read_line(stream, limit=MAX):
    data = stream.readline(limit + 1)
    if not data or len(data) > limit or not data.endswith(b"\n"):
        raise ValueError("invalid or oversized frame")
    return data


def serve(path, config, parent_stdin, heartbeat_interval=15, heartbeat_timeout=5):
    if not isinstance(config.get("token"), str) or len(config["token"]) != 64:
        raise ValueError("invalid session token")
    port = config.get("port")
    if not isinstance(port, int) or not 1024 <= port <= 65535:
        raise ValueError("invalid forwarding port")
    path = os.path.abspath(os.path.expanduser(path))
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    info = os.lstat(directory)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("session directory must be owner-only (0700)")
    # Never unlink another active session or an untrusted file.
    if os.path.lexists(path):
        info = os.lstat(path)
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError("unsafe existing session path")
        with socket.socket(socket.AF_UNIX) as check:
            check.settimeout(1)
            try:
                check.connect(path)
            except ConnectionRefusedError:
                os.unlink(path)
            else:
                raise ValueError("device already connected")
    server = socket.socket(socket.AF_UNIX)
    def forward(request, timeout=100):
        request = dict(request, token=config['token'])
        payload = json.dumps(request, separators=(',', ':')).encode()+b'\n'
        if len(payload)>MAX:
            raise ValueError('Request too large')
        with socket.create_connection(('127.0.0.1', port), timeout=5) as remote:
            remote.settimeout(timeout)
            remote.sendall(payload)
            return read_line(remote.makefile('rb'))
    try:
        server.bind(path)
        os.chmod(path, 0o600)
        server.listen(4)
        print(json.dumps({"state": "connected", "device": config.get("device", "windows")}), flush=True)
        next_heartbeat = time.monotonic()
        failures = 0
        while True:
            if config.get('heartbeat') and time.monotonic() >= next_heartbeat:
                try:
                    binding = {key:config.get(key) for key in ('projectId','hostId','deviceLabel','windowsReplica')}
                    reply = json.loads(forward(dict(op='status', args={}, binding=binding), heartbeat_timeout))
                    if reply.get('ok') is not True:
                        raise ValueError('heartbeat refused')
                    if config.get('hostId') and not matches(config, reply):
                        raise ValueError('heartbeat binding mismatch')
                    failures = 0
                    print('{"state":"heartbeat"}', flush=True)
                except Exception:
                    failures += 1
                    print('{"state":"unavailable"}', flush=True)
                    if failures >= 3:
                        raise ConnectionError('reverse forwarding heartbeat failed')
                next_heartbeat = time.monotonic() + heartbeat_interval
            ready, _, _ = select.select([server, parent_stdin], [], [], max(0, next_heartbeat-time.monotonic()) if config.get('heartbeat') else None)
            if not ready:
                continue
            if parent_stdin in ready:
                # EOF means Windows launcher/SSH disappeared; no persistent secret.
                break
            client, _ = server.accept()
            with client:
                client.settimeout(100)
                try:
                    request = json.loads(read_line(client.makefile("rb")))
                    if not isinstance(request, dict) or set(request) - {"op", "args", "binding"}:
                        raise ValueError("invalid request")
                    expected=request.get('binding')
                    if config.get('hostId') and expected != {key:config.get(key) for key in ('projectId','hostId','deviceLabel','windowsReplica')}:
                        raise ValueError('Explicit target binding required')
                    result=forward(request)
                    client.sendall(result)
                except Exception:
                    # Never leak token, command, paths, or upstream exception text.
                    try:
                        client.sendall(b'{"ok":false,"error":"Windows unavailable or invalid request"}\n')
                    except OSError:
                        pass
    finally:
        server.close()
        if os.path.exists(path):
            os.unlink(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    args = parser.parse_args()
    try:
        config = json.loads(read_line(sys.stdin.buffer, 4096))
        serve(args.socket, config, sys.stdin.buffer)
    except Exception:
        print("Bridge session could not start; check device label, private session directory and forwarding.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
