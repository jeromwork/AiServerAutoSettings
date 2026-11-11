#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'build/Wizard.Common.ps1')
[void][IO.Directory]::CreateDirectory($TestHome)
$count=0
function Assert($Value,[string]$Name){if(-not $Value){throw ('FAIL: '+$Name)};$script:count++}
function Throws([scriptblock]$Body,[string]$Name){$failed=$false;try{& $Body}catch{$failed=$true};Assert $failed $Name}
$empty=[pscustomobject]@{ssh=$false;disk=$false;happier=$false;bridge=$false;catalog=$false}
$ready=[pscustomobject]@{ssh=$true;disk=$true;happier=$true;bridge=$true;catalog=$true}
$clean=[pscustomobject]@{transport=$false;disk=$false;account=$false;bridgeEnabled=$false;vpnEnabled=$false}
$local=[pscustomobject]@{transport=$true;disk=$true;account=$true;bridgeEnabled=$true;bridge=$true;vpnEnabled=$false}
$p=@(Get-WizardPlan $empty $clean)
Assert ($p.Count -eq 6 -and -not $p[0].ready -and $p[0].repair -and -not $p[2].ready) 'clean PC, empty server: nothing falsely ready'
Assert ($p[4].ready -and $p[5].ready) 'bridge and VPN explicitly disabled'
$p=@(Get-WizardPlan $ready $clean)
Assert ($p[0].ready -and -not $p[0].repair -and -not $p[2].ready -and -not $p[3].ready) 'clean PC, configured server: reuse server, configure local components'
$p=@(Get-WizardPlan $ready $local)
Assert (@($p|Where-Object {-not $_.ready}).Count -eq 0) 'repeat run observes healthy state'
$broken=Copy-TransportObject $ready;$broken.disk=$false
$p=@(Get-WizardPlan $broken $local)
Assert ($p[0].repair -and -not $p[2].ready -and $p[3].ready) 'partially broken server isolates disk repair'
$local.bridge=$false;$p=@(Get-WizardPlan $ready $local)
Assert (-not $p[4].ready -and $p[3].ready) 'dead bridge is never ready from a marker'
# Public catalogs use existing transport schema. Both SSH input and server output include CRLF.
$server=ConvertFrom-Json ('{"schema":1,"entries":[],"hops":[],"relays":[{"name":"my-node","host":"relay.example.invalid","port":443,"enabled":true}],"cdn":[]}'+"`r`n")
$overlay=ConvertFrom-Json '{"schema":1,"entries":[],"hops":[],"relays":[{"name":"my-node","host":"relay.example.invalid","port":443,"enabled":false}],"cdn":[]}'
$merged=Merge-WizardCatalog $server $overlay
Assert (@($merged.relays).Count -eq 1 -and -not $merged.relays[0].enabled) 'local disabled override preserves server node'
Assert ($server.relays[0].enabled) 'local edits do not mutate server catalog'
$private=Copy-TransportObject $server;$private.relays[0]|Add-Member password 'never-share'
Throws {Assert-WizardCatalog $private} 'catalog rejects secrets'
$private=Copy-TransportObject $server;$private.relays[0]|Add-Member configPath 'C:\private'
Throws {Assert-WizardCatalog $private} 'catalog rejects computer paths'
$bad=Copy-TransportObject $server;$bad.schema=9
Throws {Assert-WizardCatalog $bad} 'unknown catalog version rejected'
# Exercise production catalog/inspection through a fake SSH boundary, not a UI copy of the model.
$root=Join-Path $TestHome 'home';[void][IO.Directory]::CreateDirectory($root)
Write-TransportJson (Join-Path $root 'config.json') @{schema=1;version=1;components=@{};transport=@{}}
$script:calls=0;$script:offline=$false
function Invoke-WizardSsh($Root,$Command,$InputText='',$Timeout=60){
    $script:calls++
    Assert (-not $InputText.Contains("`r")) 'cross-system payload is LF'
    if($script:offline){throw 'Нет связи с сервером'}
    if($Command -eq 'python3 -'){return (ConvertTo-Json -InputObject $server -Depth 30)+"`r`n"}
    if($Command -eq 'bash -s'){return '{"schema":1,"disk":true,"happier":true,"bridge":true,"catalog":true,"userManager":true}'+"`r`n"}
    throw 'Unexpected fake SSH command'
}
$c=Get-WizardCatalog $root $repo
Assert ($c.schema -eq 1 -and $c.relays[0].name -eq 'my-node') 'catalog fetched automatically from server (fake SSH, CRLF)'
$s=Get-WizardServer $root $repo
Assert ($s.ssh -and $s.disk) 'server readiness comes from inspection output'
$script:offline=$true
Throws {Get-WizardServer $root $repo} 'saved success cannot hide SSH failure'
$script:offline=$false
# File union: identical path means presence, never assumed equal bytes.
$base=Join-Path $TestHome 'Disk';[void][IO.Directory]::CreateDirectory((Join-Path $base 'Project/empty'))
[IO.File]::WriteAllText((Join-Path $base 'Project/both.txt'),'local version')
[IO.File]::WriteAllText((Join-Path $base 'Project/local.txt'),'preserve me')
[IO.File]::WriteAllText((Join-Path $base 'loose.txt'),'root local file')
[IO.File]::WriteAllText((Join-Path $base 'Project/.env'),'never enumerate')
[void][IO.Directory]::CreateDirectory((Join-Path $base 'LocalOnly'))
$tree=ConvertFrom-Json ('{"folders":[{"name":"Project"},{"name":"ServerOnly"}],"entries":[{"path":"Project/both.txt","directory":false},{"path":"Project/remote.txt","directory":false}]}'+"`r`n")
$rootTree=ConvertFrom-Json ('{"folders":[{"name":"Project","hasChildren":true},{"name":"ServerOnly","hasChildren":false}],"entries":[]}'+"`r`n")
$rootUnion=Get-DiskUnion $rootTree $base
Assert (@($rootUnion.rows|Where-Object {$_.path -match '/'}).Count -eq 0) 'initial inventory is root only'
Assert (@($rootUnion.rows|Where-Object {$_.path -ceq 'Project' -and $_.hasChildren -and $_.presence -eq 'both'}).Count -eq 1) 'root union has lazy child flag'
$tree.folders=@()
$union=Get-DiskUnion $tree $base 'Project'
Assert (@($union.rows|Where-Object {$_.path -ceq 'Project/both.txt' -and $_.presence -eq 'both'}).Count -eq 1) 'both marker'
Assert (@($union.rows|Where-Object {$_.path -ceq 'Project/local.txt' -and $_.presence -eq 'local'}).Count -eq 1) 'local-only marker'
Assert (@($union.rows|Where-Object {$_.path -ceq 'Project/remote.txt' -and $_.presence -eq 'server'}).Count -eq 1) 'server-only marker'
Assert (@($rootUnion.rows|Where-Object {$_.path -ceq 'LocalOnly' -and $_.presence -eq 'local'}).Count -eq 1) 'local-only project included'
Assert (@($rootUnion.rows|Where-Object {$_.path -ceq 'ServerOnly' -and $_.presence -eq 'server'}).Count -eq 1) 'server-only project included'
Assert (@($union.rows|Where-Object {$_.path -ceq 'Project/empty' -and $_.kind -eq 'directory'}).Count -eq 1) 'empty local directory included'
Assert (@($union.rows|Where-Object {$_.path -like '*.env*'}).Count -eq 0) 'secrets excluded from union'
Assert (@($rootUnion.rows|Where-Object {$_.path -ceq 'loose.txt' -and $_.presence -eq 'local' -and $_.kind -eq 'file'}).Count -eq 1) 'loose root files are visible and never silently omitted'
Assert ([IO.File]::ReadAllText((Join-Path $base 'Project/local.txt')) -ceq 'preserve me') 'tree does not modify local files'
$collision=Copy-TransportObject $tree;$collision.entries[0].path='Project/BOTH.txt'
Throws {Get-DiskUnion $collision $base 'Project'} 'case collision fails before syncing to Windows'
$collision=Copy-TransportObject $tree;$collision.entries[0].directory=$true
Throws {Get-DiskUnion $collision $base 'Project'} 'file-directory conflict remains intact'
function Initialize-WizardTransport($Root,$Bundle,$Transport){}
function Invoke-MigrationPreflight($Root,$Bundle,$Config){}
# First setup connection persists public settings; it does not replace H's old channel refs.
function Test-MigrationFresh($Root,$Name){$false}
$config=Read-TransportJson (Join-Path $root 'config.json');$config.transport|Add-Member hops @([pscustomobject]@{name='old';legacyOutbound='via-hop';legacyChannelPath='local-only.json';enabled=$true});Write-TransportJson (Join-Path $root 'config.json') $config
[void](Invoke-WizardStep $root $repo 'Connection' ([pscustomobject]@{catalog=$merged;shared=$false}))
$config=Read-TransportJson (Join-Path $root 'config.json')
Assert ($config.transport.hops[0].legacyOutbound -eq 'via-hop') 'legacy H references preserved locally'
Assert (-not $config.transport.relays[0].enabled) 'new local catalog is applied by shared step dispatcher'
Assert ($config.wizard.localCatalog.relays[0].name -eq 'my-node') 'local overlay survives next refresh'
$before=[IO.File]::ReadAllText((Join-Path $root 'config.json'))
$script:offline=$true
Throws {Invoke-WizardStep $root $repo 'Connection' ([pscustomobject]@{catalog=$merged;shared=$false})} 'offline catalog prevents partial connection edit'
Assert ([IO.File]::ReadAllText((Join-Path $root 'config.json')) -ceq $before) 'failed catalog fetch preserves working settings'
$script:offline=$false
Throws {Invoke-WizardStep $root $repo 'Connection' ([pscustomobject]@{catalog=$server;shared=$true;expected=$server})} 'failed shared publication cannot proceed to local route edit'
Assert ([IO.File]::ReadAllText((Join-Path $root 'config.json')) -ceq $before) 'CAS/SSH publication failure leaves local configuration unchanged'
# Exact shared transaction rollback restores transport only; unrelated changes survive.
$receipt=Join-Path $root 'state/wizard-network.json'
Write-TransportJson $receipt @{schema=1;session='fixture';task='fixture-only';previous=@{marker='original'}}
function Unregister-ScheduledTask($TaskName,[switch]$Confirm,$ErrorAction){}
Undo-WizardNetwork $root 'different-session'
Assert (Test-Path $receipt) 'stale rollback session cannot restore newer edit'
Undo-WizardNetwork $root 'fixture'
$config=Read-TransportJson (Join-Path $root 'config.json')
Assert ($config.transport.marker -eq 'original' -and $config.wizard.localCatalog.relays[0].name -eq 'my-node') 'rollback restores network and keeps unrelated settings'
Assert (-not (Test-Path $receipt)) 'rollback is idempotent and clears receipt'
Undo-WizardNetwork $root 'fixture'
function Test-MigrationFresh($Root,$Name){$Name -in @('transport','disk')}
function Test-MigrationSsh($Root,$Port){$true}
$config=Read-TransportJson (Join-Path $root 'config.json');$config|Add-Member -Force bridge ([pscustomobject]@{enabled=$false;allowShell=$false});Write-TransportJson (Join-Path $root 'config.json') $config
Write-TransportJson (Join-Path $root 'status/disk.json') @{connected=$true}
Assert (Test-MigrationHealth $root) 'explicitly disabled bridge does not block real migration health requirements'
$config.bridge.enabled=$true;Write-TransportJson (Join-Path $root 'config.json') $config
Assert (-not (Test-MigrationHealth $root)) 'enabled bridge needs fresh evidence'
$mark=[DateTime]::UtcNow.AddSeconds(-2)
Write-TransportJson (Join-Path $root 'status/transport.json') @{ok=$true;configRevision='previous-configuration'}
Assert (-not (Test-WizardNetworkProof $root $mark)) 'old configuration heartbeat cannot commit settings'
Write-TransportJson (Join-Path $root 'status/transport.json') @{ok=$true;configRevision=(Get-TransportRevision $root)}
Assert (Test-WizardNetworkProof $root $mark) 'matching revision and real SSH proof required'
Assert (-not (Test-WizardNetworkProof $root ([DateTime]::UtcNow.AddMinutes(1)))) 'old status timestamp cannot commit settings'
. (Join-Path $repo 'Start-WindowsControl.ps1') -LibraryOnly -LauncherHome $root
Assert (-not (Get-ControlAllowShell)) 'executor permission reads disabled shell from shared user config'
$config.bridge.allowShell=$true;Write-TransportJson (Join-Path $root 'config.json') $config
Assert (Get-ControlAllowShell) 'executor permission reads enabled shell from shared user config'
$child=Join-Path $TestHome 'child.ps1'
[IO.File]::WriteAllText($child,'[Console]::WriteLine("child-output-must-stay-private");[Console]::Error.WriteLine("child-stderr-must-stay-private");exit 0')
$output=@(Invoke-InstallChild $TestHome 'child.ps1' @())
Assert ($output.Count -eq 0) 'real child stdout/stderr cannot contaminate wizard JSON'
[IO.File]::WriteAllText($child,'[Console]::Error.WriteLine("private-fixture-marker");exit 7')
$errorText='';try{Invoke-InstallChild $TestHome 'child.ps1' @()}catch{$errorText=$_.Exception.Message}
Assert ($errorText -and -not $errorText.Contains('private-fixture-marker')) 'real child error is generic and contains no stderr'
# Stale health on a managed installation must not bypass network preflight.
function Test-MigrationFresh($Root,$Name){$false}
Write-TransportJson (Get-MigrationStatePath $root) @{phase='accepted'}
Assert (Test-WizardNetworkManaged $root) 'accepted installation keeps network safety when heartbeat is stale'
$script:networkPreflight=0
function Set-WizardNetwork($Root,$Bundle,$Transport){$script:networkPreflight++;throw 'preflight refused'}
Throws {Invoke-WizardStep $root $repo 'Connection' ([pscustomobject]@{catalog=$server;shared=$false})} 'stale installed network still runs preflight and rejects bad candidate'
Assert ($script:networkPreflight -eq 1) 'network transaction chosen without healthy heartbeat'
$pidFolder=Join-Path $root 'managed-control';[void][IO.Directory]::CreateDirectory($pidFolder)
[IO.File]::WriteAllText((Join-Path $pidFolder 'control.pid'),'12345')
function Get-CimInstance($ClassName,$Filter,$ErrorAction){[pscustomobject]@{CommandLine='powershell -File Start-WindowsControl.ps1 -Profile manual-fixture'}}
Assert ((Get-WizardBridgeCommand $root '') -eq 'powershell -File Start-WindowsControl.ps1 -Profile manual-fixture') 'manual bridge without Run has a recovery launch command'
Remove-Item -LiteralPath (Join-Path $pidFolder 'control.pid')
# Failure during bridge replacement restores config, Run and the old launch command.
$config=Read-TransportJson (Join-Path $root 'config.json')
$config|Add-Member -Force bridge ([pscustomobject]@{enabled=$true;allowShell=$true})
$config.components|Add-Member -Force control ([pscustomobject]@{enabled=$true;custom='retain'})
Write-TransportJson (Join-Path $root 'config.json') $config
$script:armed=$false;$script:restoredRun='';$script:restarted='';$script:stopped=0;$script:installCalls=0
function Get-MigrationRun($Name){'previous bridge command'}
function Set-MigrationRun($Name,$Value){$script:restoredRun=$Value}
function Start-MigrationRun($Command){$script:restarted=$Command}
function Stop-MigrationControl($Root){$script:stopped++}
function Test-WizardBridge($Root){$false}
function Register-WizardRollback($Root,$Bundle,$Kind,$Session,$Task){$script:armed=$true;Assert ($Kind -eq 'Bridge' -and (Test-Path (Join-Path $Root 'state/wizard-bridge.json'))) 'bridge snapshot precedes independent rollback registration'}
function Invoke-InstallChild($Bundle,$Script,$Arguments){Assert $script:armed 'bridge cannot stop before rollback is armed';$script:installCalls++;throw 'install failed'}
Throws {Invoke-WizardStep $root $repo 'Bridge' ([pscustomobject]@{enabled=$true;shell=$false})} 'failed bridge install is rejected'
$config=Read-TransportJson (Join-Path $root 'config.json')
Assert ($config.bridge.allowShell -and $config.components.control.custom -eq 'retain' -and $config.components.control.enabled) 'failed bridge change restores old permissions and component intent'
Assert ($script:restoredRun -eq 'previous bridge command' -and $script:restarted -eq 'previous bridge command' -and $script:stopped -eq 1) 'rollback restarts exact previous bridge command'
Assert (-not (Test-Path (Join-Path $root 'state/wizard-bridge.json'))) 'completed bridge rollback is idempotent'
$script:armed=$false;$script:installCalls=0
function Register-WizardRollback($Root,$Bundle,$Kind,$Session,$Task){throw 'scheduler refused'}
Throws {Invoke-WizardStep $root $repo 'Bridge' ([pscustomobject]@{enabled=$false;shell=$false})} 'rollback registration failure blocks bridge mutation'
Assert ($script:installCalls -eq 0 -and (Read-TransportJson (Join-Path $root 'config.json')).bridge.enabled -and -not (Test-Path (Join-Path $root 'state/wizard-bridge.json'))) 'scheduler failure leaves working bridge untouched and allows retry'
Write-Output ('OK: '+$count+' wizard/model/catalog/union/rollback checks (fake SSH, no Windows)')
