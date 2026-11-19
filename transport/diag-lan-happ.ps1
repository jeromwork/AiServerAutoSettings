#requires -Version 5.1
# Diagnostics for the clinic LAN channel while Happ is on. Manual run only (not part of the EXE).
# Userspace only: no admin rights, no changes to the system. Secrets are never printed.
#   -Mode check           A..E checks from vpn104-lan-fix.md section 3 + summary + VERDICT
#   -Mode probe-loopback  which loopback address can be used for port 53 while Happ is on
param(
    [ValidateSet('check','probe-loopback')][string]$Mode = 'check',
    [string]$Home_ = (Join-Path $env:LOCALAPPDATA 'RemoteAgents'),
    [string]$Name = 'portal.eastclinic.ru',
    [string]$Ip = '192.168.88.167',
    [string]$ClinicDns = '192.168.88.11',
    [string]$LoopbackDns = '127.31.254.53',
    [int]$SocksPort = 17880
)
$ErrorActionPreference = 'Continue'
$script:secrets = @()
function Hide([string]$s) { foreach ($x in $script:secrets) { if ($x) { $s = $s.Replace($x, '***') } }; $s }
function Out-Line([string]$s) { Write-Output (Hide $s) }

# Runs a script block in a runspace and gives up after $Sec seconds (Resolve-DnsName has no hard timeout).
function Invoke-Timed([scriptblock]$Block, [int]$Sec = 8, $Arg) {
    $ps = [powershell]::Create()
    [void]$ps.AddScript($Block.ToString()).AddArgument($Arg)
    $h = $ps.BeginInvoke()
    if ($h.AsyncWaitHandle.WaitOne($Sec * 1000)) {
        try { $r = $ps.EndInvoke($h); $ps.Dispose(); return [pscustomobject]@{ Done = $true; Result = @($r) } }
        catch { $ps.Dispose(); return [pscustomobject]@{ Done = $true; Result = @("error: $($_.Exception.Message)") } }
    }
    [void]$ps.BeginStop($null, $null)
    [pscustomobject]@{ Done = $false; Result = @() }
}

function Test-Resolve([string]$Server, [bool]$Tcp, [string]$Query = $Name, [int]$Sec = 8) {
    $r = Invoke-Timed {
        param($a)
        try {
            $p = @{ Name = $a.q; Type = 'A'; DnsOnly = $true; QuickTimeout = $true; ErrorAction = 'Stop' }
            if ($a.s) { $p.Server = $a.s }
            if ($a.t) { $p.TcpOnly = $true }
            $x = Resolve-DnsName @p | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress }
            if ($x) { 'ok ' + ($x -join ',') } else { 'empty' }
        } catch { 'fail ' + $_.Exception.Message.Split("`n")[0] }
    } $Sec @{ q = $Query; s = $Server; t = $Tcp }
    if (-not $r.Done) { return 'timeout' }
    [string]($r.Result | Select-Object -First 1)
}

function Test-Curl([string[]]$ExtraArgs) {
    $o = & curl.exe -s -m 8 -k -o NUL -w '%{http_code}' @ExtraArgs 2>&1
    [string]($o | Select-Object -Last 1)
}

