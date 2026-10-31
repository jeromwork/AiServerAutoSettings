"""Local-only checks. No VPS, ADB, VPN, production SSH, or existing project files."""
import importlib.util
import io
import json
import os
import pathlib
import secrets
import socket
import subprocess
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


adapter = load("bridge_adapter", "codex-windows-bridge.py")
broker = load("bridge_broker", "codex-bridge-session.py")


class ProtocolTests(unittest.TestCase):
    def test_mcp(self):
        result = adapter.dispatch({"method": "initialize", "params": {"protocolVersion": "2025-06-18"}}, "unused")
        self.assertEqual(result["protocolVersion"], "2025-06-18")
        tools = adapter.dispatch({"method": "tools/list"}, "unused")["tools"]
        self.assertEqual(len(tools), 8)
        with self.assertRaises(ValueError):
            adapter.dispatch({"method": "tools/call", "params": {"name": "windows_command", "arguments": {"command": "test", "timeout_seconds": 61}}}, "unused")
        with self.assertRaises(ValueError):
            adapter.dispatch({"method": "tools/call", "params": {"name": "windows_status", "arguments": {"token": "test"}}}, "unused")
        disconnected = adapter.dispatch({"method": "tools/call", "params": {"name": "windows_status"}}, "nonexistent.sock")
        self.assertTrue(disconnected["isError"])

    def test_frames(self):
        self.assertEqual(broker.read_line(io.BytesIO(b'{}\n')), b'{}\n')
        for data in (b'', b'{}', b'12345\n'):
            with self.assertRaises(ValueError):
                broker.read_line(io.BytesIO(data), 4)

    def test_stdio_stdout_is_json_only(self):
        messages = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}}, {"jsonrpc": "2.0", "method": "notifications/initialized"}, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}]
        completed = subprocess.run([os.sys.executable, str(HERE / 'codex-windows-bridge.py'), '--socket', 'missing.sock'], input=''.join(json.dumps(m) + '\n' for m in messages), text=True, capture_output=True, check=True)
        replies = [json.loads(line) for line in completed.stdout.splitlines()]
        self.assertEqual([reply['id'] for reply in replies], [1, 2])
        self.assertEqual(completed.stderr, '')


