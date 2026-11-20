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
# Core integration alone cannot catch missing .NET Framework references.
subprocess.run([sys.executable, str(EVENTS.with_name('test-transport-events-references.py'))], check=True)
SECRET = 'test-api-secret-do-not-publish'
lock = threading.Lock()
state = dict(mode='idle', version=0, requests=[], connects=0, data=[], progress={})


def frame(data, opcode=1, final=True):
    data = data.encode() if isinstance(data, str) else data
    n = len(data)
    return bytes([(128 if final else 0) | opcode, n if n < 126 else 126 if n < 65536 else 127]) + (
        b'' if n < 126 else struct.pack('!H' if n < 65536 else '!Q', n)) + data


def acknowledged(handler, version, seq):
    """A pong after the batch means the reader reached its next ReceiveAsync.

    TCP send completion alone does not mean the preceding events were parsed.
    ClientWebSocket handles this ping only as it reads past the preceding frames.
    """
    nonce = struct.pack('!QQ', version, seq)
    handler.connection.sendall(frame(nonce, opcode=9))

    def read(size):
        data = handler.rfile.read(size)
        if len(data) != size:
            raise ConnectionError('WebSocket closed before acknowledgement')
        return data

    while True:
        header = read(2)
        opcode, size = header[0] & 15, header[1] & 127
        if size in (126, 127):
            size = struct.unpack('!H' if size == 126 else '!Q', read(2 if size == 126 else 8))[0]
        mask = read(4) if header[1] & 128 else b''
        data = read(size)
        if mask:
            data = bytes(value ^ mask[i % 4] for i, value in enumerate(data))
        if opcode == 10 and data == nonce:
            return
        if opcode == 9:
            handler.connection.sendall(frame(data, opcode=10))
        elif opcode != 10:
            raise ConnectionError('WebSocket closed before acknowledgement')


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
                state['progress'] = {}
            self.send_response(200)
            self.send_header('Content-Length', '2')
            self.end_headers()
            self.wfile.write(b'{}')
            return
        if url.path == '/test/status':
            with lock:
                progress = dict(state['progress'])
            data = json.dumps(progress).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
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
        self.connection.settimeout(15)
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
                        acknowledged(self, version, seq)
                        with lock:
                            if state['version'] == version:
                                state['progress']['logs'] = True
                else:
                    # One sample per subscription cannot establish continuity,
                    # regardless of how long the scheduler pauses before close.
                    if mode == 'reconnect' and seq == 2:
                        self.connection.sendall(frame(b'\x03\xe8', opcode=8))
                        return
                    rows = []
                    if mode in ('stall', 'reconnect'):
                        with lock:
                            sample = state['progress'].get('connectionFrames', 0) + 1 if mode == 'reconnect' else seq
                        rows = [connection('a', sample * 100), connection('b', sample * 100)]
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
                    elif mode == 'disappear' and seq % 2:
                        rows = [connection('a', seq * 100), connection('b', seq * 100)]
                    elif mode == 'probe':
                        rows = [connection('a', seq * 100, inbound='direct/probe-path-a'),
                                connection('b', seq * 100, inbound='direct/probe-path-a')]
                    self.connection.sendall(frame(json.dumps(dict(connections=rows))))
                    acknowledged(self, version, seq)
                    with lock:
                        if state['version'] == version:
                            progress = state['progress']
                            now = time.monotonic()
                            progress.setdefault('firstConnection', now)
                            progress['connectionSeconds'] = now - progress['firstConnection']
                            progress['connectionFrames'] = progress.get('connectionFrames', 0) + 1
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
                self.request.settimeout(15)
                data = self.request.recv(1)
                with lock:
                    state['data'].append(data)
            elif mode in ('banner', 'partial', 'hang'):
                if mode == 'banner':
                    self.request.sendall(b'pre-banner\r\nSSH-2.0-fake\r\n')
                elif mode == 'partial':
                    self.request.sendall(b'SSH-2.0-')
                # Stay open until the check closes, even if the host is descheduled.
                # A successful banner must not race EndConnect against server EOF.
                self.request.settimeout(30)
                self.request.recv(1)
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
                until = time.monotonic() + 30
                while time.monotonic() < until:
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


