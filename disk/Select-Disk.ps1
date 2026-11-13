#requires -Version 5.1
[CmdletBinding()]
param([Alias('Home')][string]$LauncherHome,[ValidateSet('Tree','Apply')][string]$Action='Tree',[string]$SelectionFile,[string]$RelativePath='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Disk.Common.ps1')
. (Join-Path $PSScriptRoot 'Disk.Union.ps1')
$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk'
# One failing folder must not stop the others: every failure is collected and reported at the end.
$script:SelectFailures=New-Object Collections.ArrayList
function Add-SelectFailure([string]$Name,$Failure) {
    Write-DiskLog ('Выбор синхронизации: '+$Name) $Failure
    [void]$script:SelectFailures.Add([pscustomobject]@{name=$Name;reason=[string]$Failure.Exception.Message})
    Write-DiskProgress ('Не подключена папка «'+$Name+'»: '+$Failure.Exception.Message)
}
try{
    Write-DiskLog ('Выбор синхронизации: '+$Action)
    Read-DiskProfile
    # Refresh public server helper through the saved SSH profile (keeps the server copy current).
    $upload='set -eu; umask 077; mkdir -p "$HOME/.local/share/remote-disk"'+"`n"
    foreach($name in @('server-disk.sh')){
        $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot $name)).Replace("`r",'')
        $remote='$HOME/.local/share/remote-disk/'+$name;$temp=$remote+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
        $upload+='printf %s '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($source))+' | base64 -d > "'+$temp+'"; mv -f -- "'+$temp+'" "'+$remote+'"'+"`n"
    }
    $upload+=Get-DiskIgnoreUpload
    [void](Invoke-DiskSsh 'bash -s' -InputText $upload)
    $lock=[IO.File]::Open((Join-Path $script:DiskHome 'folders.lock'),'OpenOrCreate','ReadWrite','None')
    try{
        if($Action -eq 'Tree'){
            $tree=Invoke-DiskServer tree @{path=$RelativePath}
            $union=Get-DiskUnion $tree (Get-DiskBase) $RelativePath
            $selection=Read-DiskSelection
            if($null -eq $selection){$selection=@{schema=1;paths=@($union.rows|Where-Object {$_.path -notmatch '/' -and $_.kind -eq 'directory'}|ForEach-Object {$_.path})}}
            @{tree=$tree;union=$union;selection=$selection}|ConvertTo-Json -Depth 30 -Compress
        }else{
            $selection=[IO.File]::ReadAllText($SelectionFile).Replace("`r",'')|ConvertFrom-Json
            if($selection.schema -ne 1){throw 'Неверный формат выбора'}
            $paths=@(Get-SelectionPaths $selection)
            foreach($project in $paths){if($project -cne '.'){[void](Get-DiskDirection $selection ($project.Split('/')[0]))}}
            $union=Get-DiskUnion (Invoke-DiskServer tree) (Get-DiskBase)
            # All selects project directories only; loose root files remain local.
            foreach($row in @($union.rows|Where-Object {$_.kind -eq 'file' -and $_.path -notmatch '/'})){if('.' -cnotin $paths -and (Test-SelectionIncluded $row.path $paths)){throw 'Файлы в корне Disk сначала поместите в папку проекта; исходный файл сохранён'}}
            Read-DiskState
            Resume-InterruptedSelection
            try{Sync-DiskExternal @($selection.external) (Get-DiskBase)}catch{Add-SelectFailure 'внешние папки' $_}
            $external=@(Read-DiskExternal)
            # Save policy before attaching: unselected local content must never be offered to the server.
            foreach($project in @($union.rows|Where-Object {$_.path -notmatch '/' -and $_.kind -eq 'directory' -and $_.presence -ne 'server'})){
                if(@($external|Where-Object {$_.remote -ieq $project.path}).Count){continue}
                $chosen=@(Get-ProjectSelection $project.path $selection)
                if(-not $chosen.Count){continue}
                try{
                    $projectPath=Join-Path (Get-DiskBase) $project.path
                    $known=@(Invoke-DiskApi 'config/folders'|Where-Object {[IO.Path]::GetFullPath($_.path) -ieq [IO.Path]::GetFullPath($projectPath)})
                    if(-not $known.Count){
                        Initialize-ProjectSelection $projectPath $chosen
                        # A project present on both sides is merged (Add-RemoteDiskFolder): nothing is deleted, identical files stay single.
                        & (Join-Path $PSScriptRoot 'Add-RemoteDiskFolder.ps1') -Path $projectPath -Remote $project.path -ManagedSelection -Direction (Get-DiskDirection $selection $project.path)
                        if(-not $?){throw 'Не удалось подключить локальную папку'}
                    }
                }catch{Add-SelectFailure $project.path $_}
            }
            $peer=[IO.File]::ReadAllText((Join-Path $script:DiskHome 'server.txt')).Trim()
            foreach($folder in @(Invoke-DiskApi 'config/folders')){
                if(-not @($folder.devices|Where-Object {$_.deviceID -ceq $peer}).Count){continue}
                $expected=[IO.Path]::GetFullPath((Join-Path (Get-DiskBase) $folder.label))
                if([IO.Path]::GetFullPath($folder.path) -ine $expected){continue} # External and foreign folders have their own ownership.
                $chosen=@(Get-ProjectSelection $folder.label $selection)
                try{
                    if(-not $chosen.Count){
                        # Persist the exact identity BEFORE unregistering, including after an interrupted apply.
                        Save-DiskDetachedProject $folder $peer ([string](Invoke-DiskApi 'system/status').myID)
                        # Syncthing DELETE unregisters the folder on this device; it never deletes its contents.
                        [void](Invoke-DiskApi ('config/folders/'+[Uri]::EscapeDataString($folder.id)) DELETE)
                        continue
                    }
                    Set-DiskFolderDirection $folder (Get-DiskDirection $selection $folder.label)
                    if($folder.maxConflicts -ne -1 -or $folder.versioning.type -ne 'staggered' -or [string]$folder.versioning.params.maxAge -ne '0'){[void](Invoke-DiskApi ('config/folders/'+[Uri]::EscapeDataString($folder.id)) PATCH @{maxConflicts=-1;versioning=@{type='staggered';params=@{maxAge='0';cleanInterval='3600'}}})}
                    Set-ProjectSelection $folder $chosen
                }catch{Add-SelectFailure ([string]$folder.label) $_}
            }
            # Only what was applied is saved: a failed project stays unselected, so the tree shows the real state.
            $failed=@($script:SelectFailures|ForEach-Object {$_.name})
            $saved=@($paths|Where-Object {$_ -ceq '.' -or $_.Split('/')[0] -cnotin $failed})
            Write-DiskUtf8 (Join-Path $script:DiskHome 'selection.json') (@{schema=1;paths=$saved;directions=$selection.directions;external=@($selection.external)}|ConvertTo-Json -Depth 20 -Compress)
            # A successfully applied explicit project choice clears its automatic exclusion.
            $explicit=@($saved|Where-Object {$_ -cne '.'}|ForEach-Object {$_.Split('/')[0]})
            $excluded=@(Read-DiskExternalExclusions)
            if(@($excluded|Where-Object {$_ -iin $explicit}).Count){Write-DiskExternalExclusions @($excluded|Where-Object {$_ -notin $explicit})}
            @{ok=($script:SelectFailures.Count -eq 0);failed=@($script:SelectFailures)}|ConvertTo-Json -Compress
        }
    }finally{$lock.Dispose()}
    if($Action -eq 'Apply'){& (Join-Path $PSScriptRoot 'Sync-RemoteDiskFolders.ps1')}
}catch{Write-DiskLog 'Выбор синхронизации: не завершён' $_;$reason='Выбор не применён полностью; локальные файлы сохранены. Причина: '+$_.Exception.Message;[Console]::Error.WriteLine($reason);throw $reason}
if($script:SelectFailures.Count){
    # Emit an unwrapped first stderr line before PowerShell adds source/stack decorations.
    $list=@($script:SelectFailures|ForEach-Object {'«'+$_.name+'» — '+$_.reason}) -join '; '
    Write-DiskLog ('Выбор синхронизации: не подключено '+$script:SelectFailures.Count)
    $reason='Не все выбранные папки подключены. Ошибки: '+$list+'. Остальные папки подключены; локальные файлы сохранены.'
    [Console]::Error.WriteLine($reason);throw $reason
}
