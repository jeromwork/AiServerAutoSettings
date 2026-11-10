#requires -Version 5.1
# Shared ownership helpers: same embedded engine and state as the former tray.
function Get-DiskEngineProcesses([string]$DiskRoot) {
    $exe=[IO.Path]::GetFullPath((Join-Path $DiskRoot 'tray/syncthingtray.exe'))
    $state=[IO.Path]::GetFullPath((Join-Path $DiskRoot 'state')).Replace('/','\')
    $statePattern='(?:^|\s)"?--home(?:"?\s+|=)"?'+[regex]::Escape($state)+'"?(?=\s|$)'
    @(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object {
        if(-not $_.ExecutablePath -or [IO.Path]::GetFullPath($_.ExecutablePath) -ine $exe){return $false}
        $line=([string]$_.CommandLine).Replace('/','\')
        # GUI owns its adjacent ini. Embedded command mode belongs to us only for this state.
        ($line -notmatch '(?:^|\s)"?syncthing"?(?:\s|$)' -or $line -match $statePattern)
    })
}
function Stop-DiskEngineProcesses([string]$DiskRoot) {
    # Stop tray first (it can respawn the engine); then its embedded Syncthing child.
    $processes=@(Get-DiskEngineProcesses $DiskRoot|Sort-Object @{Expression={if($_.CommandLine -match '(?:^|\s)"?syncthing"?\s+"?serve"?(?:\s|$)'){1}else{0}}})
    foreach($p in $processes){
        $live=Get-CimInstance Win32_Process -Filter ('ProcessId='+$p.ProcessId) -ErrorAction Stop
        if($live -and $live.ExecutablePath -ieq $p.ExecutablePath -and $live.CreationDate -eq $p.CreationDate){
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            $wait=$null;try{$wait=[Diagnostics.Process]::GetProcessById($p.ProcessId)}catch [ArgumentException]{}
            if($wait){try{if(-not $wait.WaitForExit(10000)){throw 'Syncthing не завершён'}}finally{$wait.Dispose()}}
        }
    }
    if(@(Get-DiskEngineProcesses $DiskRoot).Count){throw 'Syncthing ещё работает'}
}
function Start-DiskHeadless {
    $exe=Join-Path $script:DiskHome 'tray/syncthingtray.exe'
    if(-not (Test-Path $exe)){throw 'Syncthing не установлен'}
    if($script:DiskEngine -and -not $script:DiskEngine.HasExited){return}
    # Never adopt an unowned engine or create a second process for the same state.
    if(@(Get-DiskEngineProcesses $script:DiskHome).Count){throw 'Остался прежний Syncthing: требуется переход с откатом'}
    $si=New-Object Diagnostics.ProcessStartInfo
    $si.FileName=$exe;$si.Arguments=(@('syncthing','serve','--home',(Join-Path $script:DiskHome 'state'),'--no-browser','--no-restart')|ForEach-Object {Quote-Disk $_}) -join ' '
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true
    $script:DiskEngine=[Diagnostics.Process]::Start($si)
}
