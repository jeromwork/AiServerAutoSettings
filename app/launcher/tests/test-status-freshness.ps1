#requires -Version 5.1
# Offline regression: real status parsing with an explicit clock, no waits or network.
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'build/Setup.Common.ps1')
$count=0
function Assert($Value,[string]$Name){if(-not $Value){throw ('FAIL: '+$Name)};$script:count++}
$root=Join-Path ([IO.Path]::GetTempPath()) ('status-freshness-'+[Guid]::NewGuid().ToString('N'))
$now=[DateTime]::SpecifyKind([DateTime]::Parse('2026-11-21T12:00:00',[Globalization.CultureInfo]::InvariantCulture),[DateTimeKind]::Utc)
try{
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'status'))
    foreach($name in @('transport','vpn','disk','bridge')){
        $file=Join-Path $root ('status/'+$name+'.json')
        Assert (-not (Test-StatusFresh $root $name $now)) ($name+': missing status is not fresh')
        foreach($age in @(0,4,5,6,14,15,16,30,31,-1,-5,-6)){
            $status=@{ok=$true;updatedAt=$now.AddSeconds(-$age).ToString('o')}
            [IO.File]::WriteAllText($file,(ConvertTo-Json $status -Compress))
            $expected=if($name -in @('transport','vpn')){$age -ge 0 -and $age -le 15}else{$age -ge -5 -and $age -le 30}
            Assert ((Test-StatusFresh $root $name $now) -eq $expected) ($name+': freshness at fake age '+$age)
        }
        [IO.File]::WriteAllText($file,(ConvertTo-Json @{ok=$false;updatedAt=$now.ToString('o')} -Compress))
        Assert (-not (Test-StatusFresh $root $name $now)) ($name+': recent failure cannot prove readiness')
        [IO.File]::WriteAllText($file,(ConvertTo-Json @{ok=$true;configError='bad config';updatedAt=$now.ToString('o')} -Compress))
        Assert ((Test-StatusFresh $root $name $now) -eq ($name -ne 'transport')) ($name+': transport-only config error rule is preserved')
    }
    Write-Output ('PASS: setup status freshness ('+$count+' checks, fake clock; transport/vpn 15 s, other components unchanged)')
}finally{
    if([IO.Directory]::Exists($root)){[IO.Directory]::Delete($root,$true)}
}
