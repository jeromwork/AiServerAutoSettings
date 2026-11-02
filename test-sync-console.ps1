$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Select-RemoteAgentsProjects.ps1')
function Assert($Value,$Message){if(!$Value){throw $Message}}
$script:lines=New-Object 'Collections.Generic.List[string]'
function Write-Host {param($Object);$script:lines.Add([string]$Object)}
$script:saves=0;$script:windowCalls=0;$script:quickCalls=0
function New-RemoteSyncProjectSelectionForm {$script:windowCalls++;throw 'Unexpected window in default console flow'}
function Initialize-RemoteSyncConsoleMouse {return $false}
function Get-RemoteSyncSelection {param($DataDir,$HostId);[pscustomobject]@{projects=@()}}
function Save-RemoteSyncSelection {param($DataDir,$HostId,$Candidates);$script:saves++;[pscustomobject]@{projects=@($Candidates)}}
$script:fixtures=@(1..12|ForEach-Object{
    [pscustomobject]@{sourcePath=('C:\fixture\repo-'+('{0:d2}' -f $_));kind='git';selected=$false;inventory=[pscustomobject]@{lastSourceWriteUtc=([datetime]'2026-01-01Z').AddDays(-$_).ToString('o');complete=$true}}
})
function Find-RemoteSyncQuickRepositories {
    param($DataDir,$HostId)
    $script:quickCalls++
    [pscustomobject]@{candidates=$script:fixtures;complete=$true;reasons=@()}
}
$script:answers=New-Object 'Collections.Generic.Queue[string]'
function Read-Host {param($Prompt);if(!$script:answers.Count){throw 'Unexpected prompt'};$script:answers.Dequeue()}
foreach($answer in @('','N','11,12','P','1','99999999999999999999','')){$script:answers.Enqueue($answer)}
$result=Show-RemoteSyncProjectSelection -DataDir 'C:\fixture\state' -HostId fixture
Assert (!$result.cancelled -and $script:saves -eq 1 -and $script:windowCalls -eq 0) 'Default flow did not stay in console with one explicit save'
Assert ($script:quickCalls -eq 2) 'Empty initial list did not search automatically, or Enter did not repeat search'
Assert ((@($result.selection.projects|Where-Object selected|ForEach-Object{$_.sourcePath}) -join '|') -ceq 'C:\fixture\repo-01|C:\fixture\repo-11|C:\fixture\repo-12') 'Paging/toggle selection mismatch'
Assert (($script:lines -join "`n") -match 'страница 2/2' -and ($script:lines -join "`n") -match 'Git \| 31.12.2025' -and ($script:lines -join "`n") -match 'Введите номера') 'Compact dates/pages/invalid input feedback missing'
Assert (($script:lines -join "`n") -match 'Подключить выбранные \(3\): repo-01, repo-11, repo-12') 'Selected names did not update in action footer'
Assert (($script:lines -join "`n") -match 'S / Enter — Подключить выбранные \(3\)') 'Selected-count Enter action not visible'
$script:answers.Enqueue('0');$again=Show-RemoteSyncProjectSelection -DataDir 'C:\fixture\state' -HostId fixture
Assert ($again.cancelled -and $script:saves -eq 1 -and $script:windowCalls -eq 0) 'Cancel created window or saved selection'
& {
    $script:emptyCalls=0
    function Find-RemoteSyncQuickRepositories {param($DataDir,$HostId);$script:emptyCalls++;[pscustomobject]@{candidates=@();complete=$true;reasons=@();visitedDirectories=3}}
    $script:answers.Enqueue('');$script:answers.Enqueue('0')
    $empty=Show-RemoteSyncProjectSelection -DataDir 'C:\fixture\state' -HostId fixture
    Assert ($empty.cancelled -and $script:emptyCalls -eq 2 -and $script:saves -eq 1) 'Empty search/Enter repeat/cancel created a binding or skipped search'
}
$beforeSearches=$script:quickCalls;$beforeSaves=$script:saves
$rows=@($script:fixtures|ForEach-Object{$copy=$_.PSObject.Copy();$copy.selected=$false;$copy});$rows[0].selected=$true
$script:answers.Enqueue('Q');$script:answers.Enqueue('0')
$rescan=Show-RemoteSyncConsoleSelection -Candidates $rows -DataDir 'C:\fixture\state' -HostId fixture
Assert ($rescan.cancelled -and $script:quickCalls -eq ($beforeSearches+1) -and $script:saves -eq $beforeSaves) 'Explicit Q with selected rows saved instead of searching'
$rows=@($script:fixtures|ForEach-Object{$copy=$_.PSObject.Copy();$copy.selected=$false;$copy})
$beforeLines=$script:lines.Count
foreach($answer in @('1 3','V','1','V','0')){$script:answers.Enqueue($answer)}
$view=Show-RemoteSyncConsoleSelection -Candidates $rows -DataDir 'C:\fixture\state' -HostId fixture
Assert ($view.cancelled -and $rows[2].selected -and !$rows[0].selected) 'Selected-only view changed global row numbers or saved on cancel'
Assert (($script:lines.GetRange($beforeLines,$script:lines.Count-$beforeLines) -join "`n") -match 'Показаны только отмеченные') 'Selected-only view missing'
foreach($separator in @('1,2','1.2','1 2','1, 2.','1;2','01 1 2')){
    $rows=@($script:fixtures|ForEach-Object{$copy=$_.PSObject.Copy();$copy.selected=$false;$copy})
    $script:answers.Enqueue($separator);$script:answers.Enqueue('S')
    $selection=Show-RemoteSyncConsoleSelection -Candidates $rows -DataDir 'C:\fixture\state' -HostId fixture
    Assert (@($selection.selection.projects|Where-Object selected).Count -eq 2) ('Separator not accepted: '+$separator)
}
& {
    function ConvertFrom-RemoteSyncProjectPaths {param($Text);Assert ($Text -ceq 'C:\fixture\group') 'Folder search prompt lost exact path';$Text}
    function Find-RemoteSyncQuickRepositories {
        param($DataDir,$HostId,$RootPaths,$MaxSeconds,$MaxDepth)
        Assert ($RootPaths[0] -ceq 'C:\fixture\group' -and $MaxDepth -eq 8 -and $MaxSeconds -eq 30) 'Folder search scope not forwarded'
        [pscustomobject]@{candidates=@();complete=$true;reasons=@()}
    }
    $script:answers.Enqueue('F');$script:answers.Enqueue('C:\fixture\group');$script:answers.Enqueue('0')
    $cancelled=Show-RemoteSyncConsoleSelection -Candidates $script:fixtures -DataDir 'C:\fixture\state' -HostId fixture
    Assert $cancelled.cancelled 'Scoped folder search changed cancellation'
}
& {
    $script:loadedPaths=New-Object 'Collections.Generic.List[string]'
    function Get-RemoteSyncSelection {param($DataDir,$HostId);[pscustomobject]@{projects=@(
        [pscustomobject]@{projectId='p-one';sourcePath='C:\fixture\saved';scopeMode='git';selected=$true},
        [pscustomobject]@{projectId='p-skip';sourcePath='C:\fixture\old-discovery';scopeMode='git';selected=$false})}}
    function Get-SyncStatePath {param($DataDir,$ProjectId,$HostId);[IO.Path]::Combine($DataDir,$ProjectId,$HostId)}
    function Get-RemoteSyncProjectCandidate {param($SourcePath,$DataDir,$HostId,$MaxSeconds,$MetadataMaxSeconds,$MetadataMaxFiles,$MetadataMaxDirectories);$script:loadedPaths.Add($SourcePath);$copy=$script:fixtures[0].PSObject.Copy();$copy.sourcePath=$SourcePath;$copy.selected=$true;$copy}
    $script:answers.Enqueue('0');$cancelled=Show-RemoteSyncProjectSelection -DataDir 'C:\fixture\state' -HostId fixture
    Assert ($cancelled.cancelled -and $script:loadedPaths.Count -eq 1 -and $script:loadedPaths[0] -ceq 'C:\fixture\saved') 'Adding later rescanned unbound old discovery rows'
}
Microsoft.PowerShell.Utility\Write-Output 'PASS: PS5.1 default console (including STA), quick search, dates, ten-row paging, explicit toggles/save, overflow rejection and cancel without window'