# ---- SOCKS5 (RFC 1928/1929) + DNS over TCP, by hand ----
function Read-Exact($stream, [int]$n) {
    $buf = New-Object byte[] $n; $got = 0
    while ($got -lt $n) { $k = $stream.Read($buf, $got, $n - $got); if ($k -le 0) { throw 'eof' }; $got += $k }
    , $buf
}
function New-DnsQuery([string]$Qname, [uint16]$Id) {
    $m = New-Object System.IO.MemoryStream
    $m.WriteByte($Id -shr 8); $m.WriteByte($Id -band 255)
    foreach ($b in 1, 0, 0, 1, 0, 0, 0, 0, 0, 0) { $m.WriteByte($b) }
    foreach ($l in $Qname.Split('.')) { $bytes = [Text.Encoding]::ASCII.GetBytes($l); $m.WriteByte($bytes.Length); $m.Write($bytes, 0, $bytes.Length) }
    foreach ($b in 0, 0, 1, 0, 1) { $m.WriteByte($b) }
    $m.ToArray()
}
function Skip-DnsName([byte[]]$d, [int]$p) {
    while ($true) {
        $l = $d[$p]
        if ($l -eq 0) { return $p + 1 }
        if (($l -band 0xC0) -eq 0xC0) { return $p + 2 }
        $p += 1 + $l
    }
}
function Get-DnsA([byte[]]$d) {
    $rc = $d[3] -band 15; $qd = $d[4] * 256 + $d[5]; $an = $d[6] * 256 + $d[7]
    $p = 12
    for ($i = 0; $i -lt $qd; $i++) { $p = (Skip-DnsName $d $p) + 4 }
    $res = @()
    for ($i = 0; $i -lt $an; $i++) {
        $p = Skip-DnsName $d $p
        $type = $d[$p] * 256 + $d[$p + 1]; $len = $d[$p + 8] * 256 + $d[$p + 9]; $p += 10
        if ($type -eq 1 -and $len -eq 4) { $res += ('{0}.{1}.{2}.{3}' -f $d[$p], $d[$p + 1], $d[$p + 2], $d[$p + 3]) }
        $p += $len
    }
    [pscustomobject]@{ Rcode = $rc; A = $res }
}
function Test-SocksDns([string]$User, [string]$Pass, [string]$Target, [string]$Qname) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect('127.0.0.1', $SocksPort, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(3000)) { return 'socks-connect-timeout' }
        $c.EndConnect($iar)
        $c.ReceiveTimeout = 5000; $c.SendTimeout = 5000
        $s = $c.GetStream()
        $s.Write([byte[]](5, 1, 2), 0, 3)
        $r = Read-Exact $s 2
        if ($r[1] -ne 2) { return "socks-method-$($r[1])" }
        $u = [Text.Encoding]::UTF8.GetBytes($User); $pw = [Text.Encoding]::UTF8.GetBytes($Pass)
        $auth = [byte[]](@(1, $u.Length) + $u + @($pw.Length) + $pw)
        $s.Write($auth, 0, $auth.Length)
        $r = Read-Exact $s 2
        if ($r[1] -ne 0) { return 'socks-auth-failed' }
        $ipb = [Net.IPAddress]::Parse($Target).GetAddressBytes()
        $req = [byte[]](@(5, 1, 0, 1) + $ipb + @(0, 53))
        $s.Write($req, 0, $req.Length)
        $r = Read-Exact $s 4
        if ($r[1] -ne 0) { return "socks-connect-rep-$($r[1])" }
        if ($r[3] -eq 1) { [void](Read-Exact $s 6) } elseif ($r[3] -eq 4) { [void](Read-Exact $s 18) } else { $n = (Read-Exact $s 1)[0]; [void](Read-Exact $s ($n + 2)) }
        $q = New-DnsQuery $Qname 4242
        $pkt = [byte[]](@([byte]($q.Length -shr 8), [byte]($q.Length -band 255)) + $q)
        $s.Write($pkt, 0, $pkt.Length)
        $lenb = Read-Exact $s 2
        $resp = Read-Exact $s ($lenb[0] * 256 + $lenb[1])
        $a = Get-DnsA $resp
        if ($a.A.Count -gt 0) { return 'ok ' + ($a.A -join ',') }
        "no-answer rcode=$($a.Rcode)"
    } catch { 'fail ' + $_.Exception.Message } finally { $c.Close() }
}

function Get-SocketErr($e) {
    $x = $e; while ($x -and -not ($x -is [System.Net.Sockets.SocketException])) { $x = $x.InnerException }
    if ($x) { return '{0}({1})' -f $x.SocketErrorCode, $x.ErrorCode }
    $e.Message
}

function Test-TcpConnect([string]$Addr, [int]$Port, [int]$Ms = 3000) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($Addr, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($Ms)) { return 'timeout' }
        $c.EndConnect($iar); 'ok'
    } catch { Get-SocketErr $_.Exception } finally { $c.Close() }
}

function Get-TunIp {
    $a = Get-NetIPAddress -InterfaceAlias 'RemoteAgents-LAN' -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($a) { [string]$a.IPAddress }
}

