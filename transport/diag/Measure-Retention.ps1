# Общий замер удержанной памяти на вызов (стенд Measure-TransportLeak.ps1 и тест test-transport-leak.ps1). Без таймеров.
function Get-PrivateBytes { $p=[Diagnostics.Process]::GetCurrentProcess();try{[long]$p.PrivateMemorySize64}finally{$p.Dispose()} }
function Invoke-FullGc { [GC]::Collect();[GC]::WaitForPendingFinalizers();[GC]::Collect() }
function Measure-Case([string]$Name,[scriptblock]$Body,[int]$Count,[double]$ThresholdKb=20) {
    for($i=0;$i -lt 5;$i++){$null=& $Body}
    Invoke-FullGc;$m0=[GC]::GetTotalMemory($true);$p0=Get-PrivateBytes
    for($i=0;$i -lt $Count;$i++){$null=& $Body}
    Invoke-FullGc;$m1=[GC]::GetTotalMemory($true);$p1=Get-PrivateBytes
    $managed=[Math]::Round(($m1-$m0)/1024/$Count,2);$private=[Math]::Round(($p1-$p0)/1024/$Count,2)
    [pscustomobject]@{function=$Name;managedKbPerCall=$managed;privateKbPerCall=$private;leaks=[bool]($managed -gt $ThresholdKb)}
}
