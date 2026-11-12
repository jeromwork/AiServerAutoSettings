#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'build/Wizard.Common.ps1')
$env:LOCALAPPDATA=$TestHome
$root=Join-Path $TestHome 'RemoteAgents';[void][IO.Directory]::CreateDirectory($root)
Write-TransportJson (Join-Path $root 'config.json') @{schema=1;version=1}
$childFile=Join-Path $TestHome 'child.ps1'
$code=@'
param($Repo,$Root,$Action,$Gate)
$ErrorActionPreference='Stop'
. (Join-Path $Repo 'build/Wizard.Common.ps1')
$script:WizardProgressFile=Join-Path $Root ($Action+'.jsonl')
[IO.File]::WriteAllText((Join-Path $Root ($Action+'.ready')),'ready')
$watch=[Diagnostics.Stopwatch]::StartNew()
while(-not (Test-Path $Gate)){if($watch.Elapsed.TotalSeconds -gt 20){throw 'gate timeout'};Start-Sleep -Milliseconds 20}
Write-SetupLog $Root ('wizard.'+$Action+'.start')
Invoke-WizardAction $Root $Action ([pscustomobject]@{}) {
    Write-SetupLog $Root ('wizard.'+$Action+'.body')
    $begin=[DateTime]::UtcNow.Ticks
    Start-Sleep -Milliseconds 900
    Update-LauncherConfig $Root {param($c) $c|Add-Member -Force $Action $true}
    Write-TransportJson (Join-Path $Root ($Action+'.result')) @{begin=$begin;end=[DateTime]::UtcNow.Ticks}
}
'@
# The child script boundary deliberately uses CRLF.
[IO.File]::WriteAllText($childFile,($code.Replace("`r",'').Replace("`n","`r`n")),(New-Object Text.UTF8Encoding($true)))
$count=0
function Assert($Value,$Text){if(-not $Value){throw $Text};$script:count++}
function Run-Group($Actions,$Id){
    $gate=Join-Path $root ('gate-'+$Id);$children=@()
    try{
        foreach($action in $Actions){
            $si=New-Object Diagnostics.ProcessStartInfo
            $si.FileName=Get-TransportPowerShell
            $si.Arguments=((@('-NoProfile','-NonInteractive','-File',$childFile,$repo,$root,$action,$gate)|ForEach-Object {Quote-Disk $_}) -join ' ')
            $si.UseShellExecute=$false;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
            $p=New-Object Diagnostics.Process;$p.StartInfo=$si;[void]$p.Start()
            $children+=@{process=$p;out=$p.StandardOutput.ReadToEndAsync();err=$p.StandardError.ReadToEndAsync()}
        }
        $watch=[Diagnostics.Stopwatch]::StartNew()
        while(@($Actions|Where-Object {-not (Test-Path (Join-Path $root ($_+'.ready')))}).Count){if($watch.Elapsed.TotalSeconds -gt 20){throw 'children did not reach barrier'};Start-Sleep -Milliseconds 20}
        [IO.File]::WriteAllText($gate,'go')
        foreach($c in $children){Assert ($c.process.WaitForExit(15000)) 'child timed out';Assert ($c.process.ExitCode -eq 0) ('child failed: '+$c.err.GetAwaiter().GetResult())}
        return @($Actions|ForEach-Object {Read-TransportJson (Join-Path $root ($_+'.result'))})
    }finally{foreach($c in $children){if(-not $c.process.HasExited){$c.process.Kill()};$c.process.Dispose()}}
}
$rows=Run-Group @('Connection','Bridge','Account','Disk','Vpn') 'independent'
$latestStart=($rows|Measure-Object -Property begin -Maximum).Maximum
$earliestEnd=($rows|Measure-Object -Property end -Minimum).Minimum
Assert ($latestStart -lt $earliestEnd) 'all five production resource locks must overlap across processes'
$rows=Run-Group @('Proxy','Lan') 'network'
Assert ($rows[0].end -le $rows[1].begin -or $rows[1].end -le $rows[0].begin) 'Proxy and Lan must serialize across processes'
foreach($action in @('Connection','Bridge','Account','Disk','Vpn','Proxy','Lan')){
    Assert ((Read-TransportJson (Join-Path $root 'config.json')).$action) 'short config lock must preserve every parallel edit'
    $line=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $root ($action+'.jsonl'))))
    Assert ($line.text -match ('^timing '+$action+' [0-9]+$')) 'elapsed time in ProgressFile'
}
$script:WizardProgressFile=Join-Path $root 'failed.jsonl'
try{Invoke-WizardAction $root 'Account' $null {throw 'fixture'}}catch{}
Assert ((ConvertFrom-Json ([IO.File]::ReadAllText($script:WizardProgressFile))).text -match '^timing Account [0-9]+$') 'failed stage also records elapsed time'
Write-Output ('OK: '+$count+' resource lock/timing/CRLF checks; five actions overlap, Proxy/Lan serialize (real PowerShell children, work simulated)')
