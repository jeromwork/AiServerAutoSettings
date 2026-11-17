#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
function Assert($ok,[string]$message){if(-not $ok){throw $message}}
$root=Join-Path ([IO.Path]::GetTempPath()) ('lan-test-'+[guid]::NewGuid().ToString('N'))
try{
    [void][IO.Directory]::CreateDirectory($root)
    $profile=@{lan=@(@{name='office';testHost='10.123.0.1';testPort=443;share=@{subnets=@('10.123.0.0/24');domains=@('*.example.org');forwards=@(@{name='ssh';host='10.123.0.2';port=22;localPort=18222})}})}
    $json=ConvertTo-Json @{profile=$profile} -Depth 20
    $file=Join-Path $root 'config.json'
    [IO.File]::WriteAllText($file,$json.Replace("`r",'').Replace("`n","`r`n"),(New-Object Text.UTF8Encoding($true)))
    $lan=Get-TransportLan (Read-TransportJson $file)
    Assert ($lan.enabled -and $lan.probeHost -eq '10.123.0.1') 'CRLF public profile parsed'
    Assert (-not (Get-TransportLan ([pscustomobject]@{})).enabled) 'old config stays disabled'
    $only=Get-TransportLan ('{"profile":{"lan":[{"share":{"forwards":[{"name":"db","host":"db.example.org","port":5432,"localPort":15432}]}}]}}'|ConvertFrom-Json)
    Assert ($only.probeHost -eq 'db.example.org' -and $only.probePort -eq 5432) 'optional arrays and forward probe'
    $t=[pscustomobject]@{channelFirst=$false}
    $settings=[pscustomobject]@{Transport=$t;Profile=[pscustomobject]@{arguments=@('-p','22')};Channel=[pscustomobject]@{inbounds=@()};Options=(Get-TransportPortDefaults);Lan=$lan}
    # A synthetic snapshot reserves ports without touching any real network setting.
    function Get-TransportPortSnapshot {[pscustomobject]@{listeners=@([pscustomobject]@{address='127.0.0.1';port=17880;pid=0},[pscustomobject]@{address='127.0.0.1';port=18222;pid=0});processes=@()}}
    $settings=Resolve-TransportPorts $root $settings 1 1
    Assert ($settings.Lan.proxyPort -ne 17880 -and $settings.Lan.forwards[0].localPort -ne 18222) 'occupied ports relocated'
    $saved=Read-TransportJson (Join-Path $root 'state/transport-ports.json')
    Assert ($saved.effective.lan.forwards[0].localPort -eq $settings.Lan.forwards[0].localPort -and @($saved.moved).Count -ge 2) 'effective ports published in state'
    $paths=[pscustomobject]@{Candidates=@([pscustomobject]@{tag='fixture';port=26000});Outbounds=@([pscustomobject]@{type='socks';tag='fixture';server='127.0.0.1';server_port=31000})}
    $cfg=New-TransportConfig $settings $paths 'fixture' 'fixture'
    Assert (@($cfg.inbounds|Where-Object {$_.tag -like 'lan-*' -and $_.listen -ne '127.0.0.1'}).Count -eq 0) 'all LAN listeners loopback only'
    $forward=@($cfg.inbounds|Where-Object {$_.tag -like 'lan-fwd-*'})[0]
    Assert ($forward.override_address -eq '10.123.0.2' -and $forward.override_port -eq 22) 'direct forward destination'
    $lanRules=@($cfg.route.rules|Where-Object {$_.inbound -contains 'lan-proxy'})
    Assert ($lanRules[-1].action -eq 'reject' -and $lanRules[0].outbound -eq 'active') 'allowlist routes through active and rejects remainder'
    $exe=Get-Command sing-box -ErrorAction SilentlyContinue
    if($exe){$candidate=Join-Path $root 'candidate.json';Write-TransportJson $candidate $cfg;& $exe.Source check -c $candidate;if($LASTEXITCODE -ne 0){throw 'sing-box client config rejected'}}
    Write-Output 'PASS: LAN config, migration, CRLF, ports, scoped routes'
}finally{if(Test-Path $root){Remove-Item -Recurse -Force $root}}