def wait_until(condition, message, timeout=15):
    deadline = time.monotonic() + timeout
    while True:
        if condition():
            return
        if time.monotonic() >= deadline:
            raise AssertionError('Deadline exceeded: ' + message)
        time.sleep(.03)


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
function Mode([string]$Name) { $null=Invoke-RestMethod ("http://127.0.0.1:$Port/test?mode=$Name") -NoProxy -TimeoutSec 15 }
function Wait-Until([scriptblock]$Condition,[string]$Message,[double]$TimeoutSeconds=15) {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    do {
        $value=& $Condition
        if ($value) { return $value }
        Start-Sleep -Milliseconds 30
    } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw "Deadline exceeded: $Message ($TimeoutSeconds s)"
}
function Collect-Until($Reader,[scriptblock]$Condition,[string]$Message) {
    $all=@();$watch=[Diagnostics.Stopwatch]::StartNew()
    do {
        $progress=Invoke-RestMethod ("http://127.0.0.1:$Port/test/status") -NoProxy -TimeoutSec 15
        $all+=@(Receive-TransportEvents $Reader)
        if (& $Condition $all $progress) { return $all }
        Start-Sleep -Milliseconds 30
    } while ($watch.Elapsed.TotalSeconds -lt 15)
    throw "Event deadline exceeded: $Message; events=$($all.Count); progress=$($progress|ConvertTo-Json -Compress)"
}
function Wait-Mode($Reader,[double]$Seconds=0,[int]$Frames=1) {
    # Negative tests need observation coverage, not a fixed sleep. Count only
    # snapshots acknowledged by the reader, including across WS reconnects.
    Collect-Until $Reader {
        param($events,$progress)
        $progress.logs -and $progress.connectionFrames -ge $Frames -and $progress.connectionSeconds -ge $Seconds
    } 'acknowledged fixture mode'
}
function Wait-Check($Handle,[string]$Type,[double]$TimeoutSeconds=10) {
    Wait-Until {
        if ($Type -eq 'path') { Receive-TransportPathCheck $Handle } else { Receive-TransportDirectCheck $Handle }
    } "check $Type" $TimeoutSeconds
}
Initialize-TransportEvents
# Emulate delayed cancellation on older .NET without depending on network scheduling.
# The production reader still owns and cancels its real subscriptions.
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Concurrent;
using System.Runtime.ExceptionServices;
public static class TransportCheckFailures {
    static readonly ConcurrentQueue<string> errors=new ConcurrentQueue<string>();
    public static void Start() {
        AppDomain.CurrentDomain.FirstChanceException+=delegate(object sender,FirstChanceExceptionEventArgs e) {
            if(Environment.StackTrace.Contains("RemoteAgents.TransportCheck")) errors.Enqueue(e.Exception.ToString());
        };
    }
    public static string Drain() {
        string error;string all="";
        while(errors.TryDequeue(out error)) all+=error+Environment.NewLine;
        return all;
    }
}
public static class DelayedTransportWorkers {
    public static Task<long> BeginStop(object reader) {
        return Task.Factory.StartNew(delegate() {return Stop(reader);});
    }
    public static long Stop(object reader) {
        FieldInfo field=reader.GetType().GetField("workers",BindingFlags.NonPublic|BindingFlags.Instance);
        Thread[] original=(Thread[])field.GetValue(reader);
        Thread[] workers=new Thread[6];
        using(ManualResetEvent release=new ManualResetEvent(false)) {
            for(int i=0;i<workers.Length;i++) {
                workers[i]=new Thread(delegate() {release.WaitOne();});
                workers[i].IsBackground=true;
                workers[i].Start();
            }
            try {
                field.SetValue(reader,workers);
                Stopwatch watch=Stopwatch.StartNew();
                ((IDisposable)reader).Dispose();
                return watch.ElapsedMilliseconds;
            } finally {
                release.Set();
                foreach(Thread worker in workers) worker.Join();
                field.SetValue(reader,original);
                foreach(Thread worker in original) worker.Join(1000);
            }
        }
    }
}
'@
$reader=$null;$check=$null
try {
    $reader=Start-TransportEvents -ApiPort $Port -Secret ''' + ps_quote(SECRET) + ''' -Tags @('path-a','path-b') -StallSeconds .4 -StallConns 2
    $null=Wait-Mode $reader
    Mode 'logs';$events=@(Wait-Mode $reader)
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
    foreach ($mode in @('download','idle','one','split','churn','disappear','probe')) {
        Mode $mode;$events=@(Wait-Mode $reader 1.3 6)
        Assert ($events.Count -eq 0) ("False stall: "+$mode)
    }
    Mode 'reconnect';$events=@(Wait-Mode $reader 1.3 3)
    Assert ($events.Count -eq 0) 'Reconnect must break sample continuity'
    Mode 'stall';$events=@(Collect-Until $reader {param($events,$progress) $events.Count -gt 0} 'first stall suspicion')
    $events+=@(Wait-Mode $reader 1.3 6)
    Assert ($events.Count -gt 0 -and $events.Count -le 2 -and @($events|Where-Object {$_.kind -ne 'stall-suspect' -or $_.tag -ne 'path-a'}).Count -eq 0) 'Two persistent upload-only connections should suspect their path at most twice'
    Mode 'download';$null=Wait-Mode $reader 0 2
    Mode 'stall';$events=@(Collect-Until $reader {param($events,$progress) $events.Count -gt 0} 'suspicion after recovery')
    Assert ($events.Count -gt 0 -and @($events|Where-Object {$_.kind -ne 'stall-suspect' -or $_.tag -ne 'path-a'}).Count -eq 0) 'Recovery must reset suspicion'
    Mode 'idle';$null=Wait-Mode $reader
    $dropped=$reader.Dropped
    Mode 'overflow'
    # Do not drain while waiting: the queue must actually fill and drop events.
    $null=Wait-Until {$reader.Dropped -gt $dropped} 'queue overflow'
    $events=@(Receive-TransportEvents $reader)
    Assert ($events.Count -gt 0 -and $events.Count -le 512 -and $reader.Dropped -gt $dropped) 'Bounded queue under error storm'
    Stop-TransportEvents $reader;Stop-TransportEvents $reader;$reader=$null
    Mode 'idle'
    Assert (-not (Test-Path (Join-Path $Root 'probe-pid'))) 'Passive subscriptions launched a probe'

    Mode 'logs'
    $reader=Start-TransportEvents -ApiPort $Port -Secret ''' + ps_quote(SECRET) + ''' -Tags @()
    $events=@(Wait-Mode $reader)
    Assert ($reader.LogsStatus -eq 'connected' -and $reader.ConnectionsStatus -eq 'connected') 'Empty tags must create a working reader'
    Assert ($events.Count -eq 17) 'Empty allowlist must still parse the complete error batch'
    Assert (@($events|Where-Object {$_.tag -ne ''}).Count -eq 0) 'Empty allowlist must not trust any path tag'
    $stop=[DelayedTransportWorkers]::BeginStop($reader)
    # Six blocked workers separate a shared 1 s deadline from sequential 6 s waits.
    $null=Wait-Until {$stop.IsCompleted} 'Dispose with blocked workers' 10
    Assert (-not $stop.IsFaulted) ("Dispose failed: "+$stop.Exception)
    Assert ($stop.Result -lt 4000) ("Dispose exceeded shared deadline: "+$stop.Result+' ms')
    Stop-TransportEvents $reader;$reader=$null
    Mode 'idle'

    # Direct checks are tested via loopback endpoints; production wrapper has the two fixed public IPs.
    $up=New-Object Net.IPEndPoint ([Net.IPAddress]::Loopback),''' + str(ports['direct']) + '''
    $down=New-Object Net.IPEndPoint ([Net.IPAddress]::Loopback),''' + str(ports['refused']) + '''
    $check=New-Object RemoteAgents.TransportCheck -ArgumentList '127.0.0.1',0,([Net.IPEndPoint[]]@($down,$up)),1500
    $e=Wait-Check $check 'direct';Assert ($e.kind -eq 'net-up' -and -not $e.local) 'One endpoint success suffices'
    Stop-TransportDirectCheck $check
    $check=New-Object RemoteAgents.TransportCheck -ArgumentList '127.0.0.1',0,([Net.IPEndPoint[]]@($down,$down)),1500
    $e=Wait-Check $check 'direct';Assert ($e.kind -eq 'net-down' -and $e.local) 'Both refused -> net-down'
    Stop-TransportDirectCheck $check
    $check=New-Object RemoteAgents.TransportCheck -ArgumentList 'invalid-binding',0,([Net.IPEndPoint[]]@($up,$up)),1500
    $e=Wait-Check $check 'direct';Assert ($e.kind -eq 'net-down') 'Binding failure must not fall back to an unbound socket'
    Stop-TransportDirectCheck $check;$check=$null

    $ports=''' + ('@{' + ';'.join(k+'='+str(v) for k, v in ports.items()) + '}') + '''
    # Inject WSAECONNABORTED: a loopback peer cannot deterministically cause a local stack abort.
    $failure=[RemoteAgents.TransportCheck].GetMethod('BannerFailure',[Reflection.BindingFlags]'NonPublic,Static')
    $aborted=[Net.Sockets.SocketException]::new([int][Net.Sockets.SocketError]::ConnectionAborted)
    Assert ($aborted.SocketErrorCode -eq [Net.Sockets.SocketError]::ConnectionAborted) 'Abort fixture socket code'
    foreach ($abortError in @($aborted,[IO.IOException]::new('test abort',$aborted))) {
        Assert ($failure.Invoke($null,[object[]]@($abortError,0)) -eq 'timeout') 'Local abort without bytes must remain timeout'
        Assert ($failure.Invoke($null,[object[]]@($abortError,12)) -eq 'stalled') 'Local abort after partial bytes must remain stalled'
    }
    [TransportCheckFailures]::Start()
    $bannerTimeout=3;$schedulerSlack=5
    foreach ($mode in @('banner','partial','hang','fin','rst','refused','trickle')) {
        $candidate=[pscustomobject]@{tag='path-a';port=$ports[$mode]}
        $check=Start-TransportPathCheck $candidate -TimeoutSeconds $bannerTimeout
        $e=Wait-Check $check 'path' ($bannerTimeout+$schedulerSlack)
        $expected=switch($mode) {'banner' {'ok'} 'partial' {'stalled'} 'hang' {'timeout'} 'fin' {'process-exited'} 'rst' {'process-exited'} 'refused' {'refused'} 'trickle' {'stalled'}}
        $failures=[TransportCheckFailures]::Drain()
        Assert ($e.kind -eq 'path-check' -and $e.tag -eq 'path-a' -and $e.code -eq $expected) ("Banner check "+$mode+': '+$e.code+'; '+$e.detail+'; '+$failures)
        if ($mode -in @('fin','rst','hang')) {Assert ($e.detail -match 'bytes=0$') 'Close/timeout without banner must report zero bytes'}
        if ($mode -eq 'trickle') {
            Assert ($e.detail -match '^ms=(\\d+); bytes=') 'Trickle check must report elapsed time'
            Assert ([long]$Matches[1] -le (($bannerTimeout+$schedulerSlack)*1000)) 'Banner deadline plus scheduling allowance exceeded by trickle'
        }
        Stop-TransportPathCheck $check;Stop-TransportPathCheck $check;$check=$null
    }
    $profile=[pscustomobject]@{sshExecutable=(Join-Path $Root 'ssh.exe');keyPath='test-key';login='test';knownHostsPath='test-hosts';serverAddress='server.invalid'}
    $candidate=[pscustomobject]@{tag='path-a';port=26000}
    foreach ($mode in @('ok','stall','timeout','exit')) {
        [IO.File]::WriteAllText((Join-Path $Root 'mode'),$mode)
        # Include fake ssh startup in the total budget; partial-transfer stall stays 300 ms.
        $checkTimeout=6;if ($mode -eq 'stall') {$checkTimeout=3}
        $check=Start-TransportPathCheck $candidate $profile -ConfirmStall -TimeoutSeconds $checkTimeout -StallSeconds .3
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
    'PASS: FIN/RST -> process-exited, local abort -> timeout/stalled, empty tags, shared Dispose deadline'
} finally {
    if ($reader) {Stop-TransportEvents $reader}
    if ($check) {if ($check.PSObject.Properties['mode']) {Stop-TransportPathCheck $check} else {Stop-TransportDirectCheck $check}}
}
''', encoding='utf-8-sig')
        result = subprocess.run([PWSH, '-NonInteractive', '-NoProfile', '-File', str(harness),
                                 '-Port', str(api_port), '-Root', str(root)],
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=180,
                                env=dict(os.environ, LOCALAPPDATA=str(root)))
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        print(result.stdout.strip())
        args = json.loads((root / 'probe-args').read_text())
        assert args[-1] == 'head -c 65536 /dev/urandom' and args[args.index('-p') + 1] == '26000', args
        assert 'StrictHostKeyChecking=yes' in args and 'BatchMode=yes' in args
        pid = int((root / 'probe-pid').read_text())
        wait_until(lambda: not Path('/proc/%d' % pid).exists(), 'SSH check leaked child process')
        def direct_finished():
            with lock:
                return bool(state['data'])
        wait_until(direct_finished, 'Direct endpoint did not observe client close')
        with lock:
            assert all(data == b'' for data in state['data']), 'Direct check sent payload'
            assert set(state['requests']) == {'/logs?level=warn', '/connections?interval=1000'}, state['requests']
            requests_before = state['connects']
        # Observe the first reconnect interval; check continuously rather than
        # sleeping and assuming all asynchronous cleanup finished in that time.
        observe_until = time.monotonic() + 1.2
        while time.monotonic() < observe_until:
            with lock:
                assert state['connects'] == requests_before, 'Reader reconnects after disposal'
            time.sleep(.03)
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
