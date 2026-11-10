"""Local subprocess/socket fixtures. Linux uses pwsh and platform shims, never Windows.

The same executor tests use unmodified PS5.1 on Windows. The Linux substitutions
only supply a user identity, private state path, process birth stamp and executable
names, not scheduling.
"""
import importlib.util
import json
import os
import queue
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent
PWSH = Path.home() / '.cache/pwsh-test/pwsh'
spec = importlib.util.spec_from_file_location('concurrency_adapter', ROOT / 'codex-windows-bridge.py')
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


class ExclusiveProtocolTests(unittest.TestCase):
    def call(self, **args):
        return adapter.dispatch({'method': 'tools/call', 'params': {'name': 'windows_command', 'arguments': dict(command='test', taskId='one', **args)}}, 'fixture.sock')

    def test_exclusive_schema_validation_and_legacy_rejection(self):
        for name in ('windows_command', 'windows_process_start'):
            tool = next(t for t in adapter.TOOLS if t[0] == name)
            self.assertEqual(tool[2]['properties']['exclusive'], {'type': 'boolean'})
            self.assertIn('network/service', tool[1])
        for value in ('true', 1, None):
            with self.assertRaises(ValueError):
                self.call(exclusive=value)
        with patch.object(adapter, 'exchange', return_value={'ok': True}) as exchange:
            result = self.call(exclusive=True)
            self.assertTrue(result['isError'])
            self.assertIn('update/restart', result['content'][0]['text'])
            self.assertEqual([c.args[1] for c in exchange.call_args_list], ['status'])

    def test_flag_forwarded_and_old_mcp_arguments_still_work(self):
        with patch.object(adapter, 'exchange', side_effect=[{'ok': True, 'coordination': {'exclusive': True}}, {'ok': True}]) as exchange:
            self.assertFalse(self.call(exclusive=True)['isError'])
            self.assertIs(exchange.call_args.args[2]['exclusive'], True)
        with patch.object(adapter, 'exchange', return_value={'ok': True}) as exchange:
            self.assertFalse(self.call()['isError'])
            self.assertEqual(exchange.call_count, 1)
            self.assertNotIn('exclusive', exchange.call_args.args[2])


