#!/usr/bin/env python3
"""Foreground SSH session broker. Secret arrives once via stdin, never argv/disk."""
import argparse
import json
import os
import select
import socket
import stat
import sys

MAX = 262144
FORWARD_TIMEOUT = 100  # seconds a Windows executor may take to answer


class Refusal(Exception):
    """Failure with a fixed machine-readable reason; carries no upstream text."""
    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


def refusal(reason):
    # Fixed vocabulary only: never leak token, command, paths or exception text.
    return json.dumps({"ok": False, "error": "Windows unavailable or invalid request", "reason": reason}, separators=(",", ":")).encode() + b"\n"


def read_line(stream, limit=MAX):
    data = stream.readline(limit + 1)
    if not data or len(data) > limit or not data.endswith(b"\n"):
        raise ValueError("invalid or oversized frame")
    return data


def serve(path, config, parent_stdin):
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
    def forward(request):
        request = dict(request, token=config['token'])
        payload = json.dumps(request, separators=(',', ':')).encode()+b'\n'
        if len(payload)>MAX:
            raise Refusal('invalid-request')
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=5) as remote:
                remote.settimeout(FORWARD_TIMEOUT)
                remote.sendall(payload)
                reply = remote.makefile('rb').readline(MAX + 1)
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
    try:
        server.bind(path)
        os.chmod(path, 0o600)
        server.listen(4)
        print(json.dumps({"state": "connected", "device": config.get("device", "windows")}), flush=True)
        while True:
            ready, _, _ = select.select([server, parent_stdin], [], [])
            if parent_stdin in ready:
                # EOF means Windows launcher/SSH disappeared; no persistent secret.
                break
            client, _ = server.accept()
            with client:
                client.settimeout(100)
                try:
                    try:
                        request = json.loads(read_line(client.makefile("rb")))
                    except (ValueError, OSError):
                        raise Refusal('invalid-request') from None
                    if not isinstance(request, dict) or set(request) - {"op", "args", "binding"}:
                        raise Refusal('invalid-request')
                    expected=request.get('binding')
                    if config.get('hostId') and expected != {key:config.get(key) for key in ('projectId','hostId','deviceLabel','windowsReplica')}:
                        raise Refusal('binding-mismatch')
                    result=forward(request)
                    client.sendall(result)
                except Exception as error:
                    # Never leak token, command, paths, or upstream exception text.
                    reason = error.reason if isinstance(error, Refusal) else 'internal-error'
                    try:
                        client.sendall(refusal(reason))
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
