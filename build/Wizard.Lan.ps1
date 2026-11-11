#requires -Version 5.1
function Get-WizardLanPayload([string]$File) {
    if(-not [IO.File]::Exists($File) -or [IO.Path]::GetExtension($File) -ine '.ovpn'){throw 'Выберите существующий файл .ovpn'}
    $parent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($File))
    $text=Convert-TransportLF ([IO.File]::ReadAllText($File));$lines=New-Object Collections.Generic.List[string];$block=''
    foreach($line in $text.Split("`n")){
        $trim=$line.Trim()
        if($block){$lines.Add($line);if($trim -ceq ('</'+$block+'>')){$block=''};continue}
        if($trim -match '^<([a-z-]+)>$'){$block=$Matches[1];$lines.Add($line);continue}
        if($trim -match '^(?:--)?(ca|cert|key|auth-user-pass|tls-auth|tls-crypt|tls-crypt-v2)(?:\s+(.*))?$'){
            $kind=$Matches[1];$value=[string]$Matches[2]
            if($value -eq '[inline]'){$lines.Add($line);continue}
            # Only files next to the selected profile. No traversal, shell expansions or absolute paths.
            if($value -notmatch '^(?:"([^"/\\]+)"|''([^''/\\]+)''|([^\s/\\]+))(?:\s+([01]))?$'){throw ('Для '+$kind+' нужен файл рядом с .ovpn; интерактивный ввод не поддерживается')}
            $name=($Matches[1]+$Matches[2]+$Matches[3]);$direction=$Matches[4]
            if($name -in @('.','..') -or $name.Contains(':')){throw 'Неверная ссылка на файл профиля'}
            $related=Join-Path $parent $name
            if(-not [IO.File]::Exists($related)){throw ('Не найден связанный файл для '+$kind+': '+$name)}
            if((Get-Item -LiteralPath $related).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Связанный файл не должен быть ссылкой'}
            $content=Convert-TransportLF ([IO.File]::ReadAllText($related))
            if($content -match '(?m)^\s*</?[a-z-]+>\s*$'){throw 'Недопустимый блок в связанном файле'}
            $lines.Add('<'+$kind+'>');$lines.Add($content.TrimEnd());$lines.Add('</'+$kind+'>')
            if($direction){$lines.Add('key-direction '+$direction)}
        }else{$lines.Add($line)}
    }
    return ($lines -join "`n")+"`n"
}
function Send-WizardLan([string]$Root,[string]$Bundle,[string]$File) {
    # The server importer requires inline secrets; references are resolved in memory, never logged.
    $payload=Get-WizardLanPayload $File
    $name='l'+(Get-TransportFingerprint 'lan' ([IO.Path]::GetFileNameWithoutExtension($File))).Substring(0,6)
    Write-WizardProgress 'Копирую профиль локальной сети на сервер…'
    $upload='set -eu; umask 077; dir="$HOME/.config/remoteagents/lan/'+$name+'"; test ! -L "$dir"; mkdir -p "$dir"; chmod 700 "$dir"; test ! -L "$dir/profile.ovpn"; '+"`n"
    $data=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload));$temp=[guid]::NewGuid().ToString('N')
    $upload+='printf %s '+$data+' | base64 -d > "$dir/.'+$temp+'"; chmod 600 "$dir/.'+$temp+'"; mv -f "$dir/.'+$temp+'" "$dir/profile.ovpn"'+"`n"
    $upload+='mkdir -p "$HOME/.local/share/remoteagents-lan/server"'+"`n"
    foreach($fileName in @('lan-vpn.sh','lan_vpn.py')){
        $bytes=[Text.Encoding]::UTF8.GetBytes((Convert-TransportLF ([IO.File]::ReadAllText((Join-Path $Bundle ('server/'+$fileName))))))
        $upload+='test ! -L "$HOME/.local/share/remoteagents-lan/server/'+$fileName+'"; printf %s '+[Convert]::ToBase64String($bytes)+' | base64 -d > "$HOME/.local/share/remoteagents-lan/server/.'+$temp+'"; mv -f "$HOME/.local/share/remoteagents-lan/server/.'+$temp+'" "$HOME/.local/share/remoteagents-lan/server/'+$fileName+'"'+"`n"
    }
    [void](Invoke-WizardSsh $Root 'bash -s' $upload)
    # This is an upload receipt, never a claim that OpenVPN or the LAN is enabled.
    $p=Read-TransportJson (Find-InstallProfile $Root)
    $command='read -r -p ''HTTPS URL проверки IP: '' ra_lan_ip; sudo bash ~'+$p.login+'/.local/share/remoteagents-lan/server/lan-vpn.sh add '+$name+' ~'+$p.login+'/.config/remoteagents/lan/'+$name+'/profile.ovpn --ip-check-url "$ra_lan_ip"'
    Write-TransportJson (Join-Path $Root 'state/lan-upload.json') @{schema=1;name=$name;command=$command;uploaded=$true;profile=(Find-InstallProfile $Root)}
    return @{ok=$true;command=$command;summary='Файл на сервере ✓. Включение выполняет администратор сервера; команда запросит HTTPS-адрес проверки IP'}
}
function Suspend-WizardDisk([string]$Root,[string]$Bundle) {
    $hold=Join-Path $Root 'state/disk-reconfigure';Write-DiskUtf8 $hold 'Old disk disconnected; data preserved'
    Update-MigrationConfig $Root {param($c) Set-MigrationDefault $c components ([pscustomobject]@{});Set-MigrationDefault $c.components disk ([pscustomobject]@{});$c.components.disk|Add-Member -Force enabled $false}
    Invoke-InstallChild $Bundle 'disk/Install-RemoteDisk.ps1' @('-Uninstall') -TimeoutSeconds 120
    Stop-MigrationDisk (Join-Path $env:LOCALAPPDATA 'RemoteDisk')
}
function Resolve-WizardDiskServer([string]$Root,[string]$Bundle,$Request) {
    $c=Read-TransportJson (Join-Path $Root 'config.json')
    if(-not $c.wizard.diskPreviousProfile){return}
    if(-not $Request.reconnect){throw 'Диск связан с прежним сервером. Выберите отключение и новую пустую папку либо оставьте прежнее подключение'}
    $base=[IO.Path]::GetFullPath([string]$Request.base)
    if((Test-Path -LiteralPath $base) -and @(Get-ChildItem -LiteralPath $base -Force).Count){throw 'Для нового сервера выберите пустую папку. Прежние файлы сохраняются отдельно'}
    $disk=Join-Path $env:LOCALAPPDATA 'RemoteDisk'
    # Stop all old owners before archiving state. Never delete or move project data.
    Suspend-WizardDisk $Root $Bundle
    $archive=Join-Path $disk ('previous-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($archive)
    foreach($item in @('state','channel','selection.json','profile.txt','server.txt','base.txt')){
        $path=Join-Path $disk $item;if(Test-Path -LiteralPath $path){Move-Item -LiteralPath $path -Destination (Join-Path $archive $item)}
    }
    Update-MigrationConfig $Root {param($config) $config.wizard.PSObject.Properties.Remove('diskPreviousProfile');$config.wizard.PSObject.Properties.Remove('diskKeepPrevious')}
}
