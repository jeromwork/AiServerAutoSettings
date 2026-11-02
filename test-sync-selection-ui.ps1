[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA'){throw 'Run with powershell.exe -STA -File test-sync-selection-ui.ps1'}
. (Join-Path $PSScriptRoot 'Select-RemoteAgentsProjects.ps1')
$script:saves=0
function Save-RemoteSyncSelection {param($DataDir,$HostId,$Candidates) $script:saves++;return [pscustomobject]@{projects=@($Candidates)}}
function Assert-Ui($Condition,[string]$Message){if(!$Condition){throw $Message}}
$metadata={param([string]$Date,[long]$Bytes,[bool]$Complete=$true) [pscustomobject]@{lastSourceWriteUtc=$Date;bytes=$Bytes;fileCount=3;complete=$Complete;excludedCount=4;largeFileCount=0}}
$candidates=@(
    [pscustomobject]@{sourcePath='C:\fixture\old saved';kind='git';selected=$true;inventory=(& $metadata '2020-01-01T00:00:00Z' 1234)},
    [pscustomobject]@{sourcePath='C:\fixture\new folder';kind='folder';selected=$false;inventory=(& $metadata '2026-10-31T00:00:00Z' 5678 $false)},
    [pscustomobject]@{sourcePath='C:\fixture\worktree';kind='worktree';selected=$false;inventory=(& $metadata '2025-01-01T00:00:00Z' 9000)}
)
$script:quickCalls=0
$outcome=[pscustomobject]@{Failure=$null}
function Find-RemoteSyncQuickRepositories {
    param($DataDir,$HostId)
    $script:quickCalls++
    [pscustomobject]@{complete=$true;reasons=@();candidates=@(
        [pscustomobject]@{sourcePath='C:\fixture\old saved';kind='git';selected=$false;inventory=[pscustomobject]@{lastSourceWriteUtc='2020-01-01T00:00:00Z';bytes=1234;fileCount=1;complete=$true;excludedCount=0;largeFileCount=0}},
        [pscustomobject]@{sourcePath='C:\fixture\fresh quick';kind='git';selected=$false;inventory=[pscustomobject]@{lastSourceWriteUtc='2026-11-01T00:00:00Z';bytes=99;fileCount=1;complete=$true;excludedCount=0;largeFileCount=0}}
    )}
}
$state=New-RemoteSyncProjectSelectionForm -Candidates $candidates -DataDir 'C:\fixture\state' -HostId 'fixture'
try{
    Assert-Ui ($state.List.Items.Count -eq 3) 'Expected three candidate rows'
    Assert-Ui ($state.List.Items[0].Text -eq 'new folder') 'Newest source date must sort first'
    Assert-Ui (!$state.List.Items[0].Checked -and $state.List.Items[1].Checked -and !$state.List.Items[2].Checked) 'Only previous saved selection may be checked; worktrees must be last'
    Assert-Ui ($state.List.Items[0].SubItems[5].Text -match 'Неполная') 'Bounded inventory must show incomplete status'
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=150
    $preview=Join-Path $PSScriptRoot 'project-selection-preview.png'
    $timer.Add_Tick({
        $timer.Stop()
        try{
            $state.Quick.PerformClick();$state.Quick.PerformClick()
            Assert-Ui ($state.List.Items.Count -eq 4 -and $state.List.Items[0].Text -eq 'fresh quick') 'Quick search did not merge/sort results or duplicated rows'
            Assert-Ui (!$state.List.Items[0].Checked -and @($state.List.Items|Where-Object{$_.Checked}).Count -eq 1) 'Quick search changed saved checks or selected new repos'
            $state.Form.Refresh()
            $bitmap=New-Object Drawing.Bitmap($state.Form.Width,$state.Form.Height)
            try{$state.Form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height)));$bitmap.Save($preview,[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
        }catch{$outcome.Failure=$_}
        finally{$state.Form.DialogResult='Cancel';$state.Form.Close()}
    }.GetNewClosure())
    $timer.Start()
    try{$result=$state.Form.ShowDialog()}finally{$timer.Dispose()}
    if($outcome.Failure){throw $outcome.Failure}
    Assert-Ui ($script:saves -eq 0 -and $script:quickCalls -eq 2) 'Quick search saved bindings or failed to run'
    Assert-Ui ($result -eq 'Cancel' -and $script:saves -eq 0) 'Cancel must not save or start transport'
}finally{$state.Form.Dispose()}
$state=New-RemoteSyncProjectSelectionForm -Candidates $candidates -DataDir 'C:\fixture\state' -HostId 'fixture'
try{
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=150
    $timer.Add_Tick({$timer.Stop();foreach($item in $state.List.Items){$item.Checked=($item.Text -eq 'worktree')};$state.Save.PerformClick()}.GetNewClosure())
    $timer.Start()
    try{$result=$state.Form.ShowDialog()}finally{$timer.Dispose()}
    Assert-Ui ($result -eq 'OK' -and $script:saves -eq 1) 'Save must run exactly once'
    Assert-Ui (@($state.Result.projects|Where-Object{$_.selected}).Count -eq 1) 'Explicit checkbox selection must control saved projects'
}finally{$state.Form.Dispose()}
$script:answers=New-Object 'Collections.Generic.Queue[string]';$script:answers.Enqueue('Q');$script:answers.Enqueue('0')
function Initialize-RemoteSyncConsoleMouse {return $false}
function Read-Host {param($Prompt) return $script:answers.Dequeue()}
$console=Show-RemoteSyncConsoleSelection -Candidates $candidates -DataDir 'C:\fixture\state' -HostId 'fixture'
Assert-Ui ($console.cancelled -and $script:saves -eq 1) 'Console cancel must not save'
Assert-Ui ($script:quickCalls -eq 3) 'Console quick search did not run'
Write-Output 'PASS: PS5.1 WinForms quick button, duplicate-free newest-first merge, saved checks, no automatic selection/save, render and console quick search/cancel.'