@unittest.skipUnless(os.name == 'nt', 'Windows executor tests')
class WindowsExecutorTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix='bridge-test-', dir=HERE)
        self.secret = secrets.token_hex(32)
        self.process = subprocess.Popen(['powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(HERE / 'windows-bridge-executor.ps1')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.process.stdin.write(json.dumps({'token': self.secret, 'workspace': self.folder.name, 'device': 'test-only', 'allow_shell': self.allow_shell(), 'parent_pid': os.getpid()}) + '\n')
        self.process.stdin.flush()
        ready_line = self.process.stdout.readline()
        if not ready_line:
            self.fail('Executor did not start: ' + self.process.stderr.read()[:1000])
        self.ready = json.loads(ready_line)

    def allow_shell(self):
        return False

    def call(self, op, args=None, token=None):
        with socket.create_connection(('127.0.0.1', self.ready['port']), timeout=5) as conn:
            conn.settimeout(70)
            conn.sendall(json.dumps({'token': self.secret if token is None else token, 'op': op, 'args': args or {}}).encode() + b'\n')
            result = conn.makefile('rb').readline(262145)
            self.assertNotIn(self.secret.encode(), result)
            return json.loads(result)

    def tearDown(self):
        try:
            if self.process.poll() is None:
                self.call('shutdown')
            self.process.wait(timeout=10)
        finally:
            if self.process.poll() is None:
                self.process.kill()
            self.process.stdin.close()
            self.process.stdout.close()
            self.process.stderr.close()
            self.folder.cleanup()

    def test_files_auth_and_shell_denied(self):
        self.assertFalse(self.call('status', token='0' * 64)['ok'])
        self.assertTrue(self.call('status')['ok'])
        self.assertFalse(self.call('command', {'command': "Write-Output 'must-not-run'"})['ok'])
        self.assertTrue(self.call('write', {'path': 'hello.txt', 'content': 'bridge-test'})['ok'])
        self.assertEqual(self.call('read', {'path': 'hello.txt'})['content'], 'bridge-test')
        self.assertEqual(self.call('list')['entries'][0]['name'], 'hello.txt')
        for path in ('..\\outside.txt', 'C:\\outside.txt', '.env', 'credentials.json', 'access-token.txt', 'id_ed25519', '.git\\config'):
            self.assertFalse(self.call('read', {'path': path})['ok'], path)
        self.assertFalse(self.call('write', {'path': 'large.txt', 'content': 'x' * 65537})['ok'])
        self.assertFalse(self.call('unknown')['ok'])
        with socket.create_connection(('127.0.0.1', self.ready['port']), timeout=5) as conn:
            conn.sendall(b'{bad json}\n')
            self.assertFalse(json.loads(conn.makefile('rb').readline())['ok'])
        self.assertTrue(self.call('status')['ok'])


class WindowsShellTests(WindowsExecutorTests):
    def allow_shell(self):
        return True

    def test_files_auth_and_shell_denied(self):
        self.assertTrue(self.call('status')['shell_enabled'])
        result = self.call('command', {'command': "Write-Output 'local-bridge-test'", 'timeout_seconds': 10})
        self.assertTrue(result['ok'])
        self.assertEqual(result['exit_code'], 0)
        self.assertIn('local-bridge-test', result['output'])
        started = self.call('process_start', {'command': "Write-Output 'tracked'; Start-Sleep -Seconds 30"})
        self.assertTrue(started['ok'])
        self.assertTrue(self.call('process_poll', {'id': started['id']})['running'])
        self.assertTrue(self.call('process_stop', {'id': started['id']})['ok'])
        self.assertFalse(self.call('process_poll', {'id': started['id']})['ok'])


@unittest.skipUnless(os.name == 'nt', 'Windows managed lifecycle test')
class LauncherTests(unittest.TestCase):
    def test_managed_stop_without_network(self):
        with tempfile.TemporaryDirectory(prefix='bridge-launch-test-', dir=HERE) as folder:
            folder = pathlib.Path(folder)
            fake_ssh = folder / 'fake-ssh.exe'
            source = 'using System; public class FakeSSH { public static void Main() { Console.ReadLine(); Console.WriteLine("{\\"state\\":\\"connected\\"}"); while(Console.ReadLine() != null) {} } }'
            # Test-only executable consumes the SSH launch; it never opens a socket.
            encoded_source = __import__('base64').b64encode(source.encode('utf-8')).decode('ascii')
            build = "$source=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + encoded_source + "')); Add-Type -TypeDefinition $source -OutputAssembly '" + str(fake_ssh) + "' -OutputType ConsoleApplication"
            subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', build], check=True, capture_output=True)
            identity = folder / 'dummy-identity'
            hosts = folder / 'dummy-known-hosts'
            identity.write_text('dummy-not-a-key')
            hosts.write_text('dummy-not-a-host-key')
            process = subprocess.Popen(['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(HERE / 'Start-CodexWindowsBridge.ps1'), '-VPSHost', 'offline.test', '-VPSUser', 'test', '-IdentityFile', str(identity), '-KnownHostsFile', str(hosts), '-Workspace', str(folder), '-SSHExecutable', str(fake_ssh), '-ManagedSession'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                ready = json.loads(process.stdout.readline())
                connected = json.loads(process.stdout.readline())
                self.assertEqual(ready['state'], 'ready')
                self.assertEqual(connected['state'], 'connected')
                process.stdin.write('stop\n')
                process.stdin.flush()
                output, errors = process.communicate(timeout=15)
                self.assertEqual(process.returncode, 0, errors[:500])
                self.assertEqual(json.loads(output.strip())['state'], 'stopped')
                self.assertNotRegex(output, r'\b[a-f0-9]{64}\b')
            finally:
                if process.poll() is None:
                    process.kill()
                for stream in (process.stdin, process.stdout, process.stderr):
                    if not stream.closed:
                        stream.close()


if __name__ == '__main__':
    unittest.main(verbosity=2)
