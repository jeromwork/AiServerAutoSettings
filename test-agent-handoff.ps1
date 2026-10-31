$ErrorActionPreference='Stop'
function Assert($Value,$Message){if(-not $Value){throw $Message}}
$files=@('Agent.Handoff.ps1','Get-CodexWindowsBridgeRegistration.ps1','setup-vps-ssh.ps1','windows-bridge-executor.ps1')
foreach($name in $files){
 $tokens=$null;$errors=$null
 [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name),[ref]$tokens,[ref]$errors)
 Assert ($errors.Count -eq 0) ('PS5.1 parse: '+$name)
}
. (Join-Path $PSScriptRoot 'Agent.Handoff.ps1')
$oldPath=$env:PATH
try{
 $env:PATH=$env:SystemRoot+'\System32;'+$env:SystemRoot+'\System32\WindowsPowerShell\v1.0'
 Assert (-not (Get-Command codex,claude,python -ErrorAction SilentlyContinue)) 'Fixture PATH contains a local agent/runtime'
 foreach($agents in @('1','2','3')){
  $label='win-'+('a'*28)
  $value=New-RemoteAgentHandoff -ProjectId 'p-fixture' -HostId 'fixture-host' -DeviceLabel $label -ReplicaPath 'C:\public fixture\replica' -Agents $agents -AllowShell $true
  Assert ($value.RemoteScript -match 'runuser -u remoteagents' -and $value.RemoteScript -match '--prepare-b64') 'App-user prepare missing'
  Assert ($value.SmokeScript -match '--smoke' -and $value.HandoffPath -match '/p-fixture/fixture-host/handoff.json$') 'Bound smoke missing'
  $encoded=[regex]::Match($value.RemoteScript,"--prepare-b64 '([^']+)'" ).Groups[1].Value
  $metadata=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))|ConvertFrom-Json
  Assert ($metadata.agents -eq $agents -and $metadata.hostId -eq 'fixture-host' -and $metadata.allowShell) 'Public metadata lost'
  $reg=& (Join-Path $PSScriptRoot 'Get-CodexWindowsBridgeRegistration.ps1') -DeviceLabel $label -ProjectId 'p-fixture' -Agents $agents
  Assert ($reg.RemoteScript -match "if \[ '$agents' = 1 \]" -and $reg.RemoteScript -match '--scope local') 'Scoped registration absent'
  Assert ($reg.RemoteScript -notmatch 'dangerously|skip-permissions|auth\.json|credentials') 'Unsafe registration generated'
 }
 'PASS: PS5.1 parsing and all-agent public bootstrap generation with no local Codex/Claude/Python in PATH. No SSH or credentials used.'
}finally{$env:PATH=$oldPath}
