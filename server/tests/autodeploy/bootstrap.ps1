# The production password login + bootstrap helper, on a disposable clean VPS.
param([string]$Address,[string]$Key,[string]$Known,[string]$Config,[string]$Askpass,[string]$Bundle)
$ErrorActionPreference='Stop'
. (Join-Path $Bundle 'build/Wizard.Common.ps1')
$p=[pscustomobject]@{sshExecutable='/usr/bin/ssh';serverAddress=$Address;keyPath=$Key;knownHostsPath=$Known;configPath=$Config;strictHostKey=$true}
$credential=[pscustomobject]@{askpassExecutable=$Askpass;passwordPipe='synthetic-fixture'}
$pub=(Get-Content -Raw ($Key+'.pub')).Trim()
$privateProxy=[Console]::In.ReadToEnd().Trim()
$helper=Get-WizardBootstrapScript $Bundle $privateProxy
$body='remoteagents'+"`r`n"+$pub+"`r`n"+$helper
$command='IFS= read -r ra_user; IFS= read -r ra_key; export ra_user ra_key; bash -s'
[void](Invoke-WizardLogin $p 'root' $command $body $credential -Timeout 600)
[void](Invoke-WizardLogin $p 'remoteagents' 'true')
'bootstrap-ready'
