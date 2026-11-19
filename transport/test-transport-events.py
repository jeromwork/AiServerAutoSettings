#!/usr/bin/env python3
"""SW-B only: fake Clash WebSockets, banner endpoints and SSH, exclusively loopback.
Run: python3 transport/test-transport-events.py /path/to/pwsh
No real sing-box, network configuration, external services or Windows processes.
"""
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlsplit, parse_qs

PWSH = sys.argv[1] if len(sys.argv) > 1 else 'pwsh'
EVENTS = Path(__file__).with_name('Transport.Events.ps1').resolve()
SECRET = 'test-api-secret-do-not-publish'
lock = threading.Lock()
state = dict(mode='idle', version=0, requests=[], connects=0, data=[])


def frame(data, opcode=1, final=True):
    data = data.encode() if isinstance(data, str) else data
    n = len(data)
    return bytes([(128 if final else 0) | opcode, n if n < 126 else 126 if n < 65536 else 127]) + (
        b'' if n < 126 else struct.pack('!H' if n < 65536 else '!Q', n)) + data


def connection(ident, upload, download=0, tag='path-a', start='2026-11-19T10:00:00Z', inbound='mixed/vpn-in'):
    return dict(id=ident, upload=upload, download=download, chains=['detour', tag, 'active'],
                start=start, metadata=dict(type=inbound))


def logs(mode):
    def entry(payload, typ='error'):
        return dict(type=typ, payload=payload)
    if mode == 'logs':
        prefix = 'open connection to https://user:private@host:443 using outbound/vless[path-a]: '
        return ([entry(prefix + reason) for reason in ['i/o timeout', 'connection refused', 'connection reset by peer',
                   '10050', '10051', '10052', '10065', 'no route to host', 'network is unreachable',
                   'lookup private: getaddrinfow: No such host is known', 'connection refused from peer', 'remote DNS: no such host']] +
                [entry(prefix + 'context canceled'), entry(prefix + 'operation cancelled'),
                 entry(prefix + 'i/o timeout', 'warn'), entry('connection upload finished', 'debug'),
                 entry('connection download closed: read tcp: connection reset by peer'),
                 entry('[123 1ms] outbound/vless[path-b]: diagnostic', 'warn'),
                 entry('[123 2ms] connection upload closed: i/o timeout'),
                 entry('open packet connection to secret:53 using outbound/tuic[path-b]: i/o timeout'),
                 entry('listen packet connection using outbound/tuic[path-b]: network is unreachable'),
                 entry(prefix.replace('path-a', 'unknown') + 'timeout'),
                 entry('connection upload closed: context canceled'),
                 entry('unrelated error with password=private token=secret')])
    if mode == 'overflow':
        return [entry('open connection to secret:443 using outbound/vless[path-a]: i/o timeout')] * 700
    return []


