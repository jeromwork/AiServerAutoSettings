# Discovery is mocked; candidate construction and original-host key pinning are real.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('tailscale-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$count=0
function Check($Value,$Why){if(-not $Value){throw $Why};$script:count++}
try{
    $p=[pscustomobject]@{sshExecutable='ssh';serverAddress='203.0.113.10';login='worker';keyPath='fixture-key';knownHostsPath=(Join-Path $root 'known_hosts');arguments=@('-p','2222')}
    [IO.File]::WriteAllText($p.knownHostsPath,'203.0.113.10 ssh-ed25519 AAAA')
    Write-TransportJson (Join-Path $root 'config.json') @{profile=@{server=@{address=$p.serverAddress};tailscale=@{enabled=$true;hostname='fixture'}}}
    $script:status=@{BackendState='Running';TUN=$true;Peer=@{one=@{HostName='fixture';DNSName='fixture.tail.example.';TailscaleIPs=@('fd00::1','100.99.1.2');Online=$false}}}
    function Get-Command {param($Name,$CommandType,$ErrorAction) [pscustomobject]@{Source='tailscale-fixture'}}
    function Invoke-DiskProcess {param($Exe,$Arguments,$TimeoutSeconds) ($script:status|ConvertTo-Json -Depth 10).Replace("`n","`r`n")}
    $script:pinnedHost=''
    function Get-TransportHostKeys {param($Ssh,$HostName,$KnownHosts) $script:pinnedHost=$HostName;'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDKtkImHp4iQlyBtwBY4Vx3cBxfNF0Hdga/ucaszwI2r'}
    Check ((Get-TransportTailscaleAddress $root $p) -eq '100.99.1.2') 'unique IPv4 peer even if Online=false; real probe decides readiness'
    $settings=[pscustomobject]@{Profile=$p;Transport=[pscustomobject]@{channelFirst=$true};Options=@{openSsh=$false;probePortBase=26000;socksPortBase=28000};Channel=@{outbounds=@();inbounds=@()}}
    $paths=Get-TransportCandidates $settings $root
    $out=@($paths.Outbounds|Where-Object {$_.tag -eq 'tailscale'})
    Check ($out.Count -eq 1 -and $out[0].server -eq '100.99.1.2') 'Tailscale is an ordinary additional SSH candidate, including channel-first mode'
    Check ($script:pinnedHost -eq $p.serverAddress -and $out[0].host_key.Count -eq 1) 'original server host keys retained'
    Check (($paths.Candidates|Where-Object {$_.tag -eq 'tailscale'}).title -eq 'Tailscale') 'candidate title'
    $script:status.Peer.two=$script:status.Peer.one
    Check ($null -eq (Get-TransportTailscaleAddress $root $p)) 'ambiguous hostname refused'
    $script:status.Peer.Remove('two');$script:status.Peer.one.Expired=$true
    Check ($null -eq (Get-TransportTailscaleAddress $root $p)) 'expired peer refused'
    $script:status.Peer.one.Remove('Expired');$script:status.TUN=$false
    Check ($null -eq (Get-TransportTailscaleAddress $root $p)) 'local userspace client cannot route native SSH to 100.x'
    $script:status.TUN=$true;$script:status.BackendState='Stopped'
    Check ($null -eq (Get-TransportTailscaleAddress $root $p)) 'stopped client ignored'
    $script:status.BackendState='Running';$script:status.Peer.one.TailscaleIPs=@('8.8.8.8')
    Check ($null -eq (Get-TransportTailscaleAddress $root $p)) 'public address not accepted'
    function Invoke-DiskProcess {throw 'fixture CLI missing'}
    Check ($null -eq (Get-TransportTailscaleAddress $root $p)) 'CLI error preserves other routes'
    'PASS: Tailscale '+$count+' checks'
}finally{Remove-Item -Recurse -Force $root}
