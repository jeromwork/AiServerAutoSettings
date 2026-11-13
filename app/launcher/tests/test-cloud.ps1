#requires -Version 5.1
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'build/Wizard.Common.ps1')
$count=0
function Assert($ok,$why){if(-not $ok){throw $why};$script:count++}
$directory=Join-Path ([IO.Path]::GetTempPath()) ('cloud-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
try {
    $fake=Join-Path $directory 'fake-ssh'
    $script=@'
#!/usr/bin/env python3
import sys,json
assert sys.argv[-1]=='bash "$HOME/.local/share/remoteagents-cloud/server-cloud.sh" apply'
assert not any('fake-cloud-password' in x for x in sys.argv)
data=sys.stdin.buffer.read()
assert b'\r' not in data
r=json.loads(data)
assert r['password']=='fake-cloud-password'
assert r['localRoot']=='~/Disk'
if r['login']=='bad':
 print('Первая причина fake-cloud-password\r\nВторая причина',file=sys.stderr)
 sys.exit(5)
sys.stdout.buffer.write(b'{\r\n"ok":true\r\n}\r\n')
'@
    Write-DiskUtf8 $fake $script
    & chmod +x $fake
    $script:profile=[pscustomobject]@{sshExecutable=$fake;arguments=@()}
    function Find-InstallProfile($Root){return (Join-Path $directory 'profile.json')}
    Write-TransportJson (Find-InstallProfile $directory) $script:profile
    function Get-TransportSavedRouteOptions($Root,$Profile){return @()}
    $script:payload=@{vendor='mailru';login='user@mail.ru';password='fake-cloud-password';remoteRoot='Disk';localRoot='~/Disk';pollSeconds=20}|ConvertTo-Json -Compress
    function Read-WizardRelay($Name){return $script:payload}
    $result=Invoke-WizardCloud $directory ([pscustomobject]@{secretPipe='fixture'})
    Assert ($result.exitCode -eq 0 -and $result.stdout -eq '{"ok":true}') 'real fake SSH receives stdin JSON, no credential in argv, CRLF response accepted'
    $script:payload=$script:payload.Replace('user@mail.ru','bad')
    $result=Invoke-WizardCloud $directory ([pscustomobject]@{secretPipe='fixture'})
    Assert ($result.exitCode -eq 5 -and $result.stderr -eq 'Первая причина <secret>') 'nonzero result returns only first scrubbed stderr line'
    Assert (-not ($result|ConvertTo-Json -Compress).Contains('fake-cloud-password')) 'no echoed secret crosses local result boundary'
    function Invoke-WizardCloudProcess($Profile,$Options,$Command,$InputText){return @{exitCode=0;stdout='garbage';stderr=''}}
    $result=Invoke-WizardCloud $directory ([pscustomobject]@{secretPipe='fixture'})
    Assert ($result.stdout -eq '{"ok":false}') 'exit zero with invalid JSON is not success'
    function Invoke-WizardCloudProcess($Profile,$Options,$Command,$InputText){return @{exitCode=0;stdout='{"ok":"true"}';stderr=''}}
    $result=Invoke-WizardCloud $directory ([pscustomobject]@{secretPipe='fixture'})
    Assert ($result.stdout -eq '{"ok":false}') 'string true is not a boolean confirmation'
    Assert ((@(Get-WizardResources 'Cloud' ([pscustomobject]@{}))) -join ',' -eq 'cloud') 'cloud has its own resource lock'
    Write-Output ('PASS: '+$count+' cloud PowerShell/SSH-stdin checks (Linux fake SSH; not Windows PowerShell 5.1)')
} finally {Remove-Item -LiteralPath $directory -Recurse -Force}