# ---------------------------------------------------------------
function Invoke-ProbeLoopback {
    Out-Line "== probe-loopback $(Get-Date -Format o)"
    $tun = Get-TunIp
    $addrs = @($LoopbackDns); if ($tun) { $addrs += $tun } else { Out-Line 'RemoteAgents-LAN adapter: absent (only loopback probed)' }
    Out-Line ('Happ processes: ' + ((Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(happ|happd|xray)' } | ForEach-Object { $_.Name }) -join ','))
    foreach ($addr in $addrs) {
        Out-Line "-- $addr"
        $bind = 'n/a'; $udpRecv = 'n/a'; $resolveRecv = 'n/a'; $tcp = 'n/a'; $listenTcp = 'n/a'
        $srv = $null; $cli = $null; $tl = $null
        try {
            try { $srv = New-Object System.Net.Sockets.UdpClient([Net.IPEndPoint]::new([Net.IPAddress]::Parse($addr), 53)); $bind = 'ok' }
            catch { $bind = Get-SocketErr $_.Exception }
            Out-Line "bind-udp=$bind"
            if ($bind -eq 'ok') {
                $srv.Client.ReceiveTimeout = 2000
                $cli = New-Object System.Net.Sockets.UdpClient([Net.IPEndPoint]::new([Net.IPAddress]::Parse($addr), 0))
                [void]$cli.Send([byte[]](1, 2, 3, 4), 4, $addr, 53)
                try { $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0); $got = $srv.Receive([ref]$ep); $udpRecv = "ok($($got.Length)b)" }
                catch { $udpRecv = if ((Get-SocketErr $_.Exception) -match 'TimedOut') { 'timeout' } else { Get-SocketErr $_.Exception } }
                Out-Line "udp-raw-recv=$udpRecv"
                # Resolve-DnsName itself (the Windows resolver path) -> does the datagram reach our socket
                $rt = Invoke-Timed { param($a) try { [void](Resolve-DnsName -Name 'x.eastclinic.ru' -Server $a -DnsOnly -QuickTimeout -ErrorAction Stop) } catch { } } 5 $addr
                try { $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0); $got = $srv.Receive([ref]$ep); $resolveRecv = "ok($($got.Length)b)" }
                catch { $resolveRecv = if ((Get-SocketErr $_.Exception) -match 'TimedOut') { 'timeout' } else { Get-SocketErr $_.Exception } }
                Out-Line "resolve-dnsname-recv=$resolveRecv"
            }
            try { $tl = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Parse($addr), 53); $tl.Start(); $listenTcp = 'ok' }
            catch { $listenTcp = Get-SocketErr $_.Exception }
            Out-Line "listen-tcp=$listenTcp"
            if ($listenTcp -eq 'ok') { $tcp = Test-TcpConnect $addr 53 }
            Out-Line "connect-tcp=$tcp"
        } finally {
            foreach ($o in $cli, $srv) { if ($o) { try { $o.Close() } catch { } } }
            if ($tl) { try { $tl.Stop() } catch { } }
        }
        $verdict =
            if ($bind -match 'AddressAlreadyInUse' -or $listenTcp -match 'AddressAlreadyInUse') { 'bind-conflict' }
            elseif ($bind -eq 'ok' -and $udpRecv -like 'ok*' -and $listenTcp -eq 'ok' -and $tcp -eq 'ok') { 'allowed' }
            else { 'blocked' }
        $note = if ($verdict -eq 'allowed' -and $resolveRecv -notlike 'ok*') { ' (raw sockets ok, but Resolve-DnsName datagram did not arrive - see resolve-dnsname-recv)' } else { '' }
        Out-Line "LOOPBACK53 ${addr}: $verdict$note"
    }
    Out-Line '-- controls'
    Out-Line ("control tcp ${ClinicDns}:53 = " + (Test-TcpConnect $ClinicDns 53) + '   (expected 10013/refused while Happ DNS protection is active)')
    # A listener on 5300 proves the TCP path itself works on this address.
    $tl = $null; $c5 = 'n/a'
    try { $tl = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Parse($LoopbackDns), 5300); $tl.Start(); $c5 = Test-TcpConnect $LoopbackDns 5300 } catch { $c5 = 'listen-' + (Get-SocketErr $_.Exception) } finally { if ($tl) { $tl.Stop() } }
    Out-Line "control tcp ${LoopbackDns}:5300 = $c5   (expected ok)"
    # UDP control: same raw send/receive on port 5300 proves (5353 is exclusive to mDNS: bind gives 10013) the method itself works (only :53 should fail).
    $us = $null; $uc = $null; $u5 = 'n/a'
    try {
        $us = New-Object System.Net.Sockets.UdpClient([Net.IPEndPoint]::new([Net.IPAddress]::Parse($LoopbackDns), 5300)); $us.Client.ReceiveTimeout = 2000
        $uc = New-Object System.Net.Sockets.UdpClient([Net.IPEndPoint]::new([Net.IPAddress]::Parse($LoopbackDns), 0))
        [void]$uc.Send([byte[]](1, 2, 3, 4), 4, $LoopbackDns, 5300)
        $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0); $g = $us.Receive([ref]$ep); $u5 = "ok($($g.Length)b)"
    } catch { $u5 = if ((Get-SocketErr $_.Exception) -match 'TimedOut') { 'timeout' } else { Get-SocketErr $_.Exception } } finally { foreach ($o in $uc, $us) { if ($o) { try { $o.Close() } catch { } } } }
    Out-Line "control udp ${LoopbackDns}:5300 = $u5   (expected ok)"
    Out-Line ('UDP :53 endpoints: ' + ((Get-NetUDPEndpoint -LocalPort 53 -ErrorAction SilentlyContinue | ForEach-Object { "$($_.LocalAddress):$($_.OwningProcess)" }) -join ' '))
}

