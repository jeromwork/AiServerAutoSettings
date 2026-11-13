#requires -Version 5.1
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'build/Wizard.Common.ps1')
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('disk-errors-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tmp)
$previousLocal=$env:LOCALAPPDATA;$env:LOCALAPPDATA=Join-Path $tmp 'local'
$count=0
function Assert($Value,$Text){if(-not $Value){throw $Text};$script:count++}
try{
    $script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk';[void][IO.Directory]::CreateDirectory($script:DiskHome)
    $reason='AddTest: Чужой .stignore: сохраните и удалите его вручную перед подключением'
    # A real SSH-shaped process emits UTF-8/CRLF. Never contact a live server.
    $ssh=Join-Path $tmp 'ssh'
    if($env:OS -eq 'Windows_NT'){
        # A cmd wrapper cannot be run with UseShellExecute=false. The parser/child tests below run on Windows too.
        $ssh=$null
    }else{
        Write-DiskUtf8 $ssh ("#!/bin/sh`nprintf '%s\r\n' '"+$reason+"' 'later diagnostic' >&2`nexit 1`n")
        & chmod +x $ssh
        $failure='';try{Invoke-DiskProcess $ssh @()}catch{$native=$_;$failure=$_.Exception.Message}
        Assert ($failure.StartsWith($reason) -and -not $failure.Contains('later diagnostic')) 'Native stderr preserves the first Russian server cause and folder'
        Write-DiskLog 'Тест причины' $native
        Assert ([IO.File]::ReadAllText((Join-Path $script:DiskHome 'install.log')).Contains($reason)) 'Disk journal retains the server cause'
        $profile=Join-Path $tmp 'profile.json'
        Write-TransportJson $profile @{sshExecutable=$ssh;arguments=@('fixture');serverAddress='server.invalid';login='worker';keyPath='unused';knownHostsPath='unused';configPath='unused'}
        $failure='';try{Invoke-InstallChild $repo 'disk/Install-RemoteDisk.ps1' @('-Profile',$profile)}catch{$failure=$_.Exception.Message}
        Assert ($failure.Contains($reason) -and -not $failure.Contains('Проверьте SSH')) ('Actual Install -> child -> window reason retains folder and never suggests SSH for a policy refusal: '+$failure)
    }
    $child=Join-Path $tmp 'failure.ps1'
    $body=@'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
[Console]::Out.WriteLine(('progress '*600))
[Console]::Error.WriteLine('AddTest: Чужой .stignore: сохраните и удалите его вручную перед подключением')
1..600|ForEach-Object {[Console]::Error.WriteLine(('diagnostic '+$_))}
[Console]::Error.WriteLine('да не выполнена (код выхода 1)')
exit 1
'@
    [IO.File]::WriteAllText($child,$body.Replace("`r",'').Replace("`n","`r`n"),(New-Object Text.UTF8Encoding($true)))
    $failure='';try{Invoke-InstallChild $tmp 'failure.ps1' @()}catch{$failure=$_.Exception.Message}
    Assert ($failure.Contains($reason) -and -not $failure.Contains('да не выполнена') -and -not $failure.Contains('progress')) 'First stderr line wins over progress stdout and the truncated tail'
    $json=@{ok=$false;reason=(Protect-DiskFailureText $failure);remedy=(Get-InstallFailureRemedy $failure)}|ConvertTo-Json -Compress
    $window=$json|ConvertFrom-Json
    Assert ($window.reason.Contains($reason) -and $window.remedy -eq '') 'Machine-readable window response keeps the cause without a generic SSH remedy'
    $longName='VeryLongProjectNameWithMoreThanTwentyLetters'
    $protected=Protect-DiskFailureText ('Шаг установки не выполнен (код 1): '+$longName+': Чужой .stignore: token '+('A'*40))
    Assert ($protected.Contains($longName+': Чужой .stignore') -and -not $protected.Contains(('A'*40))) 'Long project name survives masking while tokens stay private'
    Assert ((Get-InstallFailureRemedy 'Шаг установки не выполнен (код 1)').Contains('Проверьте SSH')) 'Unknown failure still has actionable generic advice'
    Write-Output ('OK: '+$count+' stderr -> Disk log / Install / wizard / window checks (UTF-8, CRLF, long output; no live SSH)')
}finally{$env:LOCALAPPDATA=$previousLocal;Remove-Item -LiteralPath $tmp -Recurse -Force}
