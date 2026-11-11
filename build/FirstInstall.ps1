#requires -Version 5.1
[CmdletBinding()]
param([Alias('Home')][string]$LauncherHome,[string]$ServerAddress,[string]$Login,[switch]$LibraryOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Migrate.Common.ps1')
function Find-InstallProfile([string]$Root) {
    $config=Join-Path $Root 'config.json'
    if(Test-Path $config){$c=Read-TransportJson $config;if($c.wizard.pendingProfile){return [string]$c.wizard.pendingProfile};if($c.transport.profilePath){return [string]$c.transport.profilePath}}
    $saved=Join-Path $env:LOCALAPPDATA 'RemoteDisk/profile.txt'
    if(Test-Path $saved){return [IO.File]::ReadAllText($saved).Trim()}
    $files=@(Get-ChildItem -Path (Join-Path $Root 'ssh-profiles/*/project-connections/*/ssh-transport.json') -File -ErrorAction SilentlyContinue)
    if($files.Count -eq 1){return $files[0].FullName}
    if($files.Count -gt 1){throw 'Несколько профилей: задайте transport.profilePath в config.json'}
    return ''
}
function Invoke-InstallChild([string]$Bundle,[string]$Script,[string[]]$Arguments,[int]$TimeoutSeconds=900) {
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=Get-TransportPowerShell
    $sta=@();if($env:OS -eq 'Windows_NT'){$sta=@('-STA')}
    $psi.Arguments=(@('-NoLogo','-NoProfile','-NonInteractive')+$sta+@('-ExecutionPolicy','Bypass','-File',(Join-Path $Bundle $Script))+$Arguments|ForEach-Object {Quote-Transport ([string]$_)}) -join ' '
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $p=[Diagnostics.Process]::Start($psi)
    $out=$p.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null);$err=$p.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
    try{if(-not $p.WaitForExit($TimeoutSeconds*1000)){$p.Kill();throw ('Таймаут шага ('+$TimeoutSeconds+' с)')};if($p.ExitCode -ne 0){throw 'Шаг установки не выполнен'}}finally{$p.Dispose()}
}
function Invoke-FirstInstall([string]$Root,[string]$Bundle,[string]$Address,[string]$User) {
    # Existing migration is kept intact, including its independent network watchdog.
    $failure=Join-Path $Root 'state/migration-error.json';if(Test-Path $failure){Remove-Item -LiteralPath $failure -Force}
    Write-MigrationLog $Root 'setup.start'
    $profile=Find-InstallProfile $Root
    if(-not $profile){
        if(-not $Address -or -not $User){throw 'Нужны адрес сервера и пользователь'}
        Invoke-InstallChild $Bundle 'setup-vps-ssh.ps1' @('-ServerAddress',$Address,'-Login',$User,'-ProfileName',$Address,'-DataDir',(Join-Path $Root 'ssh-profiles'),'-SetupOnly')
        $profile=Find-InstallProfile $Root
        if(-not $profile){throw 'Ключ SSH не настроен'}
    }
    # Always prove saved credentials work; config presence is not a completion marker.
    $p=Read-TransportJson $profile
    [void](Invoke-TransportText $p.sshExecutable (@('-o','BatchMode=yes','-o','ConnectTimeout=10','-o','StrictHostKeyChecking=yes')+@($p.arguments)+@('true')))
    Write-MigrationLog $Root 'setup.ssh.verified'
    $diskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk'
    if(-not (Test-Path (Join-Path $diskHome 'state/config.xml')) -and -not (Test-Path (Join-Path $diskHome 'selection.json'))){
        [void][IO.Directory]::CreateDirectory($diskHome)
        Write-TransportJson (Join-Path $diskHome 'selection.json') @{schema=1;paths=@();placeholder=$true}
    }
    if(-not (Test-Path (Join-Path $diskHome 'state/config.xml')) -or -not (Test-Path (Join-Path $diskHome 'channel/config.json')) -or -not (Test-Path (Join-Path $env:LOCALAPPDATA 'RemoteAgents/control/config.json')) -or -not (Get-MigrationRun 'RemoteAgentsControl')){
        Invoke-InstallChild $Bundle 'Setup-All.ps1' @('-Profile',$profile,'-LauncherSetup')
    }
    Invoke-InstallChild $Bundle 'build/Migrate.ps1' @('-Home',$Root)
}
if($LibraryOnly){return}
$default=Join-Path $env:LOCALAPPDATA 'RemoteAgents'
if([IO.Path]::GetFullPath($LauncherHome).TrimEnd('\') -ine [IO.Path]::GetFullPath($default).TrimEnd('\')){throw 'Рабочая установка только в основном Home; изолированный Home не меняет компьютер'}
try{Invoke-FirstInstall $LauncherHome (Split-Path $PSScriptRoot -Parent) $ServerAddress $Login}catch{Save-MigrationFailure $LauncherHome $_;Write-MigrationLog $LauncherHome 'setup.failed';throw 'Установка не завершена; смотрите локальные журналы SSH, диска и моста'}
