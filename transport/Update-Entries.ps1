#requires -Version 5.1
[CmdletBinding()]
param([Alias('Home')][string]$TransportHome=(Join-Path $env:LOCALAPPDATA 'RemoteAgents'))
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
try{
    $config=Read-TransportJson (Join-Path $TransportHome 'config.json');$t=$config.transport
    if(-not $t){throw 'Нет transport'}
    $exe='ssh.exe'
    if($t.profilePath){$p=Read-TransportJson $t.profilePath;$exe=$p.sshExecutable}
    $count=0
    foreach($entry in @($t.entries)){
        if($null -eq $entry -or -not (Test-TransportEnabled $entry)){continue};Assert-TransportName $entry.name
        if(-not (Get-TransportValue $entry 'ssh' $entry.alias) -or (Get-TransportValue $entry 'ssh' $entry.alias) -match '^[\-]|[\r\n]'){throw 'Неверный SSH-алиас'}
        $a=@('-n','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','-o','StrictHostKeyChecking=yes')
        if($entry.configPath){$a+=@('-F',[string]$entry.configPath)}
        # Единственная удалённая команда, без пользовательской подстановки; LF в общем runner.
        $text=Invoke-TransportText $exe ($a+@([string](Get-TransportValue $entry 'ssh' $entry.alias),'cat /opt/rd-entry/client.json'))
        $data=ConvertFrom-Json (Convert-TransportLF $text)
        foreach($field in @('server','sni','cover','ports','secrets')){if(-not $data.$field){throw 'Неполный client.json'}}
        Write-TransportJson (Join-Path $TransportHome ('secrets/entries/'+$entry.name+'.json')) $data -Private;$count++
    }
    Write-Output ('Обновлено узлов: '+$count+'. Секреты сохранены локально.')
}catch{Write-Error 'Не удалось обновить узлы. Проверьте SSH-алиасы, known_hosts и формат client.json; содержимое ошибки скрыто.' -ErrorAction Continue;exit 1}
