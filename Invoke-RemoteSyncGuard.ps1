$ErrorActionPreference='Stop'
[Console]::InputEncoding=New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
$request=$null
try{
    $text=[Console]::ReadLine()
    if(-not $text -or $text.Length -gt 8192){throw 'Invalid request'}
    $request=$text|ConvertFrom-Json
    if($request.projectId -notmatch '\A[a-z0-9][a-z0-9_-]{0,63}\z' -or $request.hostId -notmatch '\A[a-z0-9][a-z0-9_-]{0,63}\z' -or -not $request.requestId){throw 'Invalid binding'}
    . (Join-Path $PSScriptRoot 'Sync.Workspace.ps1')
    . (Join-Path $PSScriptRoot 'Sync.Runtime.ps1')
    . (Join-Path $PSScriptRoot 'Sync.Orchestrator.ps1')
    $dataDir=[IO.Path]::GetFullPath([string]$request.dataDir)
    $connection=[IO.File]::ReadAllText((Join-Path $dataDir 'ssh-transport.json'))|ConvertFrom-Json
    $root=$PSScriptRoot
    $transport={param($r)& (Join-Path $root 'Invoke-RemoteAgentsSsh.ps1') -Request $r -Connection $connection -DataDir $dataDir}.GetNewClosure()
    $barrier=Invoke-RemoteSyncBarrier -DataDir $dataDir -ProjectId $request.projectId -HostId $request.hostId -SSHTransport $transport -TimeoutSec 10
    if(-not $barrier.ready -or -not $barrier.fresh -or -not [string]::Equals([IO.Path]::GetFullPath([string]$barrier.replicaPath),[IO.Path]::GetFullPath([string]$request.replicaPath),[StringComparison]::OrdinalIgnoreCase)){throw 'Not ready'}
    $answer=@{ready=$true;fresh=$true;projectId=$request.projectId;hostId=$request.hostId;replicaPath=$barrier.replicaPath;snapshotId=$barrier.snapshotId;requestId=$request.requestId}
    [Console]::WriteLine(($answer|ConvertTo-Json -Compress))
}catch{
    [Console]::WriteLine('{"ready":false,"fresh":false,"reason":"Fresh project check failed"}')
    exit 1
}
