"""Run in local WSL: real Linux MCP/broker -> fixture TCP/stdio relay -> real
Windows PowerShell executor. The sync hook copies a fixture; this is NOT a live
SSH/Syncthing/model acceptance. Windows deployment never requires Python.
"""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import secrets
import socket
import stat
import subprocess
import tempfile
import threading
import time
import unittest
import types
from unittest.mock import patch

HERE = Path(__file__).resolve().parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


handoff = load("agent_handoff", "server-agent-handoff.py")
broker = load("handoff_broker", "codex-bridge-session.py")


def metadata():
    label = "win-" + "a" * 28
    return {"schema": 1, "projectId": "p-fixture", "hostId": "fixture-host", "deviceLabel": label, "serverWorkspace": str(handoff.USER_HOME / "work/projects/p-fixture"), "windowsReplica": "C:\\fixture\\replica", "socketPath": str(handoff.USER_HOME / ".local/state/codex-remote" / (label + ".sock")), "agents": "3", "allowShell": True}


class HandoffTests(unittest.TestCase):
    def test_binding_and_instructions(self):
        data = metadata()
        handoff.validate(data)
        directory = handoff.handoff_directory(data)
        message = handoff.prompt(data, directory)
        for required in (data["projectId"], data["hostId"], data["windowsReplica"], "windows_status", "windows_command", "НОВЫЙ sync_barrier", "НЕ запуск модели", "не делай push/PR", "exclusive=true", "выполняются параллельно", "чужие poll/stop отклоняются"):
            self.assertIn(required, message)
        for name, value in (("projectId", "../outside"), ("serverWorkspace", "/tmp/other"), ("socketPath", "/tmp/unbound.sock"), ("agents", "0"), ("windowsReplica", "relative")):
            invalid = dict(data, **{name: value})
            with self.assertRaises(ValueError):
                handoff.validate(invalid)

    def test_cli_keeps_approvals_and_scope(self):
        data = metadata()
        for agent in ("codex", "claude"):
            calls = []
            with patch.object(handoff, "owned"), patch.object(handoff.os, "chdir"), patch.object(handoff.os, "execv", side_effect=lambda exe, args: calls.append(args)):
                handoff.launch(data, handoff.handoff_directory(data), agent)
            args = calls[0]
            self.assertFalse(any("bypass" in value or "danger-full" in value or value == "never" for value in args))
            if agent == "codex":
                self.assertIn("workspace-write", args)
                self.assertIn("on-request", args)
                self.assertIn(str(Path(data["serverWorkspace"])), args)
            else:
                self.assertIn("--strict-mcp-config", args)
                self.assertIn("default", args)


class FixtureUnixSocket:
    """TEST ONLY: a named Unix socket replaced by real owner-local TCP on Windows."""
    def __init__(self, *_args):
        self.inner = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    def bind(self, path):
        self.inner.bind(("127.0.0.1", 0))
        Path(path).write_text(str(self.inner.getsockname()[1]), encoding="ascii")
    def connect(self, path):
        self.inner.connect(("127.0.0.1", int(Path(path).read_text(encoding="ascii"))))
    def __getattr__(self, name):
        return getattr(self.inner, name)
    def __enter__(self):
        return self
    def __exit__(self, *_args):
        self.inner.close()


FIXTURE_SOCKET = types.SimpleNamespace(AF_UNIX=-999, socket=FixtureUnixSocket, create_connection=socket.create_connection)


