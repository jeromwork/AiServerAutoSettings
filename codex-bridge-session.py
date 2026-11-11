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
import threading
from server_node_catalog import matches

MAX = 262144
FORWARD_TIMEOUT = 100  # seconds a Windows executor may take to answer


class Refusal(Exception):
    """Failure with a fixed machine-readable reason; carries no upstream text."""
    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


def refusal(reason, error="Windows unavailable or invalid request"):
    # Fixed vocabulary only: never leak token, command, paths or exception text.
    return json.dumps({"ok": False, "error": error, "reason": reason}, separators=(",", ":")).encode() + b"\n"


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
    slots = threading.BoundedSemaphore(64)
    connections = set()
    connection_lock = threading.Lock()
    stopping = threading.Event()
    active_requests = 0
    concurrent_executor = False

    def track(conn):
        with connection_lock:
            if stopping.is_set():
                conn.close()
                raise ConnectionError('Session stopped')
            connections.add(conn)

    def forward(request, timeout=None):
        request = dict(request, token=config['token'])
        payload = json.dumps(request, separators=(',', ':')).encode()+b'\n'
        if len(payload)>MAX:
            raise Refusal('invalid-request')
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=5) as remote:
                track(remote)
                try:
                    remote.settimeout(timeout or FORWARD_TIMEOUT)
                    remote.sendall(payload)
                    with remote.makefile('rb') as stream:
                        reply = stream.readline(MAX + 1)
                finally:
                    with connection_lock:
                        connections.discard(remote)
        except socket.timeout:
            raise Refusal('windows-timeout') from None
        except ConnectionRefusedError:
            # Reverse-forward port is not listening: the SSH tunnel is gone.
            raise Refusal('tunnel-down') from None
        except OSError:
            raise Refusal('windows-no-reply') from None
        if not reply:
            # Tunnel accepted, but the Windows executor closed without a frame.
            raise Refusal('windows-no-reply')
        if len(reply) > MAX or not reply.endswith(b'\n'):
            raise Refusal('windows-invalid-reply')
        return reply
    def handle(client):
        nonlocal active_requests
        forwarding = False
        try:
            with client:
                client.settimeout(100)
                try:
                    try:
                        with client.makefile("rb") as stream:
                            request = json.loads(read_line(stream))
                    except (ValueError, OSError):
                        raise Refusal('invalid-request') from None
                    if not isinstance(request, dict) or set(request) - {"op", "args", "binding"}:
                        raise Refusal('invalid-request')
                    expected = request.get('binding')
                    if config.get('hostId') and expected != {key:config.get(key) for key in ('projectId','hostId','deviceLabel','windowsReplica')}:
                        raise Refusal('binding-mismatch')
                    with connection_lock:
                        active_requests += 1
                        forwarding = True
                    client.sendall(forward(request))
                except Exception as error:
                    # Never leak token, command, paths, or upstream exception text.
                    reason = error.reason if isinstance(error, Refusal) else 'internal-error'
                    try:
                        client.sendall(refusal(reason))
                    except OSError:
                        pass
        finally:
            with connection_lock:
                connections.discard(client)
                if forwarding:
                    active_requests -= 1
            slots.release()

    try:
        server.bind(path)
        os.chmod(path, 0o600)
        server.listen(128)
        print(json.dumps({"state": "connected", "device": config.get("device", "windows")}), flush=True)
        next_heartbeat = time.monotonic()
        failures = 0
        while True:
            if config.get('heartbeat') and time.monotonic() >= next_heartbeat:
                with connection_lock:
                    legacy_busy = not concurrent_executor and active_requests > 0
                # A legacy executor services one socket at a time. Its long command
                # must not cause three heartbeat timeouts and a false disconnection.
                if legacy_busy:
                    next_heartbeat = time.monotonic() + heartbeat_interval
                    continue
                try:
                    binding = {key:config.get(key) for key in ('projectId','hostId','deviceLabel','windowsReplica')}
                    reply = json.loads(forward(dict(op='status', args={}, binding=binding), heartbeat_timeout))
                    if reply.get('ok') is not True:
                        raise ValueError('heartbeat refused')
                    if config.get('hostId') and not matches(config, reply):
                        raise ValueError('heartbeat binding mismatch')
                    concurrent_executor = reply.get('coordination', {}).get('exclusive') is True
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
            if not slots.acquire(blocking=False):
                try:
                    client.settimeout(1)
                    client.sendall(refusal('busy', 'Too many concurrent bridge requests (64)'))
                finally:
                    client.close()
                continue
            try:
                track(client)
            except Exception:
                slots.release()
                raise
            threading.Thread(target=handle, args=(client,), daemon=True).start()
    finally:
        stopping.set()
        with connection_lock:
            for conn in connections:
                try:
                    conn.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                conn.close()
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
