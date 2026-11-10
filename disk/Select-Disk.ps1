#requires -Version 5.1
[CmdletBinding()]
param([Alias('Home')][string]$LauncherHome,[ValidateSet('Tree','Apply')][string]$Action='Tree',[string]$SelectionFile)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Disk.Common.ps1')
$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk'
try{
    Write-DiskLog ('Выбор синхронизации: '+$Action)
    Read-DiskProfile
    # Refresh public server helper through the saved SSH profile (also upgrades old installations).
    $upload='set -eu; umask 077; mkdir -p "$HOME/.local/share/remote-disk"'+"`n"
    foreach($name in @('server-disk.sh','stignore.txt','legacy-ignores.sha256')){
        $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot $name)).Replace("`r",'')
        $remote='$HOME/.local/share/remote-disk/'+$name;$temp=$remote+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
        $upload+='printf %s '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($source))+' | base64 -d > "'+$temp+'"; mv -f -- "'+$temp+'" "'+$remote+'"'+"`n"
    }
    [void](Invoke-DiskSsh 'bash -s' -InputText $upload)
    $lock=[IO.File]::Open((Join-Path $script:DiskHome 'folders.lock'),'OpenOrCreate','ReadWrite','None')
    try{
        # Replace the legacy scheduled companion before any new device policy is saved.
        $app=Join-Path $script:DiskHome 'app';[void][IO.Directory]::CreateDirectory($app)
        foreach($name in @('Disk.Common.ps1','Disk.Selective.ps1','Sync-RemoteDiskFolders.ps1','stignore.txt','legacy-ignores.sha256')){
            $target=Join-Path $app $name
            if([IO.Path]::GetFullPath($target) -ine [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $name))){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $target -Force}
        }
        if($Action -eq 'Tree'){
            $tree=Invoke-DiskServer tree
            $selection=Read-DiskSelection
            if($null -eq $selection){$selection=@{schema=1;paths=@($tree.folders|ForEach-Object {$_.name})}}
            @{tree=$tree;selection=$selection}|ConvertTo-Json -Depth 30 -Compress
        }else{
            $selection=[IO.File]::ReadAllText($SelectionFile).Replace("`r",'')|ConvertFrom-Json
            if($selection.schema -ne 1){throw 'Неверный формат выбора'}
            $paths=@(Get-SelectionPaths $selection)
            Read-DiskState
            $peer=[IO.File]::ReadAllText((Join-Path $script:DiskHome 'server.txt')).Trim()
            foreach($folder in @(Invoke-DiskApi 'config/folders')){
                if(-not @($folder.devices|Where-Object {$_.deviceID -ceq $peer}).Count){continue}
                $expected=[IO.Path]::GetFullPath((Join-Path (Get-DiskBase) $folder.label))
                if([IO.Path]::GetFullPath($folder.path) -ine $expected){throw 'Сначала перенесите проект в Disk'}
                Set-ProjectSelection $folder @(Get-ProjectSelection $folder.label $selection)
            }
            Write-DiskUtf8 (Join-Path $script:DiskHome 'selection.json') (@{schema=1;paths=$paths}|ConvertTo-Json -Depth 20 -Compress)
            @{ok=$true}|ConvertTo-Json -Compress
        }
    }finally{$lock.Dispose()}
    if($Action -eq 'Apply'){& (Join-Path $PSScriptRoot 'Sync-RemoteDiskFolders.ps1')}
}catch{Write-DiskLog 'Выбор синхронизации: не завершён';throw 'Выбор не применён полностью. Файлы без подтверждённой серверной копии сохранены. Дождитесь синхронизации, проверьте SSH и повторите.'}
