#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Path,[string]$Remote,[switch]$Merge,[switch]$ManagedSelection,[ValidateSet('both','send','receive')][string]$Direction='both')
. (Join-Path $PSScriptRoot 'Disk.Common.ps1')
$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk';$interactive=-not $Remote
$step='Проверка локальной папки'
try {
    Read-DiskProfile '';Read-DiskState;$Path=[IO.Path]::GetFullPath($Path);$item=Get-Item -LiteralPath $Path
    if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Нужна обычная папка'}
    for($parent=$item;$null -ne $parent;$parent=$parent.Parent){if($parent.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Ссылки в пути запрещены'}}
    $step='Список серверных папок';if(-not $ManagedSelection){Test-DiskIgnores $Path};$folders=@(Invoke-DiskServer list);$name=Split-Path $Path -Leaf
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
    $has=Test-DiskLocalContent $Path;$target=@($folders|Where-Object {$_.name -ceq $Remote})
    $step='Проверка подключения';$local=Invoke-DiskApi 'system/status';if(-not $local.myID){throw 'Движок не вернул ID устройства'};$peer=[IO.File]::ReadAllText((Join-Path $script:DiskHome 'server.txt')).Trim();$existing=@(Invoke-DiskApi 'config/folders');$match=@($existing|Where-Object {$_.path.TrimEnd('\','/') -ieq $Path.TrimEnd('\','/')})
    if($match.Count -gt 1){throw 'Несколько ID для одной локальной папки'}
    $sha=[Security.Cryptography.SHA256]::Create();try{$id='disk-'+([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('folder:'+$Remote))).Replace('-','').ToLowerInvariant()).Substring(0,24)}finally{$sha.Dispose()};if($target.Count){$id=$target[0].id}
    if($match.Count -and $match[0].id -cne $id){throw 'Локальная папка уже связана с другим ID'};if(@($existing|Where-Object {$_.id -ceq $id -and $_.path.TrimEnd('\','/') -ine $Path.TrimEnd('\','/')}).Count){throw 'Эта серверная папка уже подключена в другом месте'}
    $reconnecting=$ManagedSelection -and (Test-DiskProjectReconnect $Path $Remote $id $peer ([string]$local.myID))
    # Owner decision: a folder present on both sides is always merged, without a question and without refusal (-Merge is kept
    # only for old callers). Both sides keep maxConflicts=-1 and staggered versioning (set below and by server attach), so a merge
    # deletes nothing. Syncthing 2.1.7 compares block hashes: byte-identical files become one file (only time/attributes are
    # aligned, nothing is transferred); a .sync-conflict copy appears only when contents really differ (disk/test-wizard-merge.py).
    if(-not $match.Count -and -not $reconnecting -and $has -and $target.Count -and $target[0].hasFiles){Write-DiskProgress ('Объединяю «'+$Remote+'»: на компьютере и на сервере есть файлы; ничего не удаляется, при расхождении сохраняются обе версии')}
    $step='Подключение папки на сервере';[void](Invoke-DiskServer attach @{name=$Remote;deviceId=$local.myID;localHasFiles=$has;merge=$true});Test-DiskIgnores $Path -Write
    if($match.Count){$folder=$match[0]}else{$folder=@{id=$id;label=$Remote;path=$Path;type='sendreceive';paused=$true;rescanIntervalS=60;fsWatcherEnabled=$true;devices=@(@{deviceID=$local.myID})}}
    $folder.type=Get-DiskFolderType $Direction
    $folder.maxConflicts=-1;$versioning=@{type='staggered';params=@{maxAge='0';cleanInterval='3600'}};if($folder -is [Collections.IDictionary]){$folder.versioning=$versioning}else{$folder|Add-Member -Force versioning $versioning};if(-not @($folder.devices|Where-Object {$_.deviceID -ceq $peer}).Count){$folder.devices+=@(@{deviceID=$peer})}
    $step='Подключение локальной папки';[void](Invoke-DiskApi ('config/folders/'+$id) PUT $folder);if(-not $match.Count){[void](Invoke-DiskApi ('config/folders/'+$id) PATCH @{paused=$false})};Write-DiskLog 'Подключение папки';Write-Output 'Папка подключена. Передача продолжается в фоне.'
}catch{Write-DiskLog $step $_;if($interactive){Add-Type -AssemblyName System.Windows.Forms;[void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'RemoteDisk')};throw}
