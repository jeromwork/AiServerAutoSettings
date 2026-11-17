#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
function Assert($ok,[string]$message){if(-not $ok){throw $message}}
$root=Join-Path ([IO.Path]::GetTempPath()) ('lan-test-'+[guid]::NewGuid().ToString('N'))
try{
    [void][IO.Directory]::CreateDirectory($root)
    $profile=@{lan=@(@{name='office';testHost='10.123.0.1';testPort=443;share=@{subnets=@('10.123.0.0/24');domains=@('*.example.org');dnsServers=@('10.123.0.53');forwards=@(@{name='ssh';host='10.123.0.2';port=22;localPort=18222})}})}
    $json=ConvertTo-Json @{profile=$profile} -Depth 20
    $file=Join-Path $root 'config.json'
    [IO.File]::WriteAllText($file,$json.Replace("`r",'').Replace("`n","`r`n"),(New-Object Text.UTF8Encoding($true)))
    $lan=Get-TransportLan (Read-TransportJson $file)
    Assert ($lan.enabled -and $lan.probeHost -eq '10.123.0.1' -and $lan.probePort -eq 443 -and @($lan.forwards).Count -eq 0) 'CRLF public profile parsed'
    Assert (-not (Get-TransportLan ([pscustomobject]@{})).enabled) 'old config stays disabled'
    $only=Get-TransportLan ('{"profile":{"lan":[{"share":{"forwards":[{"name":"db","host":"db.example.org","port":5432,"localPort":15432}]}}]}}'|ConvertFrom-Json)
    Assert (-not $only.enabled -and @($only.subnets).Count -eq 0 -and @($only.domains).Count -eq 0 -and @($only.dnsServers).Count -eq 0 -and @($only.forwards).Count -eq 0 -and -not $only.probeHost -and $only.probePort -eq 0) 'optional arrays: deprecated forwards do not enable LAN or provide a probe'
    $probe=Get-TransportLan ('{"profile":{"lan":[{"testHost":"10.124.0.1","testPort":8443,"share":{"subnets":["10.124.0.0/24"],"forwards":[{"host":"db.example.org","port":5432}]}}]}}'|ConvertFrom-Json)
    Assert ($probe.enabled -and $probe.probeHost -eq '10.124.0.1' -and $probe.probePort -eq 8443 -and @($probe.forwards).Count -eq 0) 'probe comes from testHost/testPort, ignoring forwards'
    $t=[pscustomobject]@{channelFirst=$false}
    $settings=[pscustomobject]@{Transport=$t;Profile=[pscustomobject]@{arguments=@('-p','22')};Channel=[pscustomobject]@{inbounds=@()};Options=(Get-TransportPortDefaults);Lan=$lan}
    # A synthetic snapshot reserves ports without touching any real network setting.
    function Get-TransportPortSnapshot {[pscustomobject]@{listeners=@([pscustomobject]@{address='127.0.0.1';port=17880;pid=0});processes=@()}}
    $settings=Resolve-TransportPorts $root $settings 1 1
    Assert ($settings.Lan.proxyPort -ne 17880 -and @($settings.Lan.forwards).Count -eq 0) 'occupied helper port relocated, no forward ports allocated'
    $saved=Read-TransportJson (Join-Path $root 'state/transport-ports.json')
    Assert ($saved.effective.lanProxyPort -eq $settings.Lan.proxyPort -and $saved.effective.lan.proxyPort -eq $settings.Lan.proxyPort -and @($saved.effective.lan.forwards).Count -eq 0 -and @($saved.moved|Where-Object {$_.key -eq 'lanProxyPort'}).Count -eq 1 -and @($saved.moved|Where-Object {$_.key -like 'lan-fwd-*'}).Count -eq 0) 'effective helper port published without forward ports'
    $paths=[pscustomobject]@{Candidates=@([pscustomobject]@{tag='fixture';port=26000});Outbounds=@([pscustomobject]@{type='socks';tag='fixture';server='127.0.0.1';server_port=31000})}
    $cfg=New-TransportConfig $settings $paths 'fixture' 'fixture'
    Assert (@($cfg.inbounds|Where-Object {$_.tag -like 'lan-*' -and $_.listen -ne '127.0.0.1'}).Count -eq 0) 'all LAN listeners loopback only'
    Assert (@($cfg.inbounds|Where-Object {$_.tag -eq 'lan-proxy' -or $_.tag -like 'lan-fwd-*'}).Count -eq 0) 'deprecated proxy and forwards create no listeners'
    $helper=@($cfg.inbounds|Where-Object {$_.tag -eq 'lan-in'})
    Assert ($helper.Count -eq 1 -and $helper[0].type -eq 'mixed' -and $helper[0].listen_port -eq $settings.Lan.proxyPort -and @($helper[0].users).Count -eq 1 -and $helper[0].users[0].password) 'LAN helper uses authenticated mixed input'
    $lanRules=@($cfg.route.rules|Where-Object {$_.inbound -contains 'lan-in'})
    Assert ($lanRules.Count -eq 2 -and $lanRules[0].action -eq 'route' -and $lanRules[0].outbound -eq 'active' -and ($lanRules[0].ip_cidr -join ',') -eq '10.123.0.0/24' -and $lanRules[1].action -eq 'reject' -and @($lanRules|Where-Object {$_.domain -or $_.domain_regex -or $_.port}).Count -eq 0) 'CIDR allowlist routes through active and rejects remainder'
    $exe=Get-Command sing-box -ErrorAction SilentlyContinue
    if($exe){$candidate=Join-Path $root 'candidate.json';Write-TransportJson $candidate $cfg;& $exe.Source check -c $candidate;if($LASTEXITCODE -ne 0){throw 'sing-box client config rejected'}}
    Write-Output 'PASS: LAN config, migration, CRLF, ports, scoped routes'
}finally{if(Test-Path $root){Remove-Item -Recurse -Force $root}}
