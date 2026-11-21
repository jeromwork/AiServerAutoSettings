#requires -Version 5.1
# Стенд замера утечки демона транспорта (T0, фаза А). Только числа: КБ удержанной памяти на вызов после полного GC.
# Без сети, без таймеров (счёт итераций); пишет только во временный каталог, из home — только читает.
# Запуск: powershell.exe -NoProfile -File Measure-TransportLeak.ps1 [-TransportHome <home>] [-Iterations 200] [-DryRun] [-Only revision,status-publish] [-ApartmentMatrix]
[CmdletBinding()]
param([Alias('Home')][string]$TransportHome='',[int]$Iterations=0,[switch]$DryRun,[string[]]$Only=@(),[switch]$ApartmentMatrix,[double]$ThresholdKb=20)
$ErrorActionPreference='Stop'
$transportDir=Split-Path $PSScriptRoot -Parent
. (Join-Path $transportDir 'Transport.Common.ps1')
. (Join-Path $transportDir 'Transport.Decide.ps1')
$allCases=@('revision','revision-cached','decision','status-publish-same','status-publish-changing','metered','network')
if($Iterations -le 0){$Iterations=$(if($DryRun){20}else{200})}
$work=Join-Path ([IO.Path]::GetTempPath()) ('ra-leak-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
function Get-PrivateBytes { $p=[Diagnostics.Process]::GetCurrentProcess();try{[long]$p.PrivateMemorySize64}finally{$p.Dispose()} }
function Invoke-FullGc { [GC]::Collect();[GC]::WaitForPendingFinalizers();[GC]::Collect() }
function Measure-Case([string]$Name,[scriptblock]$Body,[int]$Count) {
    for($i=0;$i -lt 5;$i++){$null=& $Body}
    Invoke-FullGc;$m0=[GC]::GetTotalMemory($true);$p0=Get-PrivateBytes
    for($i=0;$i -lt $Count;$i++){$null=& $Body}
    Invoke-FullGc;$m1=[GC]::GetTotalMemory($true);$p1=Get-PrivateBytes
    $managed=[Math]::Round(($m1-$m0)/1024/$Count,2);$private=[Math]::Round(($p1-$p0)/1024/$Count,2)
    [pscustomobject]@{function=$Name;managedKbPerCall=$managed;privateKbPerCall=$private;leaks=[bool]($managed -gt $ThresholdKb)}
}
function New-SyntheticHome([string]$Dir) {
    # Выдуманные данные нужного размера: содержимое реального конфига не используется.
    [void][IO.Directory]::CreateDirectory((Join-Path $Dir 'secrets/entries'))
    $blob=('x'*20000)
    [IO.File]::WriteAllText((Join-Path $Dir 'profile.json'),'{"synthetic":true}')
    [IO.File]::WriteAllText((Join-Path $Dir 'channel.json'),'{"synthetic":true}')
    for($i=1;$i -le 5;$i++){[IO.File]::WriteAllText((Join-Path $Dir ('secrets/entries/e'+$i+'.json')),('{"name":"e'+$i+'","blob":"'+$blob+'"}'))}
    $cfg=[ordered]@{transport=[ordered]@{profilePath=(Join-Path $Dir 'profile.json');channelPath=(Join-Path $Dir 'channel.json')}}
    [IO.File]::WriteAllText((Join-Path $Dir 'config.json'),(ConvertTo-Json -InputObject $cfg -Depth 5))
}
try{
    if($DryRun -or -not $TransportHome){$testHome=Join-Path $work 'home';New-SyntheticHome $testHome;$source='synthetic'}
    else{$testHome=Get-TransportHome $TransportHome;if(-not [IO.File]::Exists((Join-Path $testHome 'config.json'))){throw 'В home нет config.json'};$source='real-readonly'}
    $selected=@($allCases);if($Only.Count){$selected=@($allCases|Where-Object {$_ -in $Only})}
    $apartment=[string][Threading.Thread]::CurrentThread.GetApartmentState()
    if($ApartmentMatrix -and -not $DryRun){
        # STA и MTA отдельными процессами: гипотеза о WinRT на STA-нити. Только функции с WinRT.
        $hostPath=(Get-Process -Id $PID).Path
        foreach($mode in @('-STA','-MTA')){
            try{& $hostPath -NoProfile $mode -File $PSCommandPath -TransportHome $testHome -Iterations $Iterations -Only metered,network}catch{'apartment '+$mode+': не запустился'}
        }
        return
    }
    # Состояние для функций демона (извлекаются из Daemon.ps1 по AST: сам скрипт демона не запускается).
    $daemonAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $transportDir 'Transport.Daemon.ps1'),[ref]$null,[ref]$null)
    foreach($fn in @($daemonAst.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('Publish-TransportStatus','Get-DaemonTime')},$true))){. ([scriptblock]::Create($fn.Extent.Text))}
    $root=Join-Path $work 'status-home';[void][IO.Directory]::CreateDirectory($root)
    $bigDiag=[pscustomobject]@{candidate='x';reason='timeout';portConflict=$null;exitCode=1;stderr=('e'*900)}
    $rows=@(1..6|ForEach-Object {[pscustomobject]@{tag=('p'+$_);title=('Путь '+$_);enabled=$true;state='ok';kbps=100.5;latencyMs=(50+$_);priority=$_;checkedAt='2000-01-01T00:00:00Z';diagnostic=$bigDiag}})
    $paths=[pscustomobject]@{Outbounds=@();Candidates=@()};$active='p1';$confirmed=$true;$engine=$null;$network=$null;$reloadError=$null;$portConflict=$null;$stopping=$false;$exitCode=0
    $settings=$null;$errorText=$null;$verdict=$null;$decision=$null;$initialRound=$false;$pin=[pscustomobject]@{mode='auto';tag=$null};$metered=$null;$revision='r';$retryAt=[DateTime]::UtcNow
    $daemonStarted=[DateTime]::Now;$script:engineAttempted=$true;$script:checkingSince=$null;$script:lastStatus=[DateTime]::MinValue;$script:lastStatusKey=$null;$script:lastStatusWriteMs=[long]0;$StatusHeartbeatMs=5000
    $revState=@{};$decRows=@((@{tag='a';state='ok';enabled=$true;latencyMs=100;failures=0;maxGapMs=0}),(@{tag='b';state='remembered';enabled=$true;latencyMs=120;failures=0;maxGapMs=0}))
    $script:decState=New-TransportDecisionState 0 'a';$script:decNow=[long]0;$script:statusCounter=0
    $bodies=@{
        'revision'={Get-TransportRevision $testHome}
        'revision-cached'={Get-TransportRevisionCached $testHome $revState}
        'decision'={$script:decNow+=300;$r=Invoke-TransportDecision -State $script:decState -Candidates $decRows -Now $script:decNow -Events @() -CurrentTag 'a';$script:decState=$r.state}
        'status-publish-same'={Publish-TransportStatus}
        'status-publish-changing'={$script:statusCounter++;$errorText='n'+$script:statusCounter;Publish-TransportStatus}
        'metered'={Get-TransportMetered ([pscustomobject]@{metered='auto'})}
        'network'={Get-TransportNetwork}
    }
    $results=@()
    foreach($name in $selected){$results+=Measure-Case $name $bodies[$name] $Iterations}
    'stand source='+$source+' apartment='+$apartment+' iterations='+$Iterations+' thresholdKb='+$ThresholdKb
    'connections-reader: не измеряется стендом (нужен живой sing-box и /connections)'
    ($results|Format-Table function,managedKbPerCall,privateKbPerCall,leaks -AutoSize|Out-String).TrimEnd()
}finally{
    try{[IO.Directory]::Delete($work,$true)}catch{}
}
