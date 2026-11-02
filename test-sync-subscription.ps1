$ErrorActionPreference='Stop'
. "$PSScriptRoot\Sync.Workspace.ps1"
. "$PSScriptRoot\Sync.Orchestrator.ps1"
    $script:transferAttempts=0
    $retryTransport={param($request)$script:transferAttempts++;[pscustomobject]@{exitCode=$(if($script:transferAttempts -eq 1){255}else{0});stdout='';stderr=''}}
    Invoke-SyncTransport $retryTransport @{action='upload';stage='fixture'}|Out-Null
    if($script:transferAttempts -ne 2){throw 'Transient upload was not retried once'}
    $script:transferAttempts=0;$deniedReplay=$false
    try{Invoke-SyncTransport $retryTransport @{action='exec';stage='fixture'}|Out-Null}catch{$deniedReplay=$true}
    if(!$deniedReplay -or $script:transferAttempts -ne 1){throw 'Possibly completed executable command was replayed'}
function Assert($Value,$Message){if(!$Value){throw $Message}}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('ra-attach-'+[guid]::NewGuid().ToString('N'))
try {
    $project=[pscustomobject]@{projectId='p-shared';scopeMode='folder';allowedRoots=@('.');serverPath='/home/remoteagents/work/projects/p-shared'}
    $a=New-RemoteSyncSubscription $fixture p-shared home $project
    $b=New-RemoteSyncSubscription $fixture p-shared laptop $project
    Assert ($a.replicaPath -ne $b.replicaPath) 'Hosts shared a replica'
    $again=New-RemoteSyncSubscription $fixture p-shared laptop $project
    Assert ($again.replicaPath -ceq $b.replicaPath -and @(Get-RemoteSyncProjects $fixture).Count -eq 2) 'Reattach duplicated bindings'
    $denied=$false;try{Export-RemoteSyncSeed $fixture p-shared laptop|Out-Null}catch{$denied=$true}
    Assert $denied 'Subscription exported seed'
    $candidate=Get-RemoteSyncProjectCandidate $b.sourcePath -DataDir $fixture -HostId laptop
    Assert ($candidate.kind -eq 'subscription') 'Subscription mistaken for local seed'
    $candidate.selected=$false;Save-RemoteSyncSelection $fixture laptop @($candidate)|Out-Null
    New-RemoteSyncSubscription $fixture p-shared laptop $project|Out-Null
    Assert ((Get-RemoteSyncSelection $fixture laptop).projects[0].selected) 'Reattach failed to reenable subscription'
    # Orchestrator fixture stops before any binary/network. An existing project
    # must attach; an absent shared project must never seed from a local copy.
    $script:requests=New-Object 'Collections.Generic.List[object]'
    $script:probe='existing'
    $transport={param($r)
        $script:requests.Add($r)
        $output=''
        if($r.ContainsKey('command') -and $r.command -like '*echo configured*'){$output=$script:probe}
        if($r.ContainsKey('command') -and $r.command -like '*server-sync.py attach*'){$output=@{ok=$true;projectId='p-shared';hostId='laptop';manifest=@{projectId='p-shared';hostId='laptop';scopeMode='folder';allowedRoots=@('.');files=@()}}|ConvertTo-Json -Depth 5 -Compress}
        if($r.ContainsKey('command') -and $r.command -like '*server-install-sync.sh*'){throw 'fixture stop before binary install'}
        [pscustomobject]@{exitCode=0;stdout=$output;stderr=''}
    }
    try{Connect-RemoteSyncProject $fixture p-shared laptop $transport {throw 'not reached'}|Out-Null}catch{}
    Assert (@($script:requests|Where-Object{$_.ContainsKey('command') -and $_.command -like '*server-sync.py attach*'}).Count -eq 1) 'Attach route not used'
    Assert (@($script:requests|Where-Object{$_.action -eq 'upload' -and $_.localPath -like '*seed*'}).Count -eq 0) 'Attach uploaded seed'
    $script:probe='empty';$script:requests.Clear()
    try{Connect-RemoteSyncProject $fixture p-shared laptop $transport {throw 'not reached'}|Out-Null}catch{}
    Assert (@($script:requests|Where-Object{$_.ContainsKey('command') -and $_.command -like '*server-sync.py seed*' -or $_.ContainsKey('command') -and $_.command -like '*server-sync.py attach*'}).Count -eq 0) 'Missing shared project was silently seeded/attached'
    'PASS: two host subscriptions, repeat/re-enable, missing project denial, no seed export/upload, receive-only selection'
}finally{
    $resolved=[IO.Path]::GetFullPath($fixture);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(!$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
