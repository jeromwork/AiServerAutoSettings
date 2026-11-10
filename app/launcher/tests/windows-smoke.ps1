#requires -Version 5.1
# Test fixtures only: this script does not install autorun or use a server.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Exe,[string]$TestRoot=(Join-Path $env:TEMP ('RemoteAgents-smoke-'+[guid]::NewGuid().ToString('N'))))
$ErrorActionPreference='Stop'
$Exe=[IO.Path]::GetFullPath($Exe)
# Home has an independent mutex/pipe; the working launcher may remain running.
$LauncherHome=Join-Path $TestRoot 'home';$bundle=Join-Path $LauncherHome 'bundle/1.0.0';$status=Join-Path $LauncherHome 'status'
if(Test-Path -LiteralPath $TestRoot){throw 'Тестовый каталог должен быть новым'}
[void][IO.Directory]::CreateDirectory($bundle);[void][IO.Directory]::CreateDirectory($status)
$utf8=New-Object Text.UTF8Encoding($true)
function Save([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,$utf8)}
function Quote([string]$Text){'"'+[regex]::Replace([regex]::Replace($Text,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'}
function Start-Launcher([string[]]$CommandArgs){Start-Process -FilePath $Exe -ArgumentList (($CommandArgs|ForEach-Object {Quote $_}) -join ' ') -PassThru}
function Wait-State([scriptblock]$Test,[int]$Seconds=20){
    $until=(Get-Date).AddSeconds($Seconds)
    while((Get-Date) -lt $until){try{if(& $Test){return}}catch{};Start-Sleep -Milliseconds 250}
    throw 'Проверка не подтвердилась вовремя'
}
Save (Join-Path $LauncherHome 'bundle/current.txt') "1.0.0`r`n"
Save (Join-Path $LauncherHome 'config.json') '{"schema":1,"version":1,"components":{},"update":{"enabled":false,"args":[]}}'
$component=@{
    name='fixture';title='Тестовый компонент';exe='powershell.exe'
    args=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File','{bundle}\parent.ps1','-Home','{home}')
    cwd='{bundle}';restart='always';healthFile='status/fixture.json';healthMaxAgeSec=5;enabledByDefault=$true;critical=$true
}
Save (Join-Path $bundle 'components.json') (ConvertTo-Json -InputObject @($component) -Depth 8)
Save (Join-Path $bundle 'child.ps1') @'
param([Alias('Home')][string]$LauncherHome)
[IO.File]::WriteAllText((Join-Path $LauncherHome 'child.pid'),[string]$PID)
while($true){Start-Sleep -Seconds 1}
'@
Save (Join-Path $bundle 'parent.ps1') @'
param([Alias('Home')][string]$LauncherHome)
$child=Join-Path $PSScriptRoot 'child.ps1'
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$child+'" -Home "'+$LauncherHome+'"') | Out-Null
$health=Join-Path $LauncherHome 'status/fixture.json'
while($true){
    if(-not (Test-Path -LiteralPath (Join-Path $LauncherHome 'freeze'))){
        [IO.File]::WriteAllText($health,'{"ok":true,"summary":"test fixture heartbeat"}')
    }
    Start-Sleep -Seconds 1
}
'@
$p=$null;$childId=0;$firstPid=0
try {
    $p=Start-Launcher @('--tray','--home',$LauncherHome)
    Wait-State { $script:s=Get-Content -LiteralPath (Join-Path $status 'launcher.json') -Raw|ConvertFrom-Json; $s.ok -and @($s.components)[0].alive }
    $firstPid=[int]@($s.components)[0].pid
    Wait-State { Test-Path -LiteralPath (Join-Path $LauncherHome 'child.pid') }
    $childId=[int]([IO.File]::ReadAllText((Join-Path $LauncherHome 'child.pid')))
    $second=Start-Launcher @('--home',$LauncherHome,'--restart-components')
    if(-not $second.WaitForExit(15000) -or $second.ExitCode -ne 0){throw 'Второй экземпляр не передал команду'}
    Wait-State { $script:s=Get-Content -LiteralPath (Join-Path $status 'launcher.json') -Raw|ConvertFrom-Json; $s.ok -and [int]@($s.components)[0].pid -ne $firstPid }
    Wait-State { -not (Get-Process -Id $childId -ErrorAction SilentlyContinue) }
    Wait-State { [int]([IO.File]::ReadAllText((Join-Path $LauncherHome 'child.pid'))) -ne $childId }
    $childId=[int]([IO.File]::ReadAllText((Join-Path $LauncherHome 'child.pid')))
    Save (Join-Path $LauncherHome 'freeze') ''
    Wait-State { $script:s=Get-Content -LiteralPath (Join-Path $status 'launcher.json') -Raw|ConvertFrom-Json; -not $s.ok -and @($s.components)[0].alive }
    Remove-Item -LiteralPath (Join-Path $LauncherHome 'freeze')
    Wait-State { $script:s=Get-Content -LiteralPath (Join-Path $status 'launcher.json') -Raw|ConvertFrom-Json; $s.ok }
    $command=Start-Launcher @('--home',$LauncherHome,'--exit');[void]$command.WaitForExit(15000)
    if(-not $p.WaitForExit(15000)){throw 'Лаунчер не завершился'}
    Wait-State { -not (Get-Process -Id $childId -ErrorAction SilentlyContinue) }
    $s=Get-Content -LiteralPath (Join-Path $status 'launcher.json') -Raw|ConvertFrom-Json
    if($s.running -or $s.ok){throw 'Статус завершения неверен'}
    Write-Output ('PASS: IPC, restart, stale health, recovery, job tree shutdown. Results: '+$TestRoot)
} finally {
    if($p -and -not $p.HasExited){$command=Start-Launcher @('--home',$LauncherHome,'--exit');[void]$command.WaitForExit(10000);[void]$p.WaitForExit(10000);if(-not $p.HasExited){$p.Kill()}}
}
