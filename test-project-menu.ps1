$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'setup-vps-ssh.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Parser failed'}
foreach($name in @('Connect-ProjectFolders','Start-RemoteCodex','Select-ExecutionMode')){
 $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 . ([scriptblock]::Create($node.Extent.Text.Replace('$PSScriptRoot',("'"+$PSScriptRoot.Replace("'","''")+"'"))))
}
function Assert($Value,$Message){if(-not $Value){throw $Message}}
$fixture=Join-Path $PSScriptRoot ('project menu fixture '+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture)|Out-Null
try{
 $script:projects=@(
 [pscustomobject]@{projectId='p-one';hostId='computer';sourcePath='C:\public source one';replicaPath=(Join-Path $fixture 'replica one')},
 [pscustomobject]@{projectId='p-two';hostId='computer';sourcePath='C:\public source two';replicaPath=(Join-Path $fixture 'replica two')})
 function Initialize-ProjectModule {}
 function Get-ProjectClientContext {[pscustomobject]@{ClientId='computer';DataDir=$fixture}}
 function Get-RemoteSyncProjects {param($DataDir);$script:projects}
 function Add-ProjectFolder {param($Context);[pscustomobject]@{cancelled=$script:cancelSelection}}
 $script:cancelSelection=$false;$script:selectedIds=@('p-one','p-two')
 function Get-RemoteSyncSelection {param($DataDir,$HostId);[pscustomobject]@{projects=@($script:projects|ForEach-Object{[pscustomobject]@{projectId=$_.projectId;selected=($_.projectId -in $script:selectedIds)}})}}
 function Save-ProfileMetadata {}
 function Read-Host {param($Question);''}
 function Confirm-Action {return $false}
 $script:started=0;$script:bridges=0;$script:stops=0;$script:notReady=$false
 function Start-ManagedComponent {param($File,$Parameters,$ReadyState)
  $script:started++;$id=$Parameters[$Parameters.IndexOf('-ProjectId')+1]
  $project=$script:projects|Where-Object projectId -eq $id
  $r=@{ready=(-not $script:notReady);fresh=(-not $script:notReady);projectId=$id;hostId='computer';replicaPath=$project.replicaPath;snapshotId='fixture'}|ConvertTo-Json -Compress
  [pscustomobject]@{State='project-ready';Output=[pscustomobject]@{ReadyLine=$r}}
 }
 function Get-ManagedComponentState {param($Component);$Component.State}
 function Stop-ManagedComponent {param($Component);if($Component){$script:stops++}}
 function Start-ProjectWindowsBridge {param($ProjectId,$ClientId,$ReplicaPath,$AllowShell,$SyncDataDir,$Agents)
  Assert (-not $AllowShell -and $SyncDataDir -eq $fixture -and $ReplicaPath -like '*replica*') 'Bridge scope/default permission failed'
  $script:lastBridgeAgents=$Agents
  $script:bridges++;[pscustomobject]@{State='connected'}
 }
 $common=@('-F','public config');$keyPath='public key path';$ServerAddress='example.com';$Login='root';$knownHostsPath='public known hosts';$configPath='public config';$script:sshExecutable='not executed';$script:askpassExecutable='not executed'
 $sessions=@{}
 Connect-ProjectFolders '1' $sessions
 Assert ($sessions.Count -eq 2 -and $script:bridges -eq 2 -and $script:started -eq 2 -and $script:stops -eq 0) 'Multiple ready bindings failed'
 Connect-ProjectFolders '1' $sessions
 Assert ($script:bridges -eq 2 -and $script:started -eq 2) 'Reconnect duplicated active sessions'
 $script:cancelSelection=$true
 Connect-ProjectFolders '1' $sessions
 Assert ($script:bridges -eq 2 -and $script:started -eq 2 -and $sessions.Count -eq 2) 'Cancel started transfer or changed active sessions'
 $script:cancelSelection=$false
 $script:notReady=$true;$sessions=@{};$before=$script:bridges
 Connect-ProjectFolders '1' $sessions
 Assert ($sessions.Count -eq 0 -and $script:bridges -eq $before -and $script:stops -eq 2) 'Not-ready sync reached bridge'
 $script:notReady=$false;$sessions=@{}
 Connect-ProjectFolders '2' $sessions
 Assert ($sessions.Count -eq 2 -and $script:bridges -eq ($before+2) -and $script:lastBridgeAgents -eq '2') 'Claude bridge selection was not forwarded'
 $script:selectedIds=@('p-one');$startsBefore=$script:started;$stopsBefore=$script:stops
 Connect-ProjectFolders '2' $sessions
 Assert ($sessions.Count -eq 1 -and $sessions.ContainsKey('p-one') -and $script:started -eq $startsBefore -and $script:stops -eq ($stopsBefore+2)) 'Unchecked project was not disabled cleanly'
 # The app loop owns GUI bridge lifetime, including while the optional CLI opens/exits.
 $script:stops=0;$script:steps=New-Object 'Collections.Generic.Queue[string]'
 foreach($step in @('1','2','0')){$script:steps.Enqueue($step)}
 function Install-AgentApplications {param($Choice)}
 function Select-ExecutionMode {return $script:mode}
 function Connect-ProjectFolders {param($Agents,$Sessions);$Sessions['fixture']=[pscustomobject]@{Sync=[pscustomobject]@{State='project-ready'};Bridge=[pscustomobject]@{State='connected'}};$script:connected++}
 function Open-ServerDesktop {Assert ($script:stops -eq 0) 'Bridge stopped before GUI'}
 function Start-CodexTerminal {param([switch]$ServerTerminalOnly);Assert ([bool]$ServerTerminalOnly) 'Optional CLI bypassed project replica flow';Assert ($script:stops -eq 0) 'CLI exit owned GUI bridge'}
 function Read-Host {param($Question);if($Question -like 'Выберите 1*'){return '1'};if($Question -like 'Что открыть?*'){return $script:steps.Dequeue()};throw 'Unexpected prompt'}
 $metadata=[pscustomobject]@{agentApplications='1'};$metadataPath='unused';$script:mode='1';$script:connected=0
 Start-RemoteCodex
 Assert ($script:connected -eq 1 -and $script:stops -eq 2) 'App menu did not own persistent connections'
 $script:mode='2';$script:steps.Enqueue('0');Start-RemoteCodex
 Assert ($script:connected -eq 1) 'VPS-only mode connected Windows'
 'PASS: PS5.1 multiple bindings/reuse, pending denial, Claude scoped bridge, GUI+CLI persistent lifetime, VPS-only isolation. No project content, SSH or keys read.'
}finally{
 if([IO.Path]::GetDirectoryName($fixture) -eq $PSScriptRoot){Remove-Item -LiteralPath $fixture -Recurse -Force}
}