@unittest.skipUnless(os.name == "nt", "Windows local TCP fixture")
class WindowsTransportTests(unittest.TestCase):
    def test_real_mcp_broker_executor_with_fixture_unix_transport(self):
        with tempfile.TemporaryDirectory(prefix="ra-handoff-") as temp:
            root = Path(temp)
            replica = root / "replica"; replica.mkdir()
            server = root / "server"; server.mkdir()
            (server / "marker.txt").write_text("server-first", encoding="utf-8")
            (root / "mode.txt").write_text("ready")
            guard = root / "guard.ps1"
            guard.write_text("""$ErrorActionPreference='Stop'
$r=[Console]::ReadLine()|ConvertFrom-Json
if([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'mode.txt')) -ne 'ready'){throw 'Fixture stale'}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'server\\marker.txt') -Destination (Join-Path $r.replicaPath 'marker.txt') -Force
[Console]::WriteLine((@{ready=$true;fresh=$true;projectId=$r.projectId;hostId=$r.hostId;replicaPath=$r.replicaPath;snapshotId=[guid]::NewGuid().ToString('N');requestId=$r.requestId}|ConvertTo-Json -Compress))
""", encoding="utf-8")
            env = dict(os.environ)
            env["PATH"] = os.environ["SystemRoot"] + "\\System32;" + os.environ["SystemRoot"] + "\\System32\\WindowsPowerShell\\v1.0"
            env["PYTHONUTF8"] = "1"
            ps = str(Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe")
            executor = subprocess.Popen([ps, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(HERE / "windows-bridge-executor.ps1")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
            control, stop = socket.socketpair()
            thread = None
            failures = []
            path = str(root / "broker.fixture-port")
            try:
                token = secrets.token_hex(32)
                config = {"token": token, "workspace": str(replica), "device": "handoff-fixture", "allow_shell": True, "parent_pid": os.getpid(), "server_owned": True, "sync_guard": {"path": str(guard), "data_dir": str(root), "project_id": "p-fixture", "host_id": "fixture-host"}}
                executor.stdin.write(json.dumps(config) + "\n"); executor.stdin.flush()
                ready = json.loads(executor.stdout.readline())
                fixture_os = types.SimpleNamespace(path=os.path, makedirs=os.makedirs, getuid=lambda: 0, chmod=lambda *_: None, unlink=os.unlink, lstat=lambda p: types.SimpleNamespace(st_uid=0, st_mode=(stat.S_IFDIR if str(p) == str(root) else stat.S_IFSOCK) | 0o700))

                def serve():
                    try:
                        broker.serve(path, {"token": token, "port": ready["port"], "device": "handoff-fixture"}, control)
                    except Exception as error:
                        failures.append(type(error).__name__)

                with patch.object(broker, "socket", FIXTURE_SOCKET), patch.object(broker, "os", fixture_os), contextlib.redirect_stdout(io.StringIO()):
                    thread = threading.Thread(target=serve); thread.start()
                    deadline = time.monotonic() + 5
                    while not os.path.exists(path) and not failures and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.assertFalse(failures)
                    self.assertTrue(os.path.exists(path))

                    def call(name, values=None):
                        messages = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}}, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": name, "arguments": values or {}}}]
                        completed = subprocess.run([os.sys.executable, str(Path(__file__).resolve()), "--fixture-adapter", path], input="".join(json.dumps(m) + "\n" for m in messages), text=True, encoding="utf-8", capture_output=True, timeout=45, env=env)
                        self.assertEqual(completed.returncode, 0, completed.stderr[-1500:])
                        self.assertEqual(completed.stderr, "")
                        self.assertNotIn(token, completed.stdout)
                        replies = [json.loads(line) for line in completed.stdout.splitlines()]
                        self.assertIn("windows_command", {t["name"] for t in replies[1]["result"]["tools"]})
                        return json.loads(replies[2]["result"]["content"][0]["text"])

                    status = call("windows_status")
                    self.assertTrue(status["ok"] and status["sync_guard"]["required"])
                    self.assertFalse(status["file_mutations_enabled"])
                    self.assertFalse(call("windows_write", {"path": "forbidden.txt", "content": "denied"})["ok"])
                    for value in ("server-first", "server-second"):
                        (server / "marker.txt").write_text(value, encoding="utf-8")
                        result = call("windows_command", {"command": "Get-Content -LiteralPath 'marker.txt' -Raw", "timeout_seconds": 5})
                        self.assertTrue(result["ok"], result)
                        self.assertEqual(result["exit_code"], 0)
                        self.assertEqual(result["output"].strip(), value)
                        self.assertEqual(call("windows_read", {"path": "marker.txt"})["content"], value)
                    (root / "mode.txt").write_text("stale")
                    self.assertFalse(call("windows_command", {"command": "Write-Output 'must-not-run'", "timeout_seconds": 5})["ok"])
                    stop.send(b"stop"); thread.join(5)
                    self.assertFalse(thread.is_alive())
                self.assertFalse(failures)
            finally:
                if thread and thread.is_alive():
                    stop.send(b"stop"); thread.join(5)
                control.close(); stop.close()
                executor.stdin.close()
                try:
                    executor.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    executor.kill(); executor.wait(timeout=5)
                executor.stdout.close(); executor.stderr.close()


@unittest.skipUnless(os.name == "posix" and Path("/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe").exists(), "WSL/Windows transport fixture")
class TransportTests(unittest.TestCase):
    def test_real_adapter_broker_executor_without_local_agent(self):
        def winpath(path):
            value = str(path)
            if not value.startswith("/mnt/c/"):
                raise ValueError("fixture must be on Windows C drive")
            return "C:\\" + value[len("/mnt/c/"):].replace("/", "\\")

        with tempfile.TemporaryDirectory(prefix="handoff-fixture-", dir=HERE) as temp, tempfile.TemporaryDirectory(prefix="ra-socket-") as socktemp:
            root = Path(temp)
            replica = root / "replica"
            server = root / "server"
            replica.mkdir(); server.mkdir()
            (server / "marker.txt").write_text("server-first", encoding="utf-8")
            mode = root / "mode.txt"
            mode.write_text("ready")
            guard = root / "guard.ps1"
            guard.write_text("""$ErrorActionPreference='Stop'
$r=[Console]::ReadLine()|ConvertFrom-Json
if([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'mode.txt')) -ne 'ready'){throw 'Fixture is stale'}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'server\\marker.txt') -Destination (Join-Path $r.replicaPath 'marker.txt') -Force
[Console]::WriteLine((@{ready=$true;fresh=$true;projectId=$r.projectId;hostId=$r.hostId;replicaPath=$r.replicaPath;snapshotId=[guid]::NewGuid().ToString('N');requestId=$r.requestId}|ConvertTo-Json -Compress))
""", encoding="utf-8")
            token = secrets.token_hex(32)
            ps = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
            # Neither local agent nor Python is discoverable in Windows child PATH.
            command = "$env:PATH='C:\\Windows\\System32;C:\\Windows\\System32\\WindowsPowerShell\\v1.0'; & '" + winpath(HERE / "windows-bridge-executor.ps1") + "'"
            executor = subprocess.Popen([ps, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            control, stop = socket.socketpair()
            thread = None
            path = str(Path(socktemp) / "b.sock")
            relay = socket.socket()
            relay.bind(("127.0.0.1", 0)); relay.listen(4); relay.settimeout(0.2)
            relay_stop = threading.Event()
            relay_thread = None
            try:
                config = {"token": token, "workspace": winpath(replica), "device": "handoff-fixture", "allow_shell": True, "server_owned": True, "sync_guard": {"path": winpath(guard), "data_dir": winpath(root), "project_id": "p-fixture", "host_id": "fixture-host"}}
                executor.stdin.write(json.dumps(config) + "\n"); executor.stdin.flush()
                ready = json.loads(executor.stdout.readline())
                failures = []

                def relay_windows():
                    while not relay_stop.is_set():
                        try:
                            client, _ = relay.accept()
                        except socket.timeout:
                            continue
                        except OSError:
                            return
                        with client:
                            try:
                                payload = client.makefile("rb").readline(262145)
                                completed = subprocess.run([ps, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", winpath(HERE / "test-windows-tcp-relay.ps1"), "-Port", str(ready["port"])], input=payload, capture_output=True, timeout=40)
                                if completed.returncode:
                                    raise RuntimeError("fixture relay failed")
                                client.sendall(completed.stdout)
                            except Exception:
                                client.sendall(b'{"ok":false,"error":"fixture relay failed"}\n')

                relay_thread = threading.Thread(target=relay_windows)
                relay_thread.start()

                def serve():
                    try:
                        broker.serve(path, {"token": token, "port": relay.getsockname()[1], "device": "handoff-fixture"}, control)
                    except Exception as error:
                        failures.append(type(error).__name__)

                with contextlib.redirect_stdout(io.StringIO()):
                    thread = threading.Thread(target=serve)
                    thread.start()
                    deadline = time.monotonic() + 10
                    while not os.path.exists(path) and not failures and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.assertFalse(failures)
                    self.assertTrue(os.path.exists(path))

                    def call(name, arguments=None):
                        messages = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}}, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": name, "arguments": arguments or {}}}]
                        completed = subprocess.run([os.sys.executable, str(HERE / "codex-windows-bridge.py"), "--socket", path], input="".join(json.dumps(m) + "\n" for m in messages), text=True, capture_output=True, timeout=45)
                        self.assertEqual(completed.returncode, 0)
                        self.assertEqual(completed.stderr, "")
                        self.assertNotIn(token, completed.stdout)
                        replies = [json.loads(line) for line in completed.stdout.splitlines()]
                        self.assertIn("windows_command", {tool["name"] for tool in replies[1]["result"]["tools"]})
                        return json.loads(replies[2]["result"]["content"][0]["text"])

                    status = call("windows_status")
                    self.assertTrue(status["ok"] and status["sync_guard"]["required"])
                    self.assertFalse(status["file_mutations_enabled"])
                    self.assertFalse(call("windows_write", {"path": "no.txt", "content": "denied"})["ok"])
                    for content in ("server-first", "server-second"):
                        (server / "marker.txt").write_text(content, encoding="utf-8")
                        value = call("windows_command", {"command": "Get-Content -LiteralPath 'marker.txt' -Raw", "timeout_seconds": 5})
                        self.assertTrue(value["ok"], value)
                        self.assertEqual(value["exit_code"], 0)
                        self.assertEqual(value["output"].strip(), content)
                        self.assertEqual(call("windows_read", {"path": "marker.txt"})["content"], content)
                    mode.write_text("stale")
                    self.assertFalse(call("windows_command", {"command": "Write-Output 'must-not-run'", "timeout_seconds": 5})["ok"])
                    stop.send(b"stop")
                    thread.join(5)
                    self.assertFalse(thread.is_alive())
                self.assertFalse(failures)
            finally:
                if thread and thread.is_alive():
                    stop.send(b"stop"); thread.join(5)
                control.close(); stop.close()
                relay_stop.set(); relay.close()
                if relay_thread:
                    relay_thread.join(5)
                executor.stdin.close()
                try:
                    executor.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    executor.kill(); executor.wait(timeout=5)
                executor.stdout.close(); executor.stderr.close()


if __name__ == "__main__":
    if len(os.sys.argv) == 3 and os.sys.argv[1] == "--fixture-adapter":
        adapter = load("handoff_adapter", "codex-windows-bridge.py")
        adapter.socket = FIXTURE_SOCKET
        os.sys.argv = [os.sys.argv[0], "--socket", os.sys.argv[2]]
        raise SystemExit(adapter.main())
    unittest.main(verbosity=2)
