"""Ubuntu-only bounded offline tests; never opens real user config or SSH."""
import argparse
import json
import os
import select
import socket
import subprocess
import sys
import tempfile
import threading
import tomllib
from pathlib import Path


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def reconnect_test(adapter, directory):
    path = str(directory / "fixture.sock")
    process = subprocess.Popen(
        [sys.executable, "-I", str(adapter), "--socket", path],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    sequence = 0

    def request(method, params):
        nonlocal sequence
        sequence += 1
        process.stdin.write((json.dumps({"jsonrpc": "2.0", "id": sequence, "method": method, "params": params}) + "\n").encode())
        process.stdin.flush()
        check(bool(select.select([process.stdout], [], [], 5)[0]), "adapter response timeout")
        response = json.loads(process.stdout.readline())
        check(response.get("id") == sequence and "result" in response, "invalid MCP response")
        return response["result"]

    def status():
        return request("tools/call", {"name": "windows_status", "arguments": {}})

    def online(marker):
        server = socket.socket(socket.AF_UNIX)
        server.bind(path)
        os.chmod(path, 0o600)
        server.listen(1)
        errors = []

        def serve():
            try:
                server.settimeout(5)
                with server.accept()[0] as client:
                    client.settimeout(5)
                    message = json.loads(client.makefile("rb").readline(262145))
                    check(message == {"op": "status", "args": {}}, "unexpected broker request")
                    client.sendall((json.dumps({"ok": True, "result": {"fixture": marker}}) + "\n").encode())
            except Exception as error:
                errors.append(error)

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        try:
            result = status()
            thread.join(6)
            check(not thread.is_alive() and not errors, "fixture broker failure")
            check(not result["isError"], "online status failed")
            check(json.loads(result["content"][0]["text"])["result"]["fixture"] == marker, "stale broker response")
        finally:
            server.close()
            Path(path).unlink(missing_ok=True)

    try:
        check(request("initialize", {"protocolVersion": "2025-03-26"})["serverInfo"]["name"] == "windows-bridge", "offline initialize failed")
        check(len(request("tools/list", {})["tools"]) == 8, "offline tools unavailable")
        check(status()["isError"], "offline status falsely ready")
        online("first")
        check(status()["isError"], "disconnect status falsely ready")
        online("reconnected")
        print("PASS: one persistent MCP process initializes offline and reconnects to a replaced broker")
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
        process.stdout.close()
        process.stderr.close()


def registration_test(codex, adapter, directory):
    home = directory / "isolated-home"
    config_home = home / ".codex"
    config_home.mkdir(parents=True, mode=0o700)
    config = config_home / "config.toml"
    config.write_text('[mcp_servers.keep_fixture]\ncommand = "/usr/bin/printf"\nargs = ["keep-fixture"]\n', encoding="utf-8")
    name = "windows-win-" + "0" * 28
    args = ["--socket", str(directory / "unused.sock")]
    # Explicit minimal child environment: no inherited authentication or GUI profile.
    environment = {"PATH": "/usr/bin:/bin", "HOME": str(home), "CODEX_HOME": str(config_home), "LANG": "C.UTF-8"}
    result = subprocess.run([str(codex), "mcp", "add", name, "--", "python3", str(adapter), *args], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
    check(result.returncode == 0, "official CLI fixture registration failed")
    fixture = tomllib.loads(config.read_text(encoding="utf-8"))["mcp_servers"]
    check(fixture["keep_fixture"] == {"command": "/usr/bin/printf", "args": ["keep-fixture"]}, "unrelated fixture MCP changed")
    check(fixture[name]["command"] == "python3" and fixture[name]["args"] == [str(adapter), *args], "registration arguments changed")
    print("PASS: official codex mcp add preserved unrelated MCP entry in isolated CODEX_HOME")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--adapter", required=True, type=Path)
    parser.add_argument("--codex", required=True, type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="bridge-gui-fixture-") as temporary:
        directory = Path(temporary)
        reconnect_test(args.adapter.resolve(), directory)
        registration_test(args.codex.resolve(), args.adapter.resolve(), directory)


if __name__ == "__main__":
    main()
