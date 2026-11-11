#requires -Version 5.1
# Happier step with a detached server install: the window never waits for it, the key waits only
# in secrets and is applied automatically once the install finishes. Fake SSH; no live server.
param([string]$TestHome)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'build/Wizard.Common.ps1')
$count=0
function Assert($Value,[string]$Name){if(-not $Value){throw ('FAIL: '+$Name)};$script:count++}
function Throws([scriptblock]$Body,[string]$Name){$failed=$false;try{& $Body}catch{$failed=$true;$script:lastError=$_.Exception.Message};Assert $failed $Name}
$root=Join-Path $TestHome 'RemoteAgents';[void][IO.Directory]::CreateDirectory((Join-Path $root 'secrets'))
Write-TransportJson (Join-Path $root 'config.json') @{schema=1;version=1;components=@{}}
$script:WizardProgressFile=Join-Path $TestHome 'progress.jsonl'
$secret='ABCDE-FGHIJ-KLMNO-PQRST-UVWXY-Z2345-67ABC-DEFGH-IJKLM-NOPQR-ST'
$pendingKey=Join-Path $root 'secrets/happier-pending.key';$keyFile=Join-Path $root 'secrets/happier-account.key'
$script:op=@{state='running';step='Скачиваю';stage=2;stages=3;elapsedSec=130;exitCode=$null;reason=''};$script:installed=$false;$script:commands=@();$script:childFails=$false;$script:childKey=''
function Send-WizardHelpers($Root,$Bundle){}
function Invoke-WizardSsh($Root,$Command,$InputText='',$Timeout=60){
    Assert (-not $Command.Contains($secret) -and -not ([string]$InputText).Contains($secret)) 'key never in SSH argv or helper input'
    Assert ($Timeout -le 60) 'only short SSH calls from the window'
    $script:commands+=@($Command)
    $op=[pscustomobject]$script:op;$op|Add-Member -Force op 'happier'
    if($Command -match 'server-wizard.sh" ensure happier'){
        $ready=$script:installed -and $op.state -ne 'running'
        if(-not $ready -and $op.state -ne 'running'){$script:op.state='running';$op.state='running'}
        $op|Add-Member -Force ready $ready;return (ConvertTo-Json $op -Compress)+"`r`n"
    }
    if($Command -match '^bash -s -- status happier'){return (ConvertTo-Json @{happier=$op} -Compress -Depth 5)+"`r`n"}
    if($Command -match 'test -x'){return $(if($script:installed){"yes`r`n"}else{"no`r`n"})}
    throw ('Unexpected fake SSH command: '+$Command)
}
function Invoke-InstallChild($Bundle,$Script,$Arguments,$TimeoutSeconds){
    Assert ($Script -eq 'accounts/Account.ps1' -and $TimeoutSeconds -le 300) 'account child is short'
    $script:childKey=[IO.File]::ReadAllText($keyFile).Trim()
    if($script:childFails){throw 'Аккаунт не подтверждён'}
    Write-TransportJson (Join-Path $root 'state/happier-account.json') @{schema=1;ok=$true;account=('b'*64);label='Мой'}
}
$request=[pscustomobject]@{label='Мой';serverUrl='https://api.example.invalid';webappUrl='https://web.example.invalid';expectedAccount=''}
Throws {Invoke-WizardStep $root $repo 'Account' $request} 'no key at all is an explicit error'
[IO.File]::WriteAllText($pendingKey,$secret+"`n")
$result=Invoke-WizardStep $root $repo 'Account' $request
Assert (-not $result.ok -and $result.pending -eq 'happier') 'install running: section waits instead of blocking'
Assert ($result.summary.Contains('прошло 2 мин') -and $result.summary.Contains('этап 2 из 3: Скачиваю') -and $result.summary.Contains('применится автоматически')) 'elapsed time and step, no invented forecast'
Assert (@($script:commands|Where-Object {$_ -match 'ensure happier'}).Count -eq 1) 'explicit apply ensures the detached install'
Assert ((Test-Path $pendingKey) -and -not (Test-Path $keyFile)) 'entered key waits in secrets only'
$pendingText=[IO.File]::ReadAllText((Join-Path $root 'state/happier-pending.json'))
Assert (-not $pendingText.Contains($secret) -and $pendingText.Contains('web.example.invalid')) 'pending request is public'
$script:commands=@()
$result=Invoke-WizardStep $root $repo 'ResumeAccount' $null
Assert ($result.pending -eq 'happier' -and @($script:commands|Where-Object {$_ -match 'ensure|start'}).Count -eq 0) 'automatic resume only observes the install'
$status=Invoke-WizardStep $root $repo 'Operation' ([pscustomobject]@{operations=@('happier')})
Assert ($status.operations.happier.state -eq 'running' -and $status.operations.happier.text.Contains('Можно настраивать дальше') -and $status.pendingAccount) 'status polling reports running and pending account'
$script:op=@{state='failed';step='';elapsedSec=400;exitCode=6;reason='curl: (28) Connection timed out'}
Throws {Invoke-WizardStep $root $repo 'ResumeAccount' $null} 'failed install is reported, not retried automatically'
Assert ($script:lastError.Contains('Connection timed out') -and (Test-Path $pendingKey)) 'failure reason shown; key kept for retry'
$script:commands=@()
$result=Invoke-WizardStep $root $repo 'Account' $request
Assert ($result.pending -eq 'happier' -and $script:op.state -eq 'running') 'explicit apply retries a failed install'
$script:op=@{state='finished';step='';elapsedSec=150;exitCode=0;reason=''};$script:installed=$true
$result=Invoke-WizardStep $root $repo 'ResumeAccount' $null
Assert ($result.ok -and $result.webappUrl -eq 'https://web.example.invalid' -and $script:childKey -ceq $secret) 'finished install: pending key applied automatically'
Assert (-not (Test-Path $pendingKey) -and -not (Test-Path (Join-Path $root 'state/happier-pending.json')) -and [IO.File]::ReadAllText($keyFile).Trim() -ceq $secret) 'pending state cleared after success'
Assert ((Invoke-WizardStep $root $repo 'ResumeAccount' $null).idle) 'nothing pending: resume is a no-op'
# A rejected new key restores the working one and is kept as unconfirmed for recovery.
[IO.File]::WriteAllText($pendingKey,'ZZZZZ-other-key'+"`n");$script:childFails=$true
Throws {Invoke-WizardStep $root $repo 'Account' $request} 'rejected key fails the step'
Assert ([IO.File]::ReadAllText($keyFile).Trim() -ceq $secret -and -not (Test-Path $pendingKey) -and @(Get-ChildItem (Join-Path $root 'secrets') -Filter 'happier-unconfirmed-*.key').Count -eq 1) 'previous key restored, tried key kept'
$journal=@(Get-ChildItem $root -Recurse -File|Where-Object {$_.FullName -notmatch '[\\/]secrets[\\/]'})+@(Get-Item $script:WizardProgressFile)
foreach($file in $journal){Assert (-not ([IO.File]::ReadAllText($file.FullName)).Contains($secret)) ('no key outside secrets: '+$file.Name)}
Assert (-not ((ConvertTo-Json $result -Depth 10)).Contains($secret)) 'step output has no key'
Write-Output ('OK: '+$count+' Happier pending/detached checks (fake SSH; no live server)')