@unittest.skipUnless(os.name == 'posix', 'Unix broker')
class LegacyBrokerTests(unittest.TestCase):
    def test_old_serial_executor_long_command_does_not_fail_heartbeat(self):
        with tempfile.TemporaryDirectory(prefix='bridge-old-') as tmp:
            path = str(Path(tmp) / 'fixture.sock')
            listener = socket.socket(); listener.bind(('127.0.0.1', 0)); listener.listen(8); listener.settimeout(.1)
            started = threading.Event(); release = threading.Event(); stopped = threading.Event()
            errors = []
            def serial_executor():
                try:
                    while not stopped.is_set():
                        try: conn, _ = listener.accept()
                        except socket.timeout: continue
                        with conn, conn.makefile('rb') as stream:
                            request = json.loads(stream.readline())
                            if request['op'] == 'command':
                                started.set()
                                if not release.wait(3): raise AssertionError('Test did not release command')
                            conn.sendall(b'{"ok":true}\n') # Old status has no coordination capability.
                except Exception as exc: errors.append(exc)
            thread = threading.Thread(target=serial_executor, daemon=True); thread.start()
            code = "import json,runpy,sys; m=runpy.run_path(sys.argv[1]); m['serve'](sys.argv[2],json.loads(m['read_line'](sys.stdin.buffer,4096)),sys.stdin.buffer,heartbeat_interval=.03,heartbeat_timeout=.03)"
            broker = subprocess.Popen([sys.executable, '-c', code, str(ROOT / 'codex-bridge-session.py'), path], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                broker.stdin.write(json.dumps(dict(token='a'*64, port=listener.getsockname()[1], heartbeat=True)).encode()+b'\r\n'); broker.stdin.flush()
                self.assertEqual(json.loads(broker.stdout.readline())['state'], 'connected')
                responses = queue.Queue()
                requester = threading.Thread(target=lambda: responses.put(adapter.exchange(path, 'command', dict(command='fixture', taskId='one'))), daemon=True)
                requester.start(); self.assertTrue(started.wait(3))
                # Three refused heartbeats would disconnect the old executor in <0.2 s.
                time.sleep(.3)
                self.assertIsNone(broker.poll(), 'Old serial executor was falsely disconnected')
                release.set()
                self.assertTrue(responses.get(timeout=3)['ok']); requester.join(3)
            finally:
                release.set(); broker.stdin.close()
                try: broker.wait(5)
                except subprocess.TimeoutExpired: broker.kill(); broker.wait(5)
                stderr = broker.stderr.read(); broker.stdout.close(); broker.stderr.close()
                stopped.set(); thread.join(3); listener.close()
                self.assertEqual(broker.returncode, 0, stderr)
                self.assertFalse(errors, errors)


@unittest.skipUnless(os.name == 'nt' or PWSH.exists(), 'PS5.1 or local pwsh required')
class ExecutorConcurrencyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='bridge-concurrency-')
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.stage = self.home / 'stage'; self.stage.mkdir()
        self.workspace = self.home / 'workspace'; self.workspace.mkdir()
        self.nodes = []
        self.env = dict(os.environ, LOCALAPPDATA=str(self.home / 'state'))
        self.lease = Path(self.env['LOCALAPPDATA']) / 'RemoteAgents/environment/operations.json'
        source = (ROOT / 'windows-bridge-executor.ps1').read_text()
        source = source.replace('[Security.Principal.WindowsIdentity]::GetCurrent().User.Value', "'fixture-" + secrets.token_hex(8) + "'")
        source = source.replace("[Environment]::GetFolderPath('LocalApplicationData')", '$env:LOCALAPPDATA')
        if os.name != 'nt':
            self.env['HOME'] = str(self.home)
            self.env['PATH'] = str(self.stage) + os.pathsep + os.environ['PATH']
            # .NET reconstructs Linux StartTime with different sub-microsecond rounding in
            # each process. Windows birth timestamps are exact; /proc supplies the Linux
            # equivalent so PID-reuse validation can be exercised without weakening it.
            for variable in ('$live', '$Process'):
                source = source.replace(variable + '.StartTime.ToUniversalTime().Ticks',
                    "([long](([IO.File]::ReadAllText('/proc/'+" + variable + ".Id+'/stat') -replace '^.*\\) ','').Split(' ')[19]))")
            shim = self.stage / 'powershell.exe'
            shim.write_text('#!/bin/sh\nexec "' + str(PWSH) + '" "$@"\n'); shim.chmod(0o700)
            killer = self.stage / 'taskkill.exe'
            killer.write_text('#!/usr/bin/env python3\nimport os,signal,sys\ntry: os.kill(int(sys.argv[sys.argv.index("/PID")+1]),signal.SIGKILL)\nexcept ProcessLookupError: pass\n')
            killer.chmod(0o700)
        (self.stage / 'windows-bridge-executor.ps1').write_bytes(source.replace('\n', '\r\n').encode())
        shutil.copyfile(ROOT / 'Windows.Paths.ps1', self.stage / 'Windows.Paths.ps1')
        self.addCleanup(self.close_nodes)
        self.node = self.launch()

    def launch(self, enforce=True):
        executable = 'powershell.exe' if os.name == 'nt' else str(PWSH)
        process = subprocess.Popen([executable, '-NoProfile', '-NonInteractive', '-File', str(self.stage / 'windows-bridge-executor.ps1')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=self.env)
        node = {'process': process, 'token': secrets.token_hex(32), 'binding': dict(projectId='control', hostId='fixture', deviceLabel='test', windowsReplica=str(self.workspace))}
        self.nodes.append(node)
        process.stdin.write(json.dumps(dict(token=node['token'], workspace=str(self.workspace), device='test', allow_shell=True, parent_pid=os.getpid(), control_only=True, project_id='control', host_id='fixture', enforce_target=enforce)) + '\n'); process.stdin.flush()
        # A bounded read also reports startup failures, avoiding hangs on broken fixtures.
        readiness = queue.Queue()
        threading.Thread(target=lambda: readiness.put(process.stdout.readline()), daemon=True).start()
        try:
            ready = readiness.get(timeout=30)
        except queue.Empty:
            process.kill(); process.wait(5)
            self.fail('Executor startup timeout: ' + process.stderr.read())
        self.assertTrue(ready, process.stderr.read() if process.poll() is not None else 'No readiness')
        node['port'] = json.loads(ready)['port']
        return node

    def close_nodes(self):
        for node in self.nodes:
            process = node['process']
            if process.poll() is None:
                if 'port' in node:
                    try: self.call('shutdown', node=node)
                    except (OSError, ValueError): pass
                else:
                    process.kill()
                try: process.wait(8)
                except subprocess.TimeoutExpired: process.kill(); process.wait(5)
            errors = process.stderr.read()
            for stream in (process.stdin, process.stdout, process.stderr): stream.close()
            self.assertEqual(process.returncode, 0, errors)

    def open_request(self, op, args=None, node=None):
        node = node or self.node
        conn = socket.create_connection(('127.0.0.1', node['port']), timeout=15)
        conn.sendall(json.dumps(dict(token=node['token'], binding=node['binding'], op=op, args=args or {})).encode() + b'\r\n')
        return conn

    def read(self, conn):
        with conn, conn.makefile('rb') as stream:
            raw = stream.readline(262145)
            self.assertTrue(raw, 'Executor closed request')
            return json.loads(raw)

    def call(self, op, args=None, node=None):
        return self.read(self.open_request(op, args, node))

    def start(self, task='one', command='Start-Sleep -Seconds 60', **extra):
        result = self.call('process_start', dict(taskId=task, command=command, **extra))
        self.assertTrue(result['ok'], result)
        return result['id']

    def wait_file(self, path):
        deadline = time.monotonic() + 10
        while not path.exists():
            self.assertLess(time.monotonic(), deadline, 'Command did not start')
            time.sleep(.02)

    def test_two_commands_on_same_executor_overlap_and_partial_frame_does_not_stall(self):
        partial = socket.create_connection(('127.0.0.1', self.node['port']))
        self.addCleanup(partial.close); partial.sendall(b'{')
        command = "[IO.File]::WriteAllText('ready','yes');while(!(Test-Path 'release')){Start-Sleep -Milliseconds 20};Write-Output 'done'"
        first = self.open_request('command', dict(command=command, taskId='one', timeout_seconds=8))
        self.addCleanup(first.close)
        self.wait_file(self.workspace / 'ready')
        second = self.call('command', dict(command="[IO.File]::WriteAllText('release','yes');Write-Output 'second'", taskId='two'))
        self.assertTrue(second['ok'], second)
        result = self.read(first)
        self.assertTrue(result['ok'], result); self.assertFalse(result['timed_out'])
        self.assertIn('done', result['output'])

    def test_exclusive_both_directions_metadata_and_cross_executor(self):
        other = self.launch()
        ordinary = self.start()
        denied = self.call('command', dict(command="Write-Output 'secret-command-marker'", taskId='two', exclusive=True), other)
        self.assertFalse(denied['ok']); self.assertIn('taskId=one operation=process_start started=', denied['error'])
        self.assertRegex(denied['error'], r'started=\d{4}-\d\d-\d\dT')
        self.assertNotIn('secret-command-marker', denied['error'])
        self.assertTrue(self.call('command', dict(command='Write-Output parallel', taskId='two'), other)['ok'])
        self.call('process_stop', dict(id=ordinary, taskId='one'))
        exclusive = self.start(exclusive=True)
        for op in ('command', 'process_start'):
            for node in (self.node, other):
                result = self.call(op, dict(command='Write-Output denied', taskId='two'), node)
                self.assertFalse(result['ok']); self.assertIn('taskId=one', result['error'])
        self.assertTrue(self.call('status')['ok'])
        self.assertTrue(self.call('command', dict(command='Write-Output companion', taskId='one'))['ok'])
        self.call('process_stop', dict(id=exclusive, taskId='one'))
        # A synchronous exclusive command also keeps its lease while its response is pending.
        pending = self.open_request('command', dict(command="[IO.File]::WriteAllText('ready','yes');Start-Sleep 2", taskId='one', exclusive=True))
        self.addCleanup(pending.close); self.wait_file(self.workspace / 'ready')
        denied = self.call('process_start', dict(command='Write-Output denied', taskId='two'))
        self.assertIn('operation=command', denied['error'])
        self.assertTrue(self.read(pending)['ok'])

    def test_completed_free_slots_output_consumed_and_foreign_access_denied(self):
        ids = []
        for _ in range(10):
            ids.append(self.start(command="Write-Output 'retained'"))
            deadline = time.monotonic() + 15
            while self.call('status')['active_processes']:
                self.assertLess(time.monotonic(), deadline); time.sleep(.05)
        deadline = time.monotonic() + 15
        while self.call('status')['active_processes']:
            self.assertLess(time.monotonic(), deadline); time.sleep(.05)
        last = ids[-1]
        for op in ('process_poll', 'process_stop'):
            self.assertFalse(self.call(op, dict(id=last, taskId='two'))['ok'])
        result = self.call('process_poll', dict(id=last, taskId='one'))
        self.assertTrue(result['ok'], result); self.assertFalse(result['running']); self.assertIn('retained', result['output'])
        self.assertFalse(self.call('process_poll', dict(id=last, taskId='one'))['ok'])
        live = self.start()
        for op in ('process_poll', 'process_stop'):
            self.assertFalse(self.call(op, dict(id=live, taskId='two'))['ok'])
        self.assertTrue(self.call('process_poll', dict(id=live, taskId='one'))['running'])

    def test_existing_sync_barrier_fixture(self):
        shutil.copyfile(ROOT / 'test-windows-bridge-sync.ps1', self.stage / 'test-windows-bridge-sync.ps1')
        executable = 'powershell.exe' if os.name == 'nt' else str(PWSH)
        result = subprocess.run([executable, '-NoProfile', '-NonInteractive', '-File', str(self.stage / 'test-windows-bridge-sync.ps1')], stdin=subprocess.DEVNULL, capture_output=True, text=True, env=self.env, timeout=90)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('PASS: ready/recovered execution', result.stdout)

    def test_legacy_transport_still_enforces_process_ownership(self):
        node = self.launch(enforce=False)
        started = self.call('process_start', dict(command='Start-Sleep 60', taskId='one'), node)
        self.assertTrue(started['ok'], started)
        for op in ('process_poll', 'process_stop'):
            self.assertFalse(self.call(op, dict(id=started['id'], taskId='two'), node)['ok'])
            self.assertFalse(self.call(op, dict(id=started['id']), node)['ok'])
        self.assertTrue(self.call('process_stop', dict(id=started['id'], taskId='one'), node)['ok'])

    def test_global_limit_counts_live_leases_across_tasks(self):
        live = self.start()
        state = json.loads(self.lease.read_text())
        original = state['operations'][0]
        # Reservations may share their executor PID; exercise the global bound with
        # valid live identities without allocating 64 PowerShell runtimes in CI.
        state['operations'] += [dict(original, id='reservation-'+str(i), taskId='task-'+str(i)) for i in range(63)]
        self.lease.write_text(json.dumps(state))
        result = self.call('process_start', dict(command='Start-Sleep 60', taskId='two'))
        self.assertFalse(result['ok']); self.assertIn('Global live process limit reached (64)', result['error'])
        state['operations'].pop()
        self.lease.write_text(json.dumps(state))
        self.start(task='two')
        self.call('process_stop', dict(id=live, taskId='one'))

    def test_command_timeout_releases_exclusive_without_stopping_other_task(self):
        result = self.call('command', dict(command='Start-Sleep 60', taskId='one', timeout_seconds=1, exclusive=True))
        self.assertTrue(result['ok'], result); self.assertTrue(result['timed_out'])
        other = self.start(task='two')
        result = self.call('command', dict(command='Write-Output independent', taskId='one'))
        self.assertTrue(result['ok'], result)
        self.assertTrue(self.call('process_poll', dict(id=other, taskId='two'))['running'])

    def test_per_task_limit_shared_between_executors(self):
        other = self.launch()
        for _ in range(8): self.start()
        for node in (self.node, other):
            result = self.call('process_start', dict(command='Start-Sleep 10', taskId='one'), node)
            self.assertFalse(result['ok']); self.assertIn('taskId (8)', result['error'])
        self.start(task='two')

    def test_dead_pid_and_reused_pid_leases_removed_legacy_live_blocks(self):
        # Write only when no operation is active; all state is fixture-owned.
        record = dict(id='stale', taskId='stale-owner', pid=2147483647, started=1)
        self.lease.write_text(json.dumps(dict(schema=1, operations=[record, dict(record, pid=os.getpid())])))
        self.assertTrue(self.call('command', dict(command='Write-Output reclaimed', taskId='one', exclusive=True))['ok'])
        self.assertEqual(json.loads(self.lease.read_text())['operations'], [])
        live = self.start()
        state = json.loads(self.lease.read_text())
        for entry in state['operations']:
            for key in ('exclusive', 'operation', 'began'): entry.pop(key, None)
        self.lease.write_text(json.dumps(state))
        result = self.call('process_start', dict(command='Write-Output denied', taskId='two'))
        self.assertFalse(result['ok']); self.assertIn('operation=legacy', result['error'])
        self.call('process_stop', dict(id=live, taskId='one'))

    @unittest.skipUnless(os.name == 'posix', 'Unix broker and MCP')
    def test_one_mcp_and_broker_serve_parallel_calls_and_heartbeat(self):
        node = self.launch(enforce=False) # Legacy --socket transport still isolates explicit taskIds.
        base = self.home / '.local/state/codex-remote'; base.mkdir(parents=True, mode=0o700)
        path = base / 'fixture.sock'
        code = "import json,runpy,sys; m=runpy.run_path(sys.argv[1]); m['serve'](sys.argv[2],json.loads(m['read_line'](sys.stdin.buffer,4096)),sys.stdin.buffer,heartbeat_interval=.1,heartbeat_timeout=2)"
        broker = subprocess.Popen([sys.executable, '-c', code, str(ROOT / 'codex-bridge-session.py'), str(path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env)
        def replies(process):
            mailbox = queue.Queue()
            def read_lines():
                for line in process.stdout:
                    mailbox.put(json.loads(line))
            threading.Thread(target=read_lines, daemon=True).start()
            return mailbox
        mcp = None
        try:
            broker.stdin.write(json.dumps(dict(token=node['token'], port=node['port'], device='test', heartbeat=True)).encode()+b'\n'); broker.stdin.flush()
            heartbeat = replies(broker)
            self.assertEqual(heartbeat.get(timeout=10)['state'], 'connected')
            mcp = subprocess.Popen([sys.executable, str(ROOT / 'codex-windows-bridge.py'), '--socket', str(path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env)
            responses = replies(mcp)
            def send(i, command):
                args = dict(taskId='task-'+str(i), command=command, timeout_seconds=8)
                mcp.stdin.write(json.dumps(dict(jsonrpc='2.0', id=i, method='tools/call', params=dict(name='windows_command', arguments=args))).encode()+b'\r\n'); mcp.stdin.flush()
            send(1, "[IO.File]::WriteAllText('ready','yes');while(!(Test-Path 'release')){Start-Sleep -Milliseconds 20}")
            self.wait_file(self.workspace / 'ready')
            # Discard startup heartbeats; require a new one while the command is held.
            while not heartbeat.empty(): heartbeat.get_nowait()
            self.assertEqual(heartbeat.get(timeout=3)['state'], 'heartbeat')
            self.assertFalse((self.workspace / 'release').exists())
            send(2, "[IO.File]::WriteAllText('release','yes')")
            results = [responses.get(timeout=15) for _ in range(2)]
            self.assertEqual({r['id'] for r in results}, {1, 2})
            for reply in results:
                result = reply['result']; self.assertFalse(result['isError'], result)
                self.assertFalse(json.loads(result['content'][0]['text'])['timed_out'])
            send(3, "[IO.File]::WriteAllText('ready-stop','yes');Start-Sleep 30")
            self.wait_file(self.workspace / 'ready-stop')
            broker.stdin.close(); broker.wait(timeout=5)
            self.assertTrue(responses.get(timeout=5)['result']['isError'])
        finally:
            for process in (mcp, broker):
                if process:
                    process.stdin.close()
                    try: process.wait(10)
                    except subprocess.TimeoutExpired: process.kill(); process.wait(5)
                    errors = process.stderr.read()
                    process.stdout.close(); process.stderr.close()
                    self.assertEqual(process.returncode, 0, errors)


@unittest.skipUnless(PWSH.exists(), 'local pwsh required')
class RetentionTests(unittest.TestCase):
    def test_completed_ttl_and_cache_bound(self):
        # Execute the actual sweeper function with a cache clocked in the past.
        # This tests expiry/eviction without a five-minute wall clock delay.
        script = r"""
$ErrorActionPreference='Stop'
$source=Get-Content './windows-bridge-executor.ps1' -Raw
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Executor syntax errors'}
$function=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Clear-FinishedProcesses'},$true)
Invoke-Expression $function.Extent.Text
$processes=@{};$pendingCommands=@{};$completed=@{}
$now=[DateTime]::UtcNow
for($i=0;$i -lt 65;$i++){$completed[[string]$i]=@{Finished=$now.AddSeconds(-$i);TaskId='one';Result=@{output='retained'}}}
Clear-FinishedProcesses
if($completed.Count -ne 64 -or $completed.ContainsKey('64')){throw 'Completed cache is unbounded or evicts newest'}
$completed['0'].Finished=$now.AddMinutes(-6)
Clear-FinishedProcesses
if($completed.Count -ne 63 -or $completed.ContainsKey('0')){throw 'Completed output TTL not enforced'}
'PASS retention'
"""
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run([str(PWSH), '-NoProfile', '-NonInteractive', '-Command', script], stdin=subprocess.DEVNULL, capture_output=True, text=True, cwd=ROOT, env=dict(os.environ, HOME=tmp, LOCALAPPDATA=tmp), timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('PASS retention', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