function Invoke-Check {
    $t0 = Get-Date
    Out-Line "== check $(Get-Date -Format o)"
    $sock = $null
    try {
        $sock = Get-Content -Raw -LiteralPath (Join-Path $Home_ 'state\helper-socks.json') | ConvertFrom-Json
        $script:secrets = @($sock.password, $sock.user) | Where-Object { $_ }
    } catch { Out-Line "helper-socks.json: unreadable ($($_.Exception.Message))" }

    $a = Test-Curl @('--resolve', "${Name}:443:$Ip", "https://$Name/yawizard"); Out-Line "A tcp443 via --resolve = $a"
    $b = if ($sock) { Test-SocksDns $sock.user $sock.password $ClinicDns $Name } else { 'no-credentials' }; Out-Line "B dns via SOCKS ($ClinicDns) = $b"
    $c1 = Test-Resolve '192.168.87.1' $true; Out-Line "C1 Resolve-DnsName -Server 192.168.87.1 -TcpOnly = $c1"
    $c2 = Test-Resolve '1.1.1.1' $false; Out-Line "C2 Resolve-DnsName -Server 1.1.1.1 = $c2"
    $lbBound = [bool](Get-NetUDPEndpoint -LocalAddress $LoopbackDns -LocalPort 53 -ErrorAction SilentlyContinue)
    $d1 = if ($lbBound) { Test-Resolve $LoopbackDns $false } else { 'not-listening (stage P1 not installed)' }; Out-Line "D1 Resolve-DnsName -Server $LoopbackDns = $d1"
    $d2 = Test-Resolve $null $false; Out-Line "D2 Resolve-DnsName (system/NRPT) = $d2"
    $e = Test-Curl @("https://$Name/yawizard"); Out-Line "E tcp443 by name = $e"

    Out-Line '-- summary'
    Out-Line ('adapters Up: ' + ((Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | ForEach-Object { $_.Name }) -join '; '))
    Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -or $_.DestinationPrefix -like '192.168.87.*' -or $_.DestinationPrefix -like '192.168.88.*' } |
        ForEach-Object { Out-Line ("route {0} nh={1} if={2} metric={3}" -f $_.DestinationPrefix, $_.NextHop, $_.InterfaceAlias, $_.RouteMetric) }
    Get-DnsClientNrptRule -ErrorAction SilentlyContinue | ForEach-Object { Out-Line ("nrpt ns={0} -> {1} [{2}]" -f ($_.Namespace -join ','), ($_.NameServers -join ','), $_.Comment) }
    Get-NetUDPEndpoint -LocalPort 53 -ErrorAction SilentlyContinue | ForEach-Object { Out-Line ("udp53 {0} pid={1}" -f $_.LocalAddress, $_.OwningProcess) }
    foreach ($f in 'status\vpn.json', 'status\transport.json') {
        Out-Line "-- $f"
        try {
            $j = Get-Content -Raw -LiteralPath (Join-Path $Home_ $f) | ConvertFrom-Json
            $keep = 'ok', 'enabled', 'state', 'stage', 'summary', 'errorType', 'conflict', 'active', 'phase', 'network', 'error', 'updatedAt', 'retryAt', 'fatal'
            foreach ($k in $keep) { if ($j.PSObject.Properties[$k]) { Out-Line ("  {0} = {1}" -f $k, $j.$k) } }
        } catch { Out-Line "  unreadable: $($_.Exception.Message)" }
    }
    Out-Line '-- transport.log (tail 20)'
    try { Get-Content -LiteralPath (Join-Path $Home_ 'logs\transport.log') -Tail 20 -ErrorAction Stop | ForEach-Object { Out-Line "  $_" } } catch { Out-Line "  unreadable: $($_.Exception.Message)" }

    $aOk = $a -match '^[1-9]\d\d$'; $bOk = $b -like "ok*$Ip*"
    $cBlocked = ($c1 -notlike 'ok*') -and ($c2 -notlike 'ok*')
    $verdict = if (-not $aOk -or -not $bOk) { 'our-path-broken' } elseif ($e -match '^[1-9]\d\d$') { 'ok' } elseif ($cBlocked) { 'happ-blocks-dns' } else { 'our-path-broken' }
    Out-Line ("A=$a B=$($b -replace '^(ok).*','$1') C-blocked=$cBlocked E=$e elapsed={0:n0}s" -f ((Get-Date) - $t0).TotalSeconds)
    Out-Line "VERDICT: $verdict"
}

if ($Mode -eq 'probe-loopback') { Invoke-ProbeLoopback } else { Invoke-Check }
