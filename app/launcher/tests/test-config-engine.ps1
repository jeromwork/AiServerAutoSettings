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
$overlapMs=[int](($earliestEnd-$latestStart)/10000)
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
$script:syncBody=0
Invoke-WizardAction $root 'ConfigSync' $null {$script:syncBody++}
Assert ($script:syncBody -eq 1) 'multi-resource ConfigSync invokes its body exactly once'
Update-LauncherConfig $root {param($c) $c|Add-Member -Force transport ([pscustomobject]@{marker='original'})}
$script:failProof=$true;$script:starts=0
function Start-WizardWorkingTransport($Root,$Bundle){$script:starts++}
function Wait-WizardWorkingProof($Root,$Mark){if($script:failProof){throw 'fixture proof failed'}}
$failed=$false;try{Set-WizardInitialNetwork $root $repo ([pscustomobject]@{marker='candidate'})}catch{$failed=$true}
Assert ($failed -and (Read-TransportJson (Join-Path $root 'config.json')).transport.marker -eq 'original') 'failed first working proof restores transport'
Assert ((Read-TransportJson (Join-Path $root 'config.json')).Account) 'first setup rollback preserves unrelated concurrent edits'
$script:failProof=$false
Set-WizardInitialNetwork $root $repo ([pscustomobject]@{marker='candidate'})
Assert ($script:starts -eq 2 -and (Read-TransportJson (Join-Path $root 'config.json')).transport.marker -eq 'candidate') 'first setup commits only after working proof'
Update-LauncherConfig $root {param($c) $c.transport|Add-Member -Force bootstrap $true;$c|Add-Member -Force vpn ([pscustomobject]@{enabled=$true;bootstrapTag='fixture'})}
function Test-WizardNetworkProof($Root,$Mark){$false}
$script:vpnChildren=0
function Invoke-InstallChild($Bundle,$Script,$Arguments,$TimeoutSeconds){$script:vpnChildren++}
$pending=Invoke-WizardStep $root $repo 'Vpn' ([pscustomobject]@{enabled=$false})
Assert ($pending.pending -eq 'connection' -and -not $pending.ok -and $script:vpnChildren -eq 0) 'parallel Vpn must not tear down bootstrap before Connection proof'
Assert ((Read-TransportJson (Join-Path $root 'config.json')).vpn.enabled) 'bootstrap VPN intent remains enabled while Connection starts'
Write-Output ('OK: '+$count+' resource lock/timing/CRLF checks; five-way overlap '+$overlapMs+' ms; Proxy/Lan serialize (real PowerShell children, work simulated)')
