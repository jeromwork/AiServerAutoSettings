#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName='List')]
param([Alias('Home')][string]$TransportHome=(Join-Path $env:LOCALAPPDATA 'RemoteAgents'),
    [Parameter(ParameterSetName='List')][switch]$List,
    [Parameter(Mandatory=$true,ParameterSetName='Entry')][string]$AddEntry,
    [Parameter(Mandatory=$true,ParameterSetName='Relay')][string]$AddRelay,
    [Parameter(Mandatory=$true,ParameterSetName='Hop')][string]$AddHop,
    [Parameter(Mandatory=$true,ParameterSetName='Cdn')][string]$AddCdn,
    [Parameter(Mandatory=$true,ParameterSetName='Remove')][string]$Remove,
    [Parameter(Mandatory=$true,ParameterSetName='Enable')][string]$Enable,
    [Parameter(Mandatory=$true,ParameterSetName='Disable')][string]$Disable,
    [Parameter(Mandatory=$true,ParameterSetName='Entry')][Parameter(Mandatory=$true,ParameterSetName='Hop')][string]$Ssh,
    [Parameter(Mandatory=$true,ParameterSetName='Relay')][Alias('Host')][string]$RelayHost,
    [Parameter(Mandatory=$true,ParameterSetName='Relay')][ValidateRange(1,65535)][int]$Port,
    [Parameter(Mandatory=$true,ParameterSetName='Cdn')][string]$Domain,
    [Parameter(Mandatory=$true,ParameterSetName='Cdn')][string]$Entry,
    [Parameter(ParameterSetName='Cdn')][string]$Path,
    [Parameter(ParameterSetName='Entry')][string[]]$Kinds=@())
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
# Межпроцессная блокировка предотвращает потерю двух одновременных команд трея.
$root=(Get-TransportHome $TransportHome);$mutex=New-Object Threading.Mutex($false,('Global\RemoteAgentsConfig-'+(Get-TransportFingerprint 'config' $root.ToLowerInvariant())));$locked=$false
try{
    try{$locked=$mutex.WaitOne(5000)}catch [Threading.AbandonedMutexException]{$locked=$true};if(-not $locked){throw 'Конфиг занят'}
    $file=Join-Path $root 'config.json';$config=Read-TransportJson $file;$t=$config.transport;if(-not $t){throw 'Нет transport'}
    $groups=@('entries','relays','hops','cdn');foreach($group in $groups){if(-not $t.PSObject.Properties[$group]){$t|Add-Member $group @()}}
    if(-not $t.PSObject.Properties['disabledTags']){$t|Add-Member disabledTags @()}
    $action=$PSCmdlet.ParameterSetName
    if($action -eq 'List'){ConvertTo-Json -InputObject $t -Depth 30;return}
    $name=$null;$group=$null;$item=$null
    switch($action){
        'Entry' {$name=$AddEntry;$group='entries';$item=@{name=$name;ssh=$Ssh;enabled=$true};if($Kinds.Count){$item.kinds=$Kinds}}
        'Relay' {$name=$AddRelay;$group='relays';$item=@{name=$name;host=$RelayHost;port=$Port;enabled=$true}}
        'Hop' {$name=$AddHop;$group='hops';$item=@{name=$name;ssh=$Ssh;enabled=$true}}
        'Cdn' {$name=$AddCdn;$group='cdn';$item=@{name=$name;domain=$Domain;entry=$Entry;enabled=$true};if($Path){$item.path=$Path}}
    }
    if($name){
        Assert-TransportName $name
        foreach($g in $groups){if(@($t.$g|Where-Object {$_.name -eq $name}).Count){throw 'Имя уже существует'}}
        $t.$group=@($t.$group)+@([pscustomobject]$item)
    }elseif($action -eq 'Remove'){
        $found=$false
        if(@($t.cdn|Where-Object {$_.entry -eq $Remove}).Count){throw 'Сначала удалите CDN этого узла'}
        foreach($g in $groups){if(@($t.$g|Where-Object {$_.name -eq $Remove}).Count){$found=$true};$t.$g=@($t.$g|Where-Object {$_.name -ne $Remove})}
        if(-not $found){throw 'Имя не найдено'}
    }else{
        $target=$Disable;$enabled=$false;if($action -eq 'Enable'){$target=$Enable;$enabled=$true}
        $found=$false
        foreach($g in $groups){foreach($node in @($t.$g|Where-Object {$_.name -eq $target})){$node|Add-Member -Force enabled $enabled;$found=$true}}
        if(-not $found){Assert-TransportTag $target;$t.disabledTags=@($t.disabledTags|Where-Object {$_ -ne $target});if(-not $enabled){$t.disabledTags+=@($target)}}
    }
    Assert-TransportLists $t;Write-TransportJson $file $config
    ConvertTo-Json -InputObject @{ok=$true;action=$action} -Compress
}finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
