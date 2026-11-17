#requires -Version 5.1
[CmdletBinding()]
param([Alias('Home')][string]$TransportHome=(Join-Path $env:LOCALAPPDATA 'RemoteAgents'))
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
# Read-only acceptance: uses only an already running proxy. No registry/routes,
# DNS settings, adapters, services, processes or transport configuration are changed.
$root=Get-TransportHome $TransportHome
$status=Read-TransportJson (Join-Path $root 'status/transport.json')
$stamp=[DateTime]::Parse([string]$status.updatedAt,[Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
if(([DateTime]::UtcNow-$stamp).TotalSeconds -gt 15 -or ([DateTime]::UtcNow-$stamp).TotalSeconds -lt -5 -or -not $status.ok -or -not $status.lan.enabled){throw 'Нет свежего проверенного канала с lan.share'}
$lan=$status.lan
if([string]$lan.proxyAddress -cne '127.0.0.1' -or [int]$lan.proxyPort -lt 1 -or [int]$lan.proxyPort -gt 65535){throw 'Прокси должен слушать 127.0.0.1'}
function Test-LanConnect([string]$Target,[int]$Port) {
    # http_connect proves the remote CONNECT; a non-HTTP SSH/DB response may make
    # curl fail later, which does not erase the already received CONNECT result.
    if($Target -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]*$' -or $Port -lt 1 -or $Port -gt 65535){throw 'Неверная цель пробы'}
    $sink='NUL';if($env:OS -ne 'Windows_NT'){$sink='/dev/null'}
    $curl='curl.exe';if($env:OS -ne 'Windows_NT'){$curl='curl'}
    $answer=& $curl --disable --silent --connect-timeout 2 --max-time 3 --noproxy '' --proxy ('http://127.0.0.1:'+$lan.proxyPort) --proxytunnel --output $sink --write-out '%{http_connect}' ('http://'+$Target+':'+$Port+'/') 2>$null
    return (([string]($answer -join '')).Trim() -eq '200')
}
$ok=Test-LanConnect ([string]$lan.probeHost) ([int]$lan.probePort)
$rows=@([pscustomobject]@{name='first-host';remoteConnect=$ok;localTcp=$null})
foreach($f in @($lan.forwards)){
    $tcp=$false;$client=New-Object Net.Sockets.TcpClient
    try{$task=$client.ConnectAsync('127.0.0.1',[int]$f.localPort);$tcp=$task.Wait(1000) -and $client.Connected}catch{}finally{$client.Dispose()}
    $remote=Test-LanConnect ([string]$f.host) ([int]$f.port)
    $rows+=[pscustomobject]@{name=$f.name;localPort=[int]$f.localPort;localTcp=$tcp;remoteConnect=$remote}
    $ok=$ok -and $tcp -and $remote
}
[pscustomobject]@{ok=[bool]$ok;proxy=('127.0.0.1:'+$lan.proxyPort);checks=$rows;note='localTcp проверяет локальный слушатель; remoteConnect — TCP цели через mixed-прокси. Сеть Windows не изменялась.'}|ConvertTo-Json -Depth 8
if(-not $ok){exit 1}
