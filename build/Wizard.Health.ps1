#requires -Version 5.1
# Small portable Linux probe: one saved-route SSH call; no helper install, scans or changes.
function Get-WizardServerHealthCommand {
@'
set -eu
export LC_ALL=C
printf 'health=1\n'
df -Pk "$HOME" | awk 'END {printf "diskTotalKb=%s\ndiskUsedKb=%s\ndiskFreeKb=%s\n", $2,$3,$4}'
awk '/^MemTotal:/ {print "memoryTotalKb=" $2} /^MemAvailable:/ {print "memoryAvailableKb=" $2}' /proc/meminfo
awk '{printf "load1=%s\nload5=%s\nload15=%s\n", $1,$2,$3}' /proc/loadavg
printf 'cores=%s\n' "$(getconf _NPROCESSORS_ONLN)"
awk '{print "uptimeSec=" $1}' /proc/uptime
'@
}
function ConvertFrom-WizardServerHealth([string]$Text) {
    $fields=@{}
    foreach($line in ((Convert-TransportLF $Text) -split "`n")){
        if(-not $line.Trim()){continue}
        if($line -notmatch '^([a-zA-Z0-9]+)=(-?[0-9]+(?:\.[0-9]+)?)$' -or $fields.ContainsKey($Matches[1])){throw 'Повреждён ответ состояния сервера'}
        if($Matches[2].StartsWith('-') -and $Matches[1] -cne 'diskFreeKb'){throw 'Неверные счётчики состояния сервера'}
        $fields[$Matches[1]]=$Matches[2]
    }
    $values=@{}
    foreach($key in @('health','diskTotalKb','diskUsedKb','diskFreeKb','memoryTotalKb','memoryAvailableKb','load1','load5','load15','cores','uptimeSec')){
        $number=0.0;$style=[Globalization.NumberStyles]::AllowDecimalPoint
        if($key -eq 'diskFreeKb'){$style=$style -bor [Globalization.NumberStyles]::AllowLeadingSign}
        if(-not $fields.ContainsKey($key) -or -not [double]::TryParse($fields[$key],$style,[Globalization.CultureInfo]::InvariantCulture,[ref]$number) -or [double]::IsInfinity($number) -or ($number -lt 0 -and $key -ne 'diskFreeKb')){throw 'Неполный ответ состояния сервера'}
        if($key -notin @('load1','load5','load15','uptimeSec') -and $number -ne [math]::Truncate($number)){throw 'Неверные счётчики состояния сервера'}
        $values[$key]=$number
    }
    $values.diskFreeKb=[math]::Max(0,$values.diskFreeKb)
    if($values.health -ne 1 -or $values.diskTotalKb -le 0 -or $values.memoryTotalKb -le 0 -or $values.cores -lt 1 -or $values.diskUsedKb+$values.diskFreeKb -gt $values.diskTotalKb -or $values.memoryAvailableKb -gt $values.memoryTotalKb){throw 'Неверные счётчики состояния сервера'}
    return @{schema=1;ok=$true;updatedUtc=[DateTime]::UtcNow.ToString('o');
        disk=@{totalBytes=$values.diskTotalKb*1024;usedBytes=$values.diskUsedKb*1024;freeBytes=$values.diskFreeKb*1024};
        memory=@{totalBytes=$values.memoryTotalKb*1024;availableBytes=$values.memoryAvailableKb*1024;usedBytes=($values.memoryTotalKb-$values.memoryAvailableKb)*1024};
        load=@{one=$values.load1;five=$values.load5;fifteen=$values.load15;cores=$values.cores};uptimeSec=$values.uptimeSec}
}
function Get-WizardServerHealth([string]$Root) {
    $path=Join-Path $Root 'state/server-health.json'
    $serverId=''
    try{
        # Capture the identity and SSH profile together: an in-flight poll must
        # retain its original server even if the applied profile is replaced.
        $profile=Read-TransportJson (Find-InstallProfile $Root)
        $serverId=([string]$profile.serverAddress).Trim().ToLowerInvariant()+"`n"+(Get-TransportServerPort $profile)+"`n"+[string]$profile.login
        $text=Invoke-WizardReadOnlySsh $Root (Get-WizardServerHealthCommand) 'Проверка состояния сервера' $profile
        $result=ConvertFrom-WizardServerHealth $text
        $result.serverId=$serverId
        Write-TransportJson $path $result
        return $result
    }catch{
        Write-TransportJson $path @{schema=1;ok=$false;serverId=$serverId;updatedUtc=[DateTime]::UtcNow.ToString('o');summary='Состояние сервера не получено: проверьте связь'}
        throw
    }
}
