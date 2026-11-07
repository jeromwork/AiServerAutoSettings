#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Path,[string]$Remote,[switch]$Merge)
. (Join-Path $PSScriptRoot 'Disk.Common.ps1')
$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk';$interactive=-not $Remote
$step='Проверка локальной папки'
try {
    Read-DiskProfile '';Read-DiskState;$Path=[IO.Path]::GetFullPath($Path);$item=Get-Item -LiteralPath $Path
    if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Нужна обычная папка'}
    for($parent=$item;$null -ne $parent;$parent=$parent.Parent){if($parent.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Ссылки в пути запрещены'}}
    $step='Список серверных папок';Test-DiskIgnores $Path;$folders=@(Invoke-DiskServer list);$name=Split-Path $Path -Leaf
    if($interactive){
        Add-Type -AssemblyName System.Windows.Forms
        $same=@($folders|Where-Object {$_.name -ceq $name})
        if($same.Count -eq 1){if([Windows.Forms.MessageBox]::Show(('Подключить к серверной папке '+$name+'?'),'RemoteDisk','YesNo') -ne 'Yes'){return};$Remote=$name}else{
            $form=New-Object Windows.Forms.Form;$form.Text='Серверная папка';$form.Width=520;$list=New-Object Windows.Forms.ListBox;$list.Dock='Fill';foreach($f in $folders){[void]$list.Items.Add($f.name)};[void]$list.Items.Add('Создать: '+$name);$list.SelectedIndex=$list.Items.Count-1
            $ok=New-Object Windows.Forms.Button;$ok.Text='Подключить';$ok.Dock='Bottom';$ok.DialogResult='OK';$form.Controls.Add($list);$form.Controls.Add($ok);$form.AcceptButton=$ok
            try{if($form.ShowDialog() -ne 'OK'){return};$Remote=$name;if($list.SelectedIndex -lt $folders.Count){$Remote=$folders[$list.SelectedIndex].name}}finally{$form.Dispose()}
        }
    }
    if($Remote.Length -gt 128 -or $Remote -notmatch '^[\p{L}\p{N}_][\p{L}\p{N}_. -]*$' -or $Remote.Contains('..') -or $Remote -match '[ .]$|^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){throw 'Недопустимое имя серверной папки'}
    $has=@(Get-ChildItem -LiteralPath $Path -Force|Where-Object {$_.Name -notin @('.git','.stignore','.stfolder','.stversions')}).Count -gt 0;$target=@($folders|Where-Object {$_.name -ceq $Remote})
    $step='Проверка подключения';$local=Invoke-DiskApi 'system/status';if(-not $local.myID){throw 'Движок не вернул ID устройства'};$peer=[IO.File]::ReadAllText((Join-Path $script:DiskHome 'server.txt'));$existing=@(Invoke-DiskApi 'config/folders');$match=@($existing|Where-Object {$_.path.TrimEnd('\','/') -ieq $Path.TrimEnd('\','/')})
    if($match.Count -gt 1){throw 'Несколько ID для одной локальной папки'}
    $sha=[Security.Cryptography.SHA256]::Create();try{$id='disk-'+([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('folder:'+$Remote))).Replace('-','').ToLowerInvariant()).Substring(0,24)}finally{$sha.Dispose()};if($target.Count){$id=$target[0].id}
    if($match.Count -and $match[0].id -cne $id){throw 'Локальная папка уже связана с другим ID'};if(@($existing|Where-Object {$_.id -ceq $id -and $_.path.TrimEnd('\','/') -ine $Path.TrimEnd('\','/')}).Count){throw 'Эта серверная папка уже подключена в другом месте'}
    if(-not $match.Count -and $has -and $target.Count -and $target[0].hasFiles -and -not $Merge){if(-not $interactive){throw 'Обе папки непустые: требуется -Merge'};if([Windows.Forms.MessageBox]::Show('Обе папки непустые. Объединить содержимое?','RemoteDisk','YesNo','Warning') -ne 'Yes'){return};$Merge=$true}
    $step='Подключение папки на сервере';[void](Invoke-DiskServer attach @{name=$Remote;deviceId=$local.myID;localHasFiles=$has;merge=[bool]$Merge});Test-DiskIgnores $Path -Write
    if($match.Count){$folder=$match[0]}else{$folder=@{id=$id;label=$Remote;path=$Path;type='sendreceive';paused=$true;rescanIntervalS=60;fsWatcherEnabled=$true;devices=@(@{deviceID=$local.myID})}}
    $folder.maxConflicts=10;if(-not @($folder.devices|Where-Object {$_.deviceID -ceq $peer}).Count){$folder.devices+=@(@{deviceID=$peer})}
    $step='Подключение локальной папки';[void](Invoke-DiskApi ('config/folders/'+$id) PUT $folder);if(-not $match.Count){[void](Invoke-DiskApi ('config/folders/'+$id) PATCH @{paused=$false})};Write-DiskLog 'Подключение папки';Write-Output 'Папка подключена. Передача продолжается в фоне.'
}catch{Write-DiskLog $step $_;if($interactive){Add-Type -AssemblyName System.Windows.Forms;[void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'RemoteDisk')};Write-Error $_.Exception.Message;exit 1}
