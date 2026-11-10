#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'accounts/Account.ps1') -LibraryOnly
$root=Join-Path $TestHome 'RemoteAgents';[void][IO.Directory]::CreateDirectory((Join-Path $root 'secrets'))
[IO.File]::WriteAllText((Join-Path $root 'config.json'),'{"schema":1,"happier":{"serverUrl":"https://api.example.invalid","webappUrl":"https://web.example.invalid","label":"Мой аккаунт"}}')
$count=0
function Assert($ok,$name){if(-not $ok){throw ('FAIL '+$name)};$script:count++}
$script:testKey=[Convert]::ToBase64String([byte[]](1..32))
$keyFile=Join-Path $root 'secrets/happier-account.key';[IO.File]::WriteAllText($keyFile,$script:testKey+"`r`n")
$script:fail=$false;$script:calls=0
function Read-DiskProfile {$script:calls++}
function Invoke-DiskSsh($Command,[switch]$Direct,[string]$InputText,[int]$TimeoutSeconds){
    Assert (-not $Direct) 'account uses configured transport path'
    Assert (-not $Command.Contains($script:testKey)) 'secret absent from SSH argv'
    if($Command -eq 'bash -s'){Assert (-not $InputText.Contains($script:testKey)) 'public bootstrap contains no key';return ''}
    if($script:fail){throw 'fake SSH offline'}
    $request=$InputText|ConvertFrom-Json
    Assert ($request.key -ceq $script:testKey -and $request.serverUrl -eq 'https://api.example.invalid') 'key only in private stdin; CRLF normalized'
    '{"schema":1,"ok":true,"account":"'+('a'*64)+'","web":"https://web.example.invalid"}'+"`r`n"
}
Connect-HappierAccount $root
$state=[IO.File]::ReadAllText((Join-Path $root 'state/happier-account.json'))|ConvertFrom-Json
Assert ($state.ok -and $state.updatedUtc) 'public status requires server success'
$before=[IO.File]::ReadAllBytes($keyFile)
Connect-HappierAccount $root
Assert ($script:calls -eq 2 -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($keyFile)) -ceq [Convert]::ToBase64String($before)) 'repeated setup rereads profile and preserves recovery key'
$script:fail=$true;$failed=$false;try{Connect-HappierAccount $root}catch{$failed=$true}
Assert ($failed -and -not ([IO.File]::ReadAllText((Join-Path $root 'state/happier-account.json'))|ConvertFrom-Json).ok) 'SSH failure cannot reuse old success'
Assert (-not ([IO.File]::ReadAllText((Join-Path $root 'logs/accounts.log'))).Contains($script:testKey) -and -not ([IO.File]::ReadAllText((Join-Path $root 'state/happier-account.json'))).Contains($script:testKey)) 'logs and public state contain no secret'
Write-Output ('OK: '+$count+' account PowerShell checks (fake SSH; no live accounts)')