class API(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def do_GET(self):
        url = urlsplit(self.path)
        if url.path == '/test':
            with lock:
                state['mode'] = parse_qs(url.query)['mode'][0]
                state['version'] += 1
            self.send_response(200)
            self.send_header('Content-Length', '2')
            self.end_headers()
            self.wfile.write(b'{}')
            return
        with lock:
            state['requests'].append(self.path)
            state['connects'] += 1
        if self.headers.get('Authorization') != 'Bearer ' + SECRET:
            self.send_response(401)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        assert self.path in ('/logs?level=warn', '/connections?interval=1000'), self.path
        key = self.headers['Sec-WebSocket-Key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
        self.send_response(101)
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', base64.b64encode(hashlib.sha1(key.encode()).digest()).decode())
        self.end_headers()
        seen_version = -1
        seq = 0
        try:
            while True:
                with lock:
                    mode, version = state['mode'], state['version']
                changed = version != seen_version
                if changed:
                    seq = 0
                    seen_version = version
                seq += 1
                if url.path == '/logs':
                    if changed:
                        # Malformed JSON must not kill the subscription; real records are fragmented.
                        self.connection.sendall(frame('{broken'))
                        for item in logs(mode):
                            raw = json.dumps(item).encode()
                            self.connection.sendall(frame(raw[:17], final=False) + frame(raw[17:], opcode=0))
                else:
                    if mode == 'reconnect' and seq == 4:
                        self.connection.sendall(frame(b'\x03\xe8', opcode=8))
                        return
                    rows = []
                    if mode in ('stall', 'reconnect'):
                        rows = [connection('a', seq * 100), connection('b', seq * 100)]
                    elif mode == 'download':
                        rows = [connection('a', seq * 100, seq * 20), connection('b', seq * 100, seq * 20)]
                    elif mode == 'idle':
                        rows = [connection('a', 100), connection('b', 100)]
                    elif mode == 'one':
                        rows = [connection('a', seq * 100)]
                    elif mode == 'split':
                        rows = [connection('a', seq * 100), connection('b', seq * 100, tag='path-b')]
                    elif mode == 'churn':
                        rows = [connection('a', seq * 100, start=str(seq)), connection('b', seq * 100, start=str(seq))]
                    elif mode == 'disappear' and seq % 3:
                        rows = [connection('a', seq * 100), connection('b', seq * 100)]
                    elif mode == 'probe':
                        rows = [connection('a', seq * 100, inbound='direct/probe-path-a'),
                                connection('b', seq * 100, inbound='direct/probe-path-a')]
                    self.connection.sendall(frame(json.dumps(dict(connections=rows))))
                time.sleep(.1)
        except (OSError, ConnectionError):
            pass


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True


class TCP(socketserver.BaseRequestHandler):
    def handle(self):
        mode = self.server.mode
        try:
            if mode == 'direct':
                self.request.settimeout(3)
                data = self.request.recv(1)
                with lock:
                    state['data'].append(data)
            elif mode == 'banner':
                self.request.sendall(b'pre-banner\r\nSSH-2.0-fake\r\n')
            elif mode == 'partial':
                self.request.sendall(b'SSH-2.0-')
                time.sleep(5)
            elif mode == 'hang':
                time.sleep(5)
            elif mode == 'fin':
                time.sleep(.2)  # Let the client finish connect and enter the banner read.
                # Explicit graceful EOF: keep the read side alive until the client closes.
                self.request.shutdown(socket.SHUT_WR)
                self.request.settimeout(5)
                self.request.recv(1)
            elif mode == 'rst':
                time.sleep(.2)  # Exercise a read reset rather than racing async connect.
                # Abortive close without banner bytes, distinct from FIN and a silent peer.
                self.request.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
                self.request.close()
            elif mode == 'trickle':
                for _ in range(60):
                    self.request.sendall(b'x')
                    time.sleep(.09)
        except OSError:
            pass


class TCPServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


def serve(server):
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server.server_address[1]


def ps_quote(value):
    return "'" + str(value).replace("'", "''") + "'"


api = Server(('127.0.0.1', 0), API)
api_port = serve(api)
servers = []
ports = {}
for mode in ('direct', 'banner', 'partial', 'hang', 'fin', 'rst', 'trickle'):
    server = TCPServer(('127.0.0.1', 0), TCP)
    server.mode = mode
    ports[mode] = serve(server)
    servers.append(server)
# Reserved, bound but not listening: deterministic connection refused without port reuse races.
refused = socket.socket()
refused.bind(('127.0.0.1', 0))
ports['refused'] = refused.getsockname()[1]

try:
    with tempfile.TemporaryDirectory(prefix='transport-events-test-') as tmp:
        root = Path(tmp)
        ssh = root / 'ssh.exe'
        ssh.write_text('#!' + sys.executable + '\n' + '''import json, os, sys, time
from pathlib import Path
root=Path(__file__).parent
mode=(root/'mode').read_text()
(root/'probe-args').write_text(json.dumps(sys.argv[1:]))
(root/'probe-pid').write_text(str(os.getpid()))
if mode=='exit': sys.exit(1)
if mode=='timeout': time.sleep(30)
n=int(sys.argv[-1].split()[2])
os.write(1,b'x'*(16384 if mode=='stall' else n))
if mode=='stall': time.sleep(30)
''')
        ssh.chmod(0o700)
        harness = root / 'test.ps1'
        harness.write_text('''param([int]$Port,[string]$Root)
$ErrorActionPreference='Stop'
. ''' + ps_quote(EVENTS.with_name('Transport.Common.ps1')) + '\n. ' + ps_quote(EVENTS) + '''
function Assert($Value,[string]$Message) { if (-not $Value) { throw $Message } }
function Mode([string]$Name) { $null=Invoke-RestMethod ("http://127.0.0.1:$Port/test?mode=$Name") -NoProxy }
function Collect($Reader,[double]$Seconds) {
    $all=@();$watch=[Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $Seconds) { $all+=@(Receive-TransportEvents $Reader); Start-Sleep -Milliseconds 30 }
    $all+=@(Receive-TransportEvents $Reader);$all
}
function Wait-Check($Handle,[string]$Type) {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt 5) {
        $value=if ($Type -eq 'path') { Receive-TransportPathCheck $Handle } else { Receive-TransportDirectCheck $Handle }
        if ($value) { return $value }; Start-Sleep -Milliseconds 20
    }
    throw "Check timeout: $Type"
}
Initialize-TransportEvents
# Emulate delayed cancellation on older .NET without depending on network scheduling.
# The production reader still owns and cancels its real subscriptions.
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Reflection;
using System.Threading;
public static class DelayedTransportWorkers {
    public static long Stop(object reader) {
        Thread[] workers=(Thread[])reader.GetType().GetField("workers",BindingFlags.NonPublic|BindingFlags.Instance).GetValue(reader);
        Thread[] original=(Thread[])workers.Clone();
        using(ManualResetEvent release=new ManualResetEvent(false)) {
            for(int i=0;i<workers.Length;i++) {
                workers[i]=new Thread(delegate() {release.WaitOne();});
                workers[i].IsBackground=true;
                workers[i].Start();
            }
            try {
                Stopwatch watch=Stopwatch.StartNew();
                ((IDisposable)reader).Dispose();
                return watch.ElapsedMilliseconds;
            } finally {
                release.Set();
                foreach(Thread worker in workers) worker.Join();
                Array.Copy(original,workers,workers.Length);
                foreach(Thread worker in original) worker.Join(1000);
            }
        }
    }
}
'@
$reader=$null;$check=$null
try {
    $reader=Start-TransportEvents -ApiPort $Port -Secret ''' + ps_quote(SECRET) + ''' -Tags @('path-a','path-b') -StallSeconds .4 -StallConns 2
    $null=Collect $reader .6
    Mode 'logs';$events=@(Collect $reader .7)
    Assert ($events.Count -eq 17) ("Expected 17 error events, got "+($events|ConvertTo-Json -Compress))
    Assert (@($events|Where-Object local).Count -eq 8) 'Local network/system DNS classification'
    Assert (@($events|Where-Object {$_.code -eq 'refused' -and -not $_.local}).Count -eq 2) 'Remote refusal is not local'
    Assert (@($events|Where-Object {$_.code -eq 'dns-error' -and -not $_.local}).Count -eq 1) 'Remote DNS is not local'
    Assert (@($events|Where-Object {$_.kind -eq 'conn-closed-error' -and $_.tag -eq ''}).Count -eq 1) 'Untagged close must not guess active path'
    Assert (@($events|Where-Object {$_.kind -eq 'conn-closed-error' -and $_.tag -eq 'path-b'}).Count -eq 1) 'Tagged log-context correlation'
    Assert (@($events|Where-Object {$_.tag -eq 'unknown'}).Count -eq 0) 'Unknown outbound is never trusted'
    foreach ($e in $events) {
        Assert ($e.at -gt 1700000000000 -and $e.local -is [bool]) 'Event contract types'
        Assert (($e|ConvertTo-Json -Compress) -notmatch 'private|secret|user:|password|https:') 'Secrets leaked into event'
    }
    foreach ($mode in @('download','idle','one','split','churn','disappear','probe','reconnect')) {
        Mode $mode;$events=@(Collect $reader 1.3)
        Assert ($events.Count -eq 0) ("False stall: "+$mode)
    }
    Mode 'stall';$events=@(Collect $reader 1.6)
    Assert ($events.Count -eq 1 -and $events[0].kind -eq 'stall-suspect' -and $events[0].tag -eq 'path-a') 'Two persistent upload-only connections should suspect once'
    Mode 'download';$null=Collect $reader .4
    Mode 'stall';$events=@(Collect $reader .8)
    Assert ($events.Count -eq 1) 'Recovery must reset suspicion'
    Mode 'idle';$null=Collect $reader .3
    Mode 'overflow';Start-Sleep -Milliseconds 600
    $events=@(Receive-TransportEvents $reader)
    Assert ($events.Count -eq 512 -and $reader.Dropped -ge 188) 'Bounded queue under error storm'
    Stop-TransportEvents $reader;Stop-TransportEvents $reader;$reader=$null
    Mode 'idle'
    Assert (-not (Test-Path (Join-Path $Root 'probe-pid'))) 'Passive subscriptions launched a probe'

    Mode 'logs'
    $reader=Start-TransportEvents -ApiPort $Port -Secret ''' + ps_quote(SECRET) + ''' -Tags @()
    $events=@(Collect $reader .6)
    Assert ($reader.LogsStatus -eq 'connected' -and $reader.ConnectionsStatus -eq 'connected') 'Empty tags must create a working reader'
    Assert (@($events|Where-Object {$_.tag -ne ''}).Count -eq 0) 'Empty allowlist must not trust any path tag'
    $elapsed=[DelayedTransportWorkers]::Stop($reader)
    Assert ($elapsed -lt 1500) ("Dispose waited for workers sequentially: "+$elapsed+' ms')
    Stop-TransportEvents $reader;$reader=$null
    Mode 'idle'

    # Direct checks are tested via loopback endpoints; production wrapper has the two fixed public IPs.
    $up=New-Object Net.IPEndPoint ([Net.IPAddress]::Loopback),''' + str(ports['direct']) + '''
    $down=New-Object Net.IPEndPoint ([Net.IPAddress]::Loopback),''' + str(ports['refused']) + '''
    $check=New-Object RemoteAgents.TransportCheck -ArgumentList '127.0.0.1',0,([Net.IPEndPoint[]]@($down,$up)),300
    $e=Wait-Check $check 'direct';Assert ($e.kind -eq 'net-up' -and -not $e.local) 'One endpoint success suffices'
    Stop-TransportDirectCheck $check
    $check=New-Object RemoteAgents.TransportCheck -ArgumentList '127.0.0.1',0,([Net.IPEndPoint[]]@($down,$down)),300
    $e=Wait-Check $check 'direct';Assert ($e.kind -eq 'net-down' -and $e.local) 'Both refused -> net-down'
    Stop-TransportDirectCheck $check
    $check=New-Object RemoteAgents.TransportCheck -ArgumentList 'invalid-binding',0,([Net.IPEndPoint[]]@($up,$up)),300
    $e=Wait-Check $check 'direct';Assert ($e.kind -eq 'net-down') 'Binding failure must not fall back to an unbound socket'
    Stop-TransportDirectCheck $check;$check=$null

    $ports=''' + ('@{' + ';'.join(k+'='+str(v) for k, v in ports.items()) + '}') + '''
    foreach ($mode in @('banner','partial','hang','fin','rst','refused','trickle')) {
        $candidate=[pscustomobject]@{tag='path-a';port=$ports[$mode]}
        $check=Start-TransportPathCheck $candidate -TimeoutSeconds 1.5
        $watch=[Diagnostics.Stopwatch]::StartNew();$e=Wait-Check $check 'path'
        $expected=switch($mode) {'banner' {'ok'} 'partial' {'stalled'} 'hang' {'timeout'} 'fin' {'process-exited'} 'rst' {'process-exited'} 'refused' {'refused'} 'trickle' {'stalled'}}
        Assert ($e.kind -eq 'path-check' -and $e.tag -eq 'path-a' -and $e.code -eq $expected) ("Banner check "+$mode+': '+$e.code)
        if ($mode -in @('fin','rst','hang')) {Assert ($e.detail -match 'bytes=0$') 'Close/timeout without banner must report zero bytes'}
        Assert ($watch.Elapsed.TotalSeconds -lt 3) 'Banner timeout exceeded by trickle'
        Stop-TransportPathCheck $check;Stop-TransportPathCheck $check;$check=$null
    }
    $profile=[pscustomobject]@{sshExecutable=(Join-Path $Root 'ssh.exe');keyPath='test-key';login='test';knownHostsPath='test-hosts';serverAddress='server.invalid'}
    $candidate=[pscustomobject]@{tag='path-a';port=26000}
    foreach ($mode in @('ok','stall','timeout','exit')) {
        [IO.File]::WriteAllText((Join-Path $Root 'mode'),$mode)
        # Leave startup/scheduling headroom before the total deadline; stall is still 300 ms.
        $check=Start-TransportPathCheck $candidate $profile -ConfirmStall -TimeoutSeconds 3 -StallSeconds .3
        $e=Wait-Check $check 'path';$expected=switch($mode) {'ok' {'ok'} 'stall' {'stalled'} 'timeout' {'timeout'} 'exit' {'process-exited'}}
        Assert ($e.code -eq $expected) ("64 KiB check "+$mode+': '+$e.code+'; '+$e.detail)
        if ($mode -eq 'ok') {Assert ($e.detail -match 'bytes=65536') 'Exactly 64 KiB required'}
        if ($mode -eq 'stall') {Assert ($e.detail -match 'bytes=16384$') 'Stall requires a partial transfer before silence'}
        Stop-TransportPathCheck $check;$check=$null
    }
    $profile.sshExecutable=Join-Path $Root 'missing-ssh'
    $check=Start-TransportPathCheck $candidate $profile -ConfirmStall
    $e=Wait-Check $check 'path';Assert ($e.code -eq 'process-exited') 'Start failure must produce contract event'
    Stop-TransportPathCheck $check;$check=$null
    'PASS: event subscriptions, classifier, stall continuity, reconnect, checks, cleanup'
    'PASS: FIN/RST -> process-exited, silent peer -> timeout, empty tags, shared Dispose deadline'
} finally {
    if ($reader) {Stop-TransportEvents $reader}
    if ($check) {if ($check.PSObject.Properties['mode']) {Stop-TransportPathCheck $check} else {Stop-TransportDirectCheck $check}}
}
''', encoding='utf-8-sig')
        result = subprocess.run([PWSH, '-NonInteractive', '-NoProfile', '-File', str(harness),
                                 '-Port', str(api_port), '-Root', str(root)],
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=90,
                                env=dict(os.environ, LOCALAPPDATA=str(root)))
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        print(result.stdout.strip())
        args = json.loads((root / 'probe-args').read_text())
        assert args[-1] == 'head -c 65536 /dev/urandom' and args[args.index('-p') + 1] == '26000', args
        assert 'StrictHostKeyChecking=yes' in args and 'BatchMode=yes' in args
        pid = int((root / 'probe-pid').read_text())
        assert not Path('/proc/%d' % pid).exists(), 'SSH check leaked child process'
        with lock:
            assert state['data'] and all(data == b'' for data in state['data']), 'Direct check sent payload'
            assert set(state['requests']) == {'/logs?level=warn', '/connections?interval=1000'}, state['requests']
            requests_before = state['connects']
        time.sleep(1.2)
        with lock:
            assert state['connects'] == requests_before, 'Reader reconnects after disposal'
        print('PASS: no external traffic, no payload in direct check, fixed WS endpoints, no leaked probes')
finally:
    api.shutdown()
    api.server_close()
    for server in servers:
        server.shutdown()
        server.server_close()
    refused.close()
