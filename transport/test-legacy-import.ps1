#requires -Version 5.1
param([string]$SingBox='')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'build/Migrate.Common.ps1')
$work=Join-Path ([IO.Path]::GetTempPath()) ('legacy-import-'+[guid]::NewGuid().ToString('N'))
$oldLocal=$env:LOCALAPPDATA;$env:LOCALAPPDATA=$work;$count=0
function Assert($Ok,[string]$Name){if(-not $Ok){throw ('FAIL legacy: '+$Name)};$script:count++}
try{
    $root=Join-Path $work 'RemoteAgents';$disk=Join-Path $work 'RemoteDisk';$channelPath=Join-Path $disk 'channel/config.json'
    $profile=Join-Path $work 'profile.json';$key=Join-Path $work 'key';$known=Join-Path $work 'known_hosts'
    [void][IO.Directory]::CreateDirectory((Split-Path $channelPath -Parent))
    $ssh='ssh';$kg=(Get-Command ssh-keygen -ErrorAction Stop).Source
    [void](Invoke-TransportText $kg @('-q','-t','ed25519','-N','','-f',$key))
    [IO.File]::WriteAllText($known,('server.example.invalid '+[IO.File]::ReadAllText($key+'.pub')))
    Write-TransportJson $profile @{sshExecutable=$ssh;serverAddress='server.example.invalid';login='tester';keyPath=$key;knownHostsPath=$known;arguments=@()}
    [IO.File]::WriteAllText((Join-Path $disk 'profile.txt'),($profile+"`r`n"))
    $channel=Read-TransportJson (Join-Path $PSScriptRoot 'fixtures/legacy-hop.json')
    $channel.outbounds[2].private_key_path=$key
    # Exercise the actual file reader with BOM + CRLF, as on Windows PowerShell 5.1.
    [IO.File]::WriteAllText($channelPath,((ConvertTo-Json -InputObject $channel -Depth 40).Replace("`r",'').Replace("`n","`r`n")),(New-Object Text.UTF8Encoding($true)))
    Write-TransportJson (Join-Path $root 'config.json') @{transport=@{bindPhysical=$false;openSsh=$false;entries=@(@{name='user-entry';ssh='keep';enabled=$false})}}
    $c=Import-MigrationConfig $root $disk
    Assert ($c.transport.hops.Count -eq 1 -and $c.transport.hops[0].legacyOutbound -ceq 'vless-hop') 'CRLF hop imported'
    Assert ($c.transport.entries[0].name -ceq 'user-entry' -and -not $c.transport.entries[0].enabled) 'user entries preserved'
    $text=[IO.File]::ReadAllText((Join-Path $root 'config.json'))
    Assert ($text -notmatch 'private_key|00000000|hop.example.invalid') 'only references, no copied credentials/endpoints'
    $c.transport.hops[0].enabled=$false;Write-TransportJson (Join-Path $root 'config.json') $c
    $c=Import-MigrationConfig $root $disk
    Assert ($c.transport.hops.Count -eq 1 -and -not $c.transport.hops[0].enabled) 'repeat import preserves disable'
    $c.transport.hops[0].enabled=$true;Write-TransportJson (Join-Path $root 'config.json') $c
    $settings=Read-TransportSettings $root;$paths=Get-TransportCandidates $settings $root
    $candidate=@($paths.Candidates|Where-Object {$_.tag -like 'legacy-*'})
    Assert ($candidate.Count -eq 1 -and $candidate[0].title -eq 'VLESS через SSH-переход') 'hop candidate has readable title'
    $route=@($paths.Outbounds|Where-Object {$_.tag -eq $candidate[0].tag})[0]
    $hop=@($paths.Outbounds|Where-Object {$_.tag -eq $route.detour})[0]
    Assert ($route.server -ceq 'server.example.invalid' -and $hop.server -ceq 'hop.example.invalid' -and $hop.type -eq 'ssh') 'detour graph preserved'
    Assert ($hop.private_key_path -ceq $key -and -not $hop.host_key) 'original key reference and host-key policy preserved'
    $cfg=New-TransportConfig $settings $paths 'fixture-secret' $candidate[0].tag
    if($SingBox){$file=Join-Path $work 'check.json';Write-TransportJson $file $cfg -Private;Test-TransportConfigFile $SingBox $file;Assert $true 'real sing-box check of imported graph'}
    Assert ($candidate[0].tag -in @(Get-TransportRankTags @(Get-TransportRemembered @{networks=@{}} '' $paths.AllCandidates) $paths.Candidates @{topOnMetered=1} $true)) 'metered budget prioritizes imported route'
    # Runtime first start also discovers legacy routes without a previous migration marker.
    $c.transport.hops=@();Write-TransportJson (Join-Path $root 'config.json') $c
    Assert ((Read-TransportSettings $root).Transport.hops.Count -eq 1) 'first daemon startup imports old channel'
    # More than one hop and non-SSH detours use the same graph parser.
    $multi=Copy-TransportObject $channel
    $multi.outbounds[2]|Add-Member detour 'second-hop'
    $second=Copy-TransportObject $multi.outbounds[2];$second.tag='second-hop';$second.PSObject.Properties.Remove('detour');$multi.outbounds+=@($second)
    Assert (@(Get-TransportLegacyChain $multi 'vless-hop').Count -eq 3) 'multi-hop chain'
    $multi.outbounds[2].type='socks'
    $t=[pscustomobject]@{};$issues=@(Import-TransportLegacyRoutes $t $multi $channelPath (Read-TransportJson $profile))
    Assert ($issues.Count -eq 0 -and $t.hops.Count -eq 1) 'mixed detour chain'
    $multi.outbounds[4].type='http'
    $t=[pscustomobject]@{};$issues=@(Import-TransportLegacyRoutes $t $multi $channelPath (Read-TransportJson $profile))
    Assert ($issues.Count -eq 0 -and $t.relays.Count -eq 1) 'non-SSH detours in relays'
    $multi.outbounds[2].detour='vless-hop'
    $issues=@(Import-TransportLegacyRoutes ([pscustomobject]@{}) $multi $channelPath)
    Assert ($issues.reason -contains 'legacy-cycle') 'cycle rejected explicitly'
    $multi.outbounds[2].detour='missing'
    Assert (@(Import-TransportLegacyRoutes ([pscustomobject]@{}) $multi $channelPath).reason -contains 'legacy-missing-or-duplicate') 'missing dependency rejected'
    $multi.outbounds[2].type='unknown-protocol'
    Write-TransportJson $channelPath $multi
    $failed=$false;try{$null=Import-MigrationConfig $root $disk}catch{$failed=$_.Exception.Message -like 'Старый канал*'}
    Assert $failed 'unsupported protocol blocks cutover'
    Assert (([IO.File]::ReadAllText((Join-Path $root 'logs/migration.log'))).Contains('legacy-unsupported-type')) 'unsupported reason in migration log'
    Assert ((Read-TransportJson $channelPath).outbounds[2].type -eq 'unknown-protocol') 'source channel untouched'
    $selector=Copy-TransportObject $channel;$selector.outbounds[3].outbounds=@('server')
    Assert (@(Import-TransportLegacyRoutes ([pscustomobject]@{}) $selector $channelPath).reason -contains 'legacy-selector-invalid') 'selector cycle rejected'
    # Per-candidate reasons and the same safe reason are persisted for the two launcher UIs.
    $probe=Join-Path $work 'probe'
    Write-TransportJson (Join-Path $probe 'status/transport.json') @{candidates=@(@{tag='test-hop';title='VLESS через SSH-переход';state='fail';diagnostic=@{candidate='test-hop';reason='connection-refused';exitCode=255;stderr='connect: Connection refused'}},@{tag='test-direct';title='SSH напрямую';state='fail';diagnostic=@{candidate='test-direct';reason='timeout';exitCode=$null;stderr=''}})}
    $message=Write-MigrationPreflightFailure $root $probe
    $log=[IO.File]::ReadAllText((Join-Path $root 'logs/migration.log'))
    Assert ($log.Contains('candidate=test-hop reason=connection-refused exit=255 stderr=connect: Connection refused') -and $log.Contains('candidate=test-direct reason=timeout')) 'migration log includes every candidate, code and stderr'
    Assert ($message.StartsWith('Нет рабочего пути к серверу:') -and $message.Contains('Прежний канал не остановлен')) 'clear preflight failure'
    Assert ((Read-TransportJson (Join-Path $root 'state/migration-error.json')).message -ceq $message) 'UI receives persisted safe reason'
    Write-Output ('OK: '+$count+' legacy migration checks (fixtures)')
}finally{$env:LOCALAPPDATA=$oldLocal;Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}
