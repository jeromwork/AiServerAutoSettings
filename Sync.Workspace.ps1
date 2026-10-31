# Windows PowerShell 5.1. No network or process is started by dot-sourcing.
Set-StrictMode -Version 2
function Get-SyncSHA256([string]$LiteralPath) {
    $stream=[IO.File]::OpenRead($LiteralPath)
    $hash=[Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-','').ToLowerInvariant() }
    finally { $hash.Dispose();$stream.Dispose() }
}
function Assert-SyncId([string]$Value) {
    if ($Value -cnotmatch '^[a-z0-9][a-z0-9_-]{0,63}$') { throw 'Invalid project/host ID' }
}
function Get-SyncStatePath($DataDir,$ProjectId,$HostId) {
    Assert-SyncId $ProjectId; Assert-SyncId $HostId
    Join-Path ([IO.Path]::GetFullPath($DataDir)) "sync\projects\$ProjectId\$HostId"
}
function Test-SyncDenied([string]$Name) {
    return $Name -match '(?i)^(\.env.*|env\.example|\.npmrc|\.pypirc|\.netrc|auth\.json|.*credential.*|.*token.*|.*secret.*|.*private.*|id_.*|\.git|\.tools|\.?ssh|\.codex|\.claude|node_modules|vendor|deps|dependencies|\.gradle|\.next|\.cache|\.stversions|\.stfolder|\.stignore|build|dist|target|obj|bin|\.dart_tool|\.nuxt|\.output|\.turbo|\.cxx|coverage|logs?|cache|caches|db|databases?|backups?|.*backup.*|.*dump.*|uploads?|storage|android-sdk|\.idea|\.vscode|local\.properties|google-services.*\.json|GoogleService-Info\.plist|config\.php)$' -or $Name -match '(?i)\.(pem|key|keystore|jks|p8|p12|pfx|sqlite3?|db|db3|bak|backup|dump|log|zip|tar|gz|exe|dll|so|bin)$'
}
function Get-SyncGitExecutable {
    [CmdletBinding()]
    param([string]$DataDir,[string]$DownloadedArchive,[switch]$ForcePortable)
    if(!$ForcePortable) {
        $cached=Get-Variable SyncGitExecutable -Scope Script -ErrorAction SilentlyContinue
        if($cached -and (Test-Path -LiteralPath $cached.Value -PathType Leaf)){
            $expected=Get-Variable SyncGitExecutableSHA256 -Scope Script -ErrorAction SilentlyContinue
            if($expected -and $expected.Value -and (Get-SyncSHA256 $cached.Value) -cne $expected.Value){throw 'Portable Git verification failed'}
            return $cached.Value
        }
        $command=Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
        $candidates=@();if($command){$candidates+=,$command.Source}
        foreach($homePath in @($env:ProgramW6432,$env:ProgramFiles,${env:ProgramFiles(x86)},(Join-Path $env:LOCALAPPDATA 'Programs'))) {
            if($homePath){$candidates+=,(Join-Path $homePath 'Git\cmd\git.exe')}
        }
        foreach($candidate in $candidates) {
            if(Test-Path -LiteralPath $candidate -PathType Leaf){$script:SyncGitExecutable=[IO.Path]::GetFullPath($candidate);$script:SyncGitExecutableSHA256=$null;return $script:SyncGitExecutable}
        }
    }
    if(!$DataDir){$DataDir=Join-Path $env:LOCALAPPDATA 'RemoteAgents'}
    # Official asset checksums: https://github.com/git-for-windows/git/releases/tag/v2.56.0.windows.4
    $version='2.56.0.4'
    $architecture=$env:PROCESSOR_ARCHITEW6432;if(!$architecture){$architecture=$env:PROCESSOR_ARCHITECTURE}
    switch($architecture) {
        'ARM64' {$platform='arm64';$sha='70f7649f78088c1db1d2f3571ca46a04d5bef06e4e9d56d8ed7f9829e8c6c4db'}
        'AMD64' {$platform='64-bit';$sha='e3bf78351fe777fba47ddee5950082f8a98bb0f02604fdc7ba3ee2cb68ffa877'}
        'x86' {$platform='32-bit';$sha='6b3d71c7536d3c85baebaeb26d461e74c755895ccc1f4c817d0e289470419ccc'}
        default {throw 'Portable Git does not support this Windows architecture'}
    }
    $parent=[IO.Path]::GetFullPath((Join-Path $DataDir "sync\git\$version"))
    $destination=Join-Path $parent $platform;$executable=Join-Path $destination 'cmd\git.exe'
    $scan=$destination
    while($scan) {
        if((Test-Path -LiteralPath $scan) -and ((Get-Item -LiteralPath $scan -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse Git installation directory forbidden'}
        $next=Split-Path $scan -Parent;if($next -eq $scan){break};$scan=$next
    }
    if(Test-Path -LiteralPath $destination) {
        $marker=Join-Path $destination 'portable-git.json'
        if(!(Test-Path -LiteralPath $marker -PathType Leaf) -or !(Test-Path -LiteralPath $executable -PathType Leaf)){throw 'Portable Git installation is incomplete; existing files were preserved'}
        foreach($ownedFile in @($marker,$executable)) {if((Get-Item -LiteralPath $ownedFile -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse Git installation file forbidden'}}
        $installed=[IO.File]::ReadAllText($marker)|ConvertFrom-Json
        if($installed.archiveSHA256 -cne $sha -or $installed.executableSHA256 -cne (Get-SyncSHA256 $executable)){throw 'Portable Git verification failed'}
        $script:SyncGitExecutable=$executable;$script:SyncGitExecutableSHA256=$installed.executableSHA256;return $executable
    }
    New-Item -ItemType Directory -Path $parent -Force|Out-Null
    $stage=Join-Path $parent ('install-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage|Out-Null
    $archive=$DownloadedArchive
    try {
        if(!$archive) {
            $archive=Join-Path $stage 'download.zip'
            $url="https://github.com/git-for-windows/git/releases/download/v2.56.0.windows.4/MinGit-$version-$platform.zip"
            [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
            try {Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $archive -TimeoutSec 120}
            catch {
                $curl=Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
                if(!$curl){throw 'Portable Git download failed; check internet access and retry'}
                & $curl.Source --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 120 --output $archive $url
                if($LASTEXITCODE -ne 0){throw 'Portable Git download failed; check internet access and retry'}
            }
        }
        if((Get-SyncSHA256 $archive) -cne $sha){throw 'Portable Git archive SHA256 mismatch'}
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip=[IO.Compression.ZipFile]::OpenRead($archive)
        $payload=Join-Path $stage 'payload';New-Item -ItemType Directory -Path $payload|Out-Null
        try {
            foreach($entry in $zip.Entries) {
                $relative=$entry.FullName.Replace('/','\')
                if(!$relative -or $relative -match '(^\\|:|(^|\\)\.\.?(\\|$))' -or (($entry.ExternalAttributes -shr 16) -band 61440) -eq 40960){throw 'Unsafe portable Git archive entry'}
                $target=[IO.Path]::GetFullPath((Join-Path $payload $relative))
                if(!$target.StartsWith($payload+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Portable Git archive escaped installation'}
            }
        } finally {$zip.Dispose()}
        [IO.Compression.ZipFile]::ExtractToDirectory($archive,$payload)
        $stagedExecutable=Join-Path $payload 'cmd\git.exe'
        if(!(Test-Path -LiteralPath $stagedExecutable -PathType Leaf)){throw 'Portable Git archive layout mismatch'}
        $executableHash=Get-SyncSHA256 $stagedExecutable
        Write-SyncJson (Join-Path $payload 'portable-git.json') @{version=$version;archiveSHA256=$sha;executableSHA256=$executableHash}
        Move-Item -LiteralPath $payload -Destination $destination
        $script:SyncGitExecutable=$executable;$script:SyncGitExecutableSHA256=$executableHash;return $executable
    } finally {
        $checked=[IO.Path]::GetFullPath($stage)
        if(!$checked.StartsWith($parent+'\install-',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe portable Git temporary directory'}
        if(Test-Path -LiteralPath $checked){Remove-Item -LiteralPath $checked -Recurse -Force}
    }
}
function Invoke-SyncGit([string]$Root,[string[]]$Arguments,[int]$TimeoutMilliseconds=15000,[int]$MaxOutputCharacters=16777216) {
    $git=Get-SyncGitExecutable
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$git;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
    # Paths enter the process through WorkingDirectory, never command text.
    $start.WorkingDirectory=$Root
    $start.Arguments='-c core.fsmonitor=false '+($Arguments -join ' ')
    $process=New-Object Diagnostics.Process;$process.StartInfo=$start
    try {
        [void]$process.Start();$errorTask=$process.StandardError.ReadToEndAsync();$clock=[Diagnostics.Stopwatch]::StartNew()
        $buffer=New-Object char[] 4096;$outputBuilder=New-Object Text.StringBuilder
        while($true) {
            $remaining=$TimeoutMilliseconds-[int]$clock.ElapsedMilliseconds
            if($remaining -le 0){$process.Kill();throw 'Git scope command timed out'}
            $readTask=$process.StandardOutput.ReadAsync($buffer,0,$buffer.Length)
            if(!$readTask.Wait($remaining)){$process.Kill();throw 'Git scope command timed out'}
            $read=$readTask.GetAwaiter().GetResult();if(!$read){break}
            if($outputBuilder.Length+$read -gt $MaxOutputCharacters){$process.Kill();throw 'Git scope output limit exceeded'}
            [void]$outputBuilder.Append($buffer,0,$read)
        }
        $remaining=[Math]::Max(1,$TimeoutMilliseconds-[int]$clock.ElapsedMilliseconds)
        if(!$process.WaitForExit($remaining)){ $process.Kill();throw 'Git scope command timed out' }
        $output=$outputBuilder.ToString();$errorText=$errorTask.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0){throw 'Git scope could not be inspected'}
        if($errorText){throw 'Git scope could not be fully inspected; resolve Git warnings before seed'}
        return $output
    } finally { $process.Dispose() }
}
function Get-SyncGitPaths([string]$Root) {
    $base=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    $top=(Invoke-SyncGit $base @('rev-parse','--show-toplevel')).Trim().Replace('/','\').TrimEnd('\')
    if(![string]::Equals($base,$top,[StringComparison]::OrdinalIgnoreCase)){throw 'Select the exact Git repository root, not its parent or a subfolder'}
    $paths=(Invoke-SyncGit $base @('ls-files','--cached','--others','--exclude-standard','-z')).Split([char]0)
    $safe=New-Object 'Collections.Generic.List[string]'
    foreach($path in $paths) {
        if(!$path){continue}
        if($path -match '(^/|:|\\|(^|/)\.\.?(/|$))'){throw 'Unsafe Git path'}
        $parts=$path.Split('/');$denied=$false;$candidate=$base
        foreach($part in $parts) {
            if(Test-SyncDenied $part){$denied=$true;break}
            $candidate=Join-Path $candidate $part
            if(!(Test-Path -LiteralPath $candidate)){ $denied=$true;break }
            $entry=Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
            if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse Git entry forbidden'}
            if($entry.PSIsContainer -and (Test-Path -LiteralPath (Join-Path $candidate '.git'))){$denied=$true;break}
        }
        if(!$denied -and !(Get-Item -LiteralPath $candidate -Force).PSIsContainer){$safe.Add($path)}
    }
    @($safe | Sort-Object -Unique)
}
function Get-SyncGitInventory([string]$Root,[switch]$Hash) {
    $paths=@(Get-SyncGitPaths $Root)
    if(!$paths.Count){return @()}
    @(Get-SyncInventory -Root $Root -AllowedRoots $paths -Hash:$Hash -GitSourceTypes)
}
function Get-SyncInventory {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string[]]$AllowedRoots,[switch]$Hash,[switch]$WholeRoot,[switch]$GitSourceTypes)
    $base=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    $rootItem=Get-Item -LiteralPath $base -Force -ErrorAction Stop
    if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse root forbidden' }
    $seen=@{}; $items=New-Object 'System.Collections.Generic.List[object]'
    foreach($allowed in $AllowedRoots) {
        if($WholeRoot -and $allowed -eq '.') {
            $candidate=$base;$parts=@()
        } else {
        if (!$allowed -or $allowed -match '(^[\\/]|:|\*|\?|(^|[\\/])\.\.?([\\/]|$))') { throw 'Allowlist requires explicit relative paths' }
        $parts=$allowed -split '[\\/]'
        foreach($part in $parts) { if (Test-SyncDenied $part) { throw 'Denied allowlist path' } }
        $candidate=$base
        foreach($part in $parts) {
            $candidate=Join-Path $candidate $part
            $entry=Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
            if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse path forbidden' }
        }
        }
        $pending=New-Object 'System.Collections.Generic.Stack[string]'; $pending.Push($candidate)
        while($pending.Count) {
            $path=$pending.Pop(); $entry=Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if(Test-SyncDenied $entry.Name) { continue }
            if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse entry forbidden' }
            if($entry.PSIsContainer) {
                if($WholeRoot -and $path -ne $base -and (Test-Path -LiteralPath (Join-Path $path '.git'))){continue}
                foreach($child in Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop) {
                    if(!(Test-SyncDenied $child.Name)) { $pending.Push($child.FullName) }
                }
                continue
            }
            # Fail closed: only source/text/assets explicitly suitable for project transfer.
            $sourceExtension=$entry.Extension -match '(?i)^\.(php|js|mjs|cjs|jsx|ts|mts|cts|tsx|vue|json|lock|yaml|yml|xml|gradle|kts|kt|java|dart|css|scss|sass|less|html|md|txt|sql|graphql|gql|sh|ps1|bat|cmd|properties|toml|ini|png|jpg|jpeg|gif|webp|svg|woff2?|ttf)$'
            if($GitSourceTypes -and $entry.Extension -match '(?i)^\.(py|go|rs|c|h|cpp|hpp|cs|rb|swift)$'){$sourceExtension=$true}
            if(!$sourceExtension -and $entry.Name -notin @('artisan','gradlew','Dockerfile','Makefile','.editorconfig','.gitattributes','.gitignore','.node-version')) { continue }
            $relative=$entry.FullName.Substring($base.Length+1).Replace('\','/')
            if($seen.ContainsKey($relative)) { continue }; $seen[$relative]=$true
            $record=[ordered]@{path=$relative;size=[long]$entry.Length}
            if($Hash) { $record.sha256=Get-SyncSHA256 $entry.FullName }
            $items.Add([pscustomobject]$record)
        }
    }
    @($items | Sort-Object -Property path)
}
function Write-SyncJson($Path,$Value) {
    $json=$Value | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($Path,$json,(New-Object Text.UTF8Encoding($false)))
}
function ConvertFrom-RemoteSyncProjectPaths {
    param([AllowEmptyString()][string]$Text)
    $seen=@{}
    foreach($line in @($Text -split '\r?\n')) {
        $path=$line.Trim();if(!$path){continue}
        if(($path.StartsWith('"') -and $path.EndsWith('"')) -or ($path.StartsWith("'") -and $path.EndsWith("'"))){$path=$path.Substring(1,$path.Length-2).Trim()}
        if(!$path -or $path.Contains('"') -or ![IO.Path]::IsPathRooted($path)){throw 'Paste one absolute folder path per line'}
        $path=[IO.Path]::GetFullPath($path).TrimEnd('\','/')
        if(!$seen.ContainsKey($path)){$seen[$path]=$true;$path}
    }
}
function ConvertTo-RemoteSyncCandidatePaths {param([string]$Text) ConvertFrom-RemoteSyncProjectPaths -Text $Text}
function Test-RemoteSyncSystemPath([string]$Path) {
    $base=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    foreach($name in @($env:WINDIR,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramData,(Join-Path $env:USERPROFILE 'AppData'))) {
        if($name -and ($base -eq $name.TrimEnd('\') -or $base.StartsWith($name.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))){return $true}
    }
    if($base -eq $env:USERPROFILE -or $base -match '(?i)^[a-z]:\\Users$'){return $true}
    foreach($part in @($base -split '[\\/]')){if(Test-SyncDenied $part){return $true}}
    return $false
}
function Assert-RemoteSyncProjectPath([string]$SourcePath) {
    $root=Assert-SyncProjectsRoot $SourcePath
    if(Test-RemoteSyncSystemPath $root){throw 'System, profile and denied folders cannot be selected as projects'}
    return $root
}
function Test-RemoteSyncSourceFile($Entry) {
    return $Entry.Extension -match '(?i)^\.(php|js|mjs|cjs|jsx|ts|mts|cts|tsx|vue|json|lock|yaml|yml|xml|gradle|kts|kt|java|dart|css|scss|sass|less|html|md|txt|sql|graphql|gql|sh|ps1|bat|cmd|properties|toml|ini|png|jpg|jpeg|gif|webp|svg|woff2?|ttf|py|go|rs|c|h|cpp|hpp|cs|rb|swift)$' -or $Entry.Name -in @('artisan','gradlew','Dockerfile','Makefile','.editorconfig','.gitattributes','.gitignore','.node-version')
}
function Get-RemoteSyncProjectMetadata {
    param([Parameter(Mandatory)][string]$SourcePath,[ValidateSet('git','folder')][string]$ScopeMode='folder',[ValidateRange(1,1000000)][int]$MaxFiles=50000,[ValidateRange(1,100000)][int]$MaxDirectories=10000,[ValidateRange(1,30)][int]$MaxSeconds=3,[long]$LargeFileBytes=20971520,[switch]$Refresh)
    $root=Assert-RemoteSyncProjectPath $SourcePath
    $key="$root|$ScopeMode|$MaxFiles|$MaxDirectories|$MaxSeconds|$LargeFileBytes"
    if(!(Get-Variable RemoteSyncMetadataCache -Scope Script -ErrorAction SilentlyContinue)){$script:RemoteSyncMetadataCache=@{}}
    if(!$Refresh -and $script:RemoteSyncMetadataCache.ContainsKey($key)) {
        $cached=$script:RemoteSyncMetadataCache[$key]
        if(([DateTime]::UtcNow-$cached.created).TotalSeconds -lt 5){$copy=$cached.value.PSObject.Copy();$copy.cached=$true;return $copy}
    }
    $clock=[Diagnostics.Stopwatch]::StartNew();$pending=New-Object 'Collections.Generic.Stack[string]';$pending.Push($root)
    $reasons=New-Object 'Collections.Generic.List[string]';$files=0;$dirs=0;$visited=0;$excluded=0;$large=0;[long]$bytes=0;$latest=$null
    if($ScopeMode -eq 'git') {
        $pending.Clear();$directories=@{};$directories[$root]=$true;$dirs=1
        try {
            if(!(Test-Path -LiteralPath (Join-Path $root '.git'))){throw 'Git metadata requires an exact repository root'}
            $paths=(Invoke-SyncGit $root @('ls-files','--cached','--others','--exclude-standard','-z') ($MaxSeconds*1000)).Split([char]0)
            $seenFiles=@{}
            foreach($relative in $paths) {
                if(!$relative){continue}
                if($clock.Elapsed.TotalSeconds -ge $MaxSeconds){$reasons.Add('time-limit');break}
                if($visited -ge $MaxFiles){$reasons.Add('file-limit');break};$visited++
                if($relative -match '(^/|:|\\|(^|/)\.\.?(/|$))'){$reasons.Add('unsafe-path');continue}
                $safe=$true;$path=$root
                foreach($part in $relative.Split('/')) {
                    if(Test-SyncDenied $part){$safe=$false;break};$path=Join-Path $path $part
                    if(!(Test-Path -LiteralPath $path)){$safe=$false;break}
                    $entry=Get-Item -LiteralPath $path -Force -ErrorAction Stop
                    if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){$safe=$false;break}
                    if($entry.PSIsContainer) {
                        if(Test-Path -LiteralPath (Join-Path $path '.git')){$safe=$false;break}
                        if(!$directories.ContainsKey($path)) {
                            if($dirs -ge $MaxDirectories){$reasons.Add('directory-limit');$safe=$false;break}
                            $directories[$path]=$true;$dirs++
                        }
                    }
                }
                if(!$safe -or $entry.PSIsContainer -or !(Test-RemoteSyncSourceFile $entry)){$excluded++;continue}
                if($seenFiles.ContainsKey($path)){continue};$seenFiles[$path]=$true
                $files++;$bytes+=$entry.Length;if($entry.Length -gt $LargeFileBytes){$large++}
                if($null -eq $latest -or $entry.LastWriteTimeUtc -gt $latest){$latest=$entry.LastWriteTimeUtc}
            }
        } catch {$reasons.Add('unreadable-git-scope')}
    }
    while($pending.Count) {
        if($clock.Elapsed.TotalSeconds -ge $MaxSeconds){$reasons.Add('time-limit');break}
        if($dirs -ge $MaxDirectories){$reasons.Add('directory-limit');break}
        $directory=$pending.Pop()
        try {
            $item=Get-Item -LiteralPath $directory -Force -ErrorAction Stop
            if((Test-SyncDenied $item.Name) -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){$excluded++;continue}
            if($directory -ne $root -and (Test-Path -LiteralPath (Join-Path $directory '.git'))){$excluded++;continue}
            $dirs++
            foreach($path in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
                if($clock.Elapsed.TotalSeconds -ge $MaxSeconds){$reasons.Add('time-limit');break}
                if(Test-SyncDenied ([IO.Path]::GetFileName($path))){$excluded++;continue}
                $entry=Get-Item -LiteralPath $path -Force -ErrorAction Stop
                if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){$excluded++;continue}
                if($entry.PSIsContainer){
                    if($dirs+$pending.Count -ge $MaxDirectories){$reasons.Add('directory-limit');continue}
                    $pending.Push($path);continue
                }
                if($visited -ge $MaxFiles){$reasons.Add('file-limit');break};$visited++
                if(!(Test-RemoteSyncSourceFile $entry)){$excluded++;continue}
                $files++;$bytes+=$entry.Length;if($entry.Length -gt $LargeFileBytes){$large++}
                if($null -eq $latest -or $entry.LastWriteTimeUtc -gt $latest){$latest=$entry.LastWriteTimeUtc}
            }
        } catch {$reasons.Add('unreadable-directory')}
        if($reasons.Contains('file-limit') -or $reasons.Contains('time-limit')){break}
    }
    $result=[pscustomobject]@{fileCount=$files;bytes=$bytes;lastSourceWriteUtc=$(if($latest){$latest.ToString('o')}else{$null});complete=($reasons.Count -eq 0);reasons=@($reasons|Sort-Object -Unique);largeFileCount=$large;excludedCount=$excluded;visitedDirectories=$dirs;visitedFiles=$visited;cached=$false}
    if($script:RemoteSyncMetadataCache.Count -ge 128){$script:RemoteSyncMetadataCache.Clear()}
    $script:RemoteSyncMetadataCache[$key]=@{created=[DateTime]::UtcNow;value=$result};$result
}
function Get-RemoteSyncSelection {
    param([Parameter(Mandatory)][string]$DataDir,[Parameter(Mandatory)][string]$HostId)
    Assert-SyncId $HostId;$path=Join-Path $DataDir "sync\selections\$HostId.json"
    if(Test-Path -LiteralPath $path -PathType Leaf){return ([IO.File]::ReadAllText($path)|ConvertFrom-Json)}
    $projects=@(Get-RemoteSyncProjects $DataDir|Where-Object {$_.hostId -eq $HostId}|ForEach-Object {
        $mode='allowlist';if($_.PSObject.Properties.Name -contains 'scopeMode'){$mode=$_.scopeMode}
        [pscustomobject]@{projectId=$_.projectId;sourcePath=$_.sourcePath;scopeMode=$mode;selected=$true}
    })
    [pscustomobject]@{schema=1;hostId=$HostId;projects=$projects;legacy=$true}
}
function Get-RemoteSyncProjectCandidate {
    param([Parameter(Mandatory)][string]$SourcePath,[string]$DataDir,[string]$HostId,[switch]$Refresh,[ValidateRange(1,30)][int]$MaxSeconds=6)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $root=Assert-RemoteSyncProjectPath $SourcePath;$kind='folder';$mode='folder'
    if(Test-Path -LiteralPath (Join-Path $root '.git')) {
        $marker=Get-Item -LiteralPath (Join-Path $root '.git') -Force -ErrorAction Stop
        if($marker.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked Git metadata is forbidden'}
        $plumbing=(Invoke-SyncGit $root @('rev-parse','--show-toplevel','--absolute-git-dir','--git-common-dir') ($MaxSeconds*1000)).Trim() -split '\r?\n'
        if($plumbing.Count -ne 3){throw 'Git scope response is incomplete'}
        $top=$plumbing[0].Replace('/','\').TrimEnd('\')
        if(![string]::Equals($top,$root,[StringComparison]::OrdinalIgnoreCase)){throw 'Select the exact Git repository root'}
        $gitDir=$plumbing[1].Replace('/','\')
        $common=$plumbing[2].Replace('/','\')
        if(![IO.Path]::IsPathRooted($common)){$common=[IO.Path]::GetFullPath((Join-Path $root $common))}
        $kind='git';if(![string]::Equals($gitDir.TrimEnd('\'),$common.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)){$kind='worktree'};$mode='git'
    }
    $id=$null;$selected=$false
    if($DataDir -and $HostId){$saved=Get-RemoteSyncSelection $DataDir $HostId;$match=@($saved.projects|Where-Object {$_.sourcePath.TrimEnd('\') -eq $root}|Select-Object -First 1);if($match.Count){$id=$match[0].projectId;$selected=[bool]$match[0].selected}}
    $remaining=[Math]::Min(3,[Math]::Floor($MaxSeconds-$clock.Elapsed.TotalSeconds))
    if($remaining -ge 1){$metadata=Get-RemoteSyncProjectMetadata $root -ScopeMode $mode -Refresh:$Refresh -MaxSeconds ([int]$remaining)}
    else {$metadata=[pscustomobject]@{fileCount=0;bytes=0;lastSourceWriteUtc=$null;complete=$false;reasons=@('time-limit');largeFileCount=0;excludedCount=0;visitedDirectories=0;visitedFiles=0;cached=$false}}
    [pscustomobject]@{projectId=$id;sourcePath=$root;name=[IO.Path]::GetFileName($root);scopeMode=$mode;kind=$kind;selected=$selected;inventory=$metadata}
}
function Get-RemoteSyncProjectCandidates {
    param([string[]]$Paths,[string]$DataDir,[string]$HostId,[switch]$Refresh)
    $seen=@{};foreach($path in $Paths){$root=[IO.Path]::GetFullPath($path).TrimEnd('\');if(!$seen.ContainsKey($root)){$seen[$root]=$true;Get-RemoteSyncProjectCandidate $root -DataDir $DataDir -HostId $HostId -Refresh:$Refresh}}
}
function Save-RemoteSyncSelection {
    param([Parameter(Mandatory)][string]$DataDir,[Parameter(Mandatory)][string]$HostId,[AllowEmptyCollection()][object[]]$Candidates=@(),[switch]$Cancel)
    Assert-SyncId $HostId;if($Cancel){return (Get-RemoteSyncSelection $DataDir $HostId)}
    $previous=Get-RemoteSyncSelection $DataDir $HostId;$rows=New-Object 'Collections.Generic.List[object]';$seen=@{};$enabled=New-Object 'Collections.Generic.List[string]'
    # Validate the entire selection before creating bindings or writing state.
    foreach($candidate in $Candidates) {
        $root=[IO.Path]::GetFullPath([string]$candidate.sourcePath).TrimEnd('\');if($seen.ContainsKey($root)){throw 'Duplicate project path'};$seen[$root]=$true
        $selected=[bool]$candidate.selected;$match=@($previous.projects|Where-Object {$_.sourcePath.TrimEnd('\') -eq $root}|Select-Object -First 1)
        $id=$null;$mode='folder';if($match.Count){$id=$match[0].projectId;$mode=$match[0].scopeMode}
        if($selected){
            $probe=Get-RemoteSyncProjectCandidate $root;if(!$match.Count){$mode=$probe.scopeMode}
            $service=[IO.Path]::GetFullPath($DataDir).TrimEnd('\')
            if($root -eq $service -or $root.StartsWith($service+'\',[StringComparison]::OrdinalIgnoreCase) -or $service.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Project and service data folders must be disjoint'}
            foreach($other in $enabled){if($root -eq $other -or $root.StartsWith($other+'\',[StringComparison]::OrdinalIgnoreCase) -or $other.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Selected project folders overlap; choose a parent or its nested project'}}
            $enabled.Add($root)
        }
        if(!$id){$id='p-'+[guid]::NewGuid().ToString('N')}
        $rows.Add([pscustomobject]@{projectId=$id;sourcePath=$root;scopeMode=$mode;selected=$selected})
    }
    foreach($old in $previous.projects){if(!$seen.ContainsKey($old.sourcePath)){$rows.Add([pscustomobject]@{projectId=$old.projectId;sourcePath=$old.sourcePath;scopeMode=$old.scopeMode;selected=[bool]$old.selected})}}
    $enabled.Clear()
    foreach($row in $rows){if($row.selected){foreach($other in $enabled){if($row.sourcePath -eq $other -or $row.sourcePath.StartsWith($other+'\',[StringComparison]::OrdinalIgnoreCase) -or $other.StartsWith($row.sourcePath+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Selected project folders overlap; choose a parent or its nested project'}};$enabled.Add($row.sourcePath)}}
    foreach($row in $rows){if($row.selected -and !(Test-Path -LiteralPath (Join-Path (Get-SyncStatePath $DataDir $row.projectId $HostId) 'project.json'))){New-RemoteSyncProject -DataDir $DataDir -HostId $HostId -ProjectId $row.projectId -SourcePath $row.sourcePath -ScopeMode $row.scopeMode|Out-Null}}
    $directory=Join-Path $DataDir 'sync\selections';New-Item -ItemType Directory -Path $directory -Force|Out-Null
    $record=[pscustomobject]@{schema=1;hostId=$HostId;projects=$rows.ToArray();legacy=$false}
    $destination=Join-Path $directory "$HostId.json";$temporary=Join-Path $directory ([guid]::NewGuid().ToString('N')+'.tmp')
    try {Write-SyncJson $temporary $record;Move-Item -LiteralPath $temporary -Destination $destination -Force} finally {if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
    $record
}
function Find-RemoteSyncProjectCandidates {
    param([Parameter(Mandatory)][string]$RootPath,[switch]$IncludeNonGit,[switch]$AllowVolumeRoot,[ValidateRange(1,32)][int]$MaxDepth=12,[ValidateRange(1,100000)][int]$MaxDirectories=10000,[ValidateRange(1,1000)][int]$MaxProjects=200,[ValidateRange(1,30)][int]$MaxSeconds=15)
    $root=[IO.Path]::GetFullPath($RootPath).TrimEnd('\');$volume=$root -eq [IO.Path]::GetPathRoot($root).TrimEnd('\')
    if($volume){if(!$AllowVolumeRoot){throw 'Disk discovery requires explicit volume authorization'};$root+='\'}else{$root=Assert-RemoteSyncProjectPath $root}
    $clock=[Diagnostics.Stopwatch]::StartNew();$queue=New-Object 'Collections.Generic.Queue[object]';$queue.Enqueue(@{path=$root;depth=0});$results=New-Object 'Collections.Generic.List[object]';$reasons=New-Object 'Collections.Generic.List[string]';$visited=0
    while($queue.Count) {
        if($clock.Elapsed.TotalSeconds -ge $MaxSeconds){$reasons.Add('time-limit');break};if($visited -ge $MaxDirectories){$reasons.Add('directory-limit');break}
        $current=$queue.Dequeue();$visited++
        try {
            if($current.path -ne $root -and (Test-RemoteSyncSystemPath $current.path)){continue}
            $item=Get-Item -LiteralPath $current.path -Force -ErrorAction Stop;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
            $isProject=Test-Path -LiteralPath (Join-Path $current.path '.git')
            if(!$isProject -and $IncludeNonGit){foreach($name in @('package.json','composer.json','pyproject.toml','Cargo.toml','go.mod','pubspec.yaml','*.sln')){if($name -eq '*.sln'){continue};if(Test-Path -LiteralPath (Join-Path $current.path $name) -PathType Leaf){$isProject=$true;break}}}
            if($isProject -and !$volume -or ($isProject -and $current.path -ne $root)) {
                $remaining=[Math]::Floor($MaxSeconds-$clock.Elapsed.TotalSeconds);if($remaining -lt 1){$reasons.Add('time-limit');break}
                $candidate=Get-RemoteSyncProjectCandidate $current.path -MaxSeconds ([int]$remaining)
                $candidate.selected=$false;$results.Add($candidate)
                if($results.Count -ge $MaxProjects){if($queue.Count){$reasons.Add('project-limit')};break};continue
            }
            foreach($child in [IO.Directory]::EnumerateDirectories($current.path)) {
                if($clock.Elapsed.TotalSeconds -ge $MaxSeconds){$reasons.Add('time-limit');break}
                if(Test-SyncDenied ([IO.Path]::GetFileName($child))){continue}
                if($current.depth -ge $MaxDepth){$reasons.Add('depth-limit');continue}
                if($visited+$queue.Count -ge $MaxDirectories){$reasons.Add('directory-limit');break}
                $queue.Enqueue(@{path=$child;depth=$current.depth+1})
            }
        } catch {$reasons.Add('unreadable-directory')}
    }
    [pscustomobject]@{rootPath=$root;candidates=$results.ToArray();complete=($reasons.Count -eq 0);reasons=@($reasons|Sort-Object -Unique);visitedDirectories=$visited}
}
function New-RemoteSyncProject {
    param([Parameter(Mandatory)][string]$DataDir,[Parameter(Mandatory)][string]$ProjectId,[Parameter(Mandatory)][string]$HostId,[Parameter(Mandatory)][string]$SourcePath,[string[]]$AllowedRoots,[ValidateSet('allowlist','git','folder')][string]$ScopeMode='allowlist')
    $state=Get-SyncStatePath $DataDir $ProjectId $HostId
    if(Test-Path -LiteralPath (Join-Path $state 'project.json')) { throw 'Project binding already exists; use status/connect' }
    if($ScopeMode -eq 'git'){$AllowedRoots=@('.');$inventory=@(Get-SyncGitInventory $SourcePath)}
    elseif($ScopeMode -eq 'folder'){$SourcePath=Assert-RemoteSyncProjectPath $SourcePath;if(Test-Path -LiteralPath (Join-Path $SourcePath '.git')){throw 'Folder scope requires a non-Git project'};$AllowedRoots=@('.');$inventory=@(Get-SyncInventory -Root $SourcePath -AllowedRoots $AllowedRoots -WholeRoot -GitSourceTypes)}
    else {if(!$AllowedRoots.Count){throw 'Explicit allowed roots required'};$inventory=@(Get-SyncInventory -Root $SourcePath -AllowedRoots $AllowedRoots)}
    $source=[IO.Path]::GetFullPath($SourcePath).TrimEnd('\')
    $replica=[IO.Path]::GetFullPath((Join-Path $DataDir "workspaces\$ProjectId\$HostId"))
    if($replica.StartsWith($source+'\',[StringComparison]::OrdinalIgnoreCase) -or $replica -eq $source -or $source.StartsWith($replica+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Replica must be disjoint from source' }
    if(Test-Path -LiteralPath $replica) { throw 'Replica must be a new path' }
    New-Item -ItemType Directory -Path $state -Force | Out-Null
    $binding=[ordered]@{schema=1;projectId=$ProjectId;hostId=$HostId;sourcePath=$source;replicaPath=$replica;allowedRoots=@($AllowedRoots);folderId="ra-$ProjectId";state='registered';fileCount=$inventory.Count;bytes=($inventory|Measure-Object size -Sum).Sum}
    if($ScopeMode -in @('git','folder')){$binding.scopeMode=$ScopeMode}
    Write-SyncJson (Join-Path $state 'project.json') $binding
    [pscustomobject]$binding
}
function Get-SyncBinding($DataDir,$ProjectId,$HostId) {
    $state=Get-SyncStatePath $DataDir $ProjectId $HostId
    Get-Content -LiteralPath (Join-Path $state 'project.json') -Raw | ConvertFrom-Json
}
function Get-RemoteSyncProjects {
    param([Parameter(Mandatory)][string]$DataDir)
    $base=Join-Path $DataDir 'sync\projects'
    if(!(Test-Path -LiteralPath $base)) { return @() }
    foreach($project in Get-ChildItem -LiteralPath $base -Directory) {
        foreach($hostDir in Get-ChildItem -LiteralPath $project.FullName -Directory) {
            $path=Join-Path $hostDir.FullName 'project.json'
            if(Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
        }
    }
}
function Assert-SyncProjectsRoot([string]$RootPath) {
    $root=[IO.Path]::GetFullPath($RootPath).TrimEnd('\')
    if($root -eq [IO.Path]::GetPathRoot($root).TrimEnd('\')){throw 'Choose a projects folder, not an entire drive'}
    $item=Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if(!$item.PSIsContainer -or (Test-SyncDenied $item.Name)){throw 'Choose a regular projects folder'}
    $scan=$root
    while($scan) {
        if((Get-Item -LiteralPath $scan -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked projects roots are forbidden'}
        $next=Split-Path $scan -Parent;if($next -eq $scan){break};$scan=$next
    }
    $root
}
function Get-RemoteSyncRoot {
    param([Parameter(Mandatory)][string]$DataDir,[Parameter(Mandatory)][string]$HostId)
    Assert-SyncId $HostId
    $path=Join-Path $DataDir "sync\roots\$HostId.json"
    if(Test-Path -LiteralPath $path -PathType Leaf){[IO.File]::ReadAllText($path)|ConvertFrom-Json}
}
function Save-RemoteSyncRoot {
    param([Parameter(Mandatory)][string]$DataDir,[Parameter(Mandatory)][string]$HostId,[Parameter(Mandatory)][string]$RootPath)
    Assert-SyncId $HostId;$root=Assert-SyncProjectsRoot $RootPath
    $directory=Join-Path $DataDir 'sync\roots';New-Item -ItemType Directory -Path $directory -Force|Out-Null
    $record=[ordered]@{schema=1;hostId=$HostId;rootPath=$root}
    Write-SyncJson (Join-Path $directory "$HostId.json") $record
    [pscustomobject]$record
}
function Find-RemoteSyncRepositories {
    param([Parameter(Mandatory)][string]$RootPath,[string[]]$ExcludedPaths=@(),[ValidateRange(1,32)][int]$MaxDepth=12,[ValidateRange(1,100000)][int]$MaxDirectories=10000,[ValidateRange(1,1000)][int]$MaxProjects=200,[ValidateRange(1,60)][int]$MaxSeconds=30)
    $root=Assert-SyncProjectsRoot $RootPath
    $excluded=@($ExcludedPaths|ForEach-Object{[IO.Path]::GetFullPath($_).TrimEnd('\')})
    $queue=New-Object 'Collections.Generic.Queue[object]';$queue.Enqueue([pscustomobject]@{path=$root;depth=0})
    $projects=New-Object 'Collections.Generic.List[object]';$reasons=New-Object 'Collections.Generic.List[string]'
    $clock=[Diagnostics.Stopwatch]::StartNew();$visited=0;$skipped=0;$complete=$true
    while($queue.Count) {
        if($clock.Elapsed.TotalSeconds -ge $MaxSeconds){$complete=$false;$reasons.Add('time-limit');break}
        if($visited -ge $MaxDirectories){$complete=$false;$reasons.Add('directory-limit');break}
        $current=$queue.Dequeue();$visited++
        $omit=$false
        foreach($path in $excluded){if([string]::Equals($current.path,$path,[StringComparison]::OrdinalIgnoreCase) -or $current.path.StartsWith($path+'\',[StringComparison]::OrdinalIgnoreCase)){$omit=$true;break}}
        if($omit){$skipped++;continue}
        try {
            $item=Get-Item -LiteralPath $current.path -Force -ErrorAction Stop
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){$skipped++;continue}
            $marker=Join-Path $current.path '.git'
            if(Test-Path -LiteralPath $marker) {
                if((Get-Item -LiteralPath $marker -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){$skipped++;continue}
                $relative=if($current.path -eq $root){'.'}else{$current.path.Substring($root.Length+1).Replace('\','/')}
                $projects.Add([pscustomobject]@{sourcePath=$current.path;relativeProjectPath=$relative})
                # A repository owns its subtree: never register nested repos or submodules twice.
                if($projects.Count -ge $MaxProjects -and $queue.Count){$complete=$false;$reasons.Add('project-limit');break}
                continue
            }
            foreach($child in [IO.Directory]::EnumerateDirectories($current.path)) {
                if($clock.Elapsed.TotalSeconds -ge $MaxSeconds){$complete=$false;$reasons.Add('time-limit');break}
                if(Test-SyncDenied ([IO.Path]::GetFileName($child))){$skipped++;continue}
                if($current.depth -ge $MaxDepth){$complete=$false;$reasons.Add('depth-limit');continue}
                if($visited+$queue.Count -ge $MaxDirectories){$complete=$false;$reasons.Add('directory-limit');break}
                $queue.Enqueue([pscustomobject]@{path=$child;depth=($current.depth+1)})
            }
        } catch {$complete=$false;$reasons.Add('unreadable-directory')}
    }
    [pscustomobject]@{rootPath=$root;repositories=@($projects|Sort-Object relativeProjectPath);complete=$complete;reasons=@($reasons|Sort-Object -Unique);visitedDirectories=$visited;skippedDirectories=$skipped}
}
function Update-RemoteSyncRootProjects {
    param([Parameter(Mandatory)][string]$DataDir,[Parameter(Mandatory)][string]$HostId)
    $saved=Get-RemoteSyncRoot $DataDir $HostId
    if(!$saved){return [pscustomobject]@{hasRoot=$false;addedCount=0;existingCount=0;failedCount=0;complete=$true;projects=@();reasons=@()}}
    $found=Find-RemoteSyncRepositories -RootPath $saved.rootPath -ExcludedPaths @($DataDir)
    $existing=@{};foreach($binding in @(Get-RemoteSyncProjects $DataDir|Where-Object{$_.hostId -eq $HostId})){$existing[$binding.sourcePath.TrimEnd('\')]=$binding}
    $projects=New-Object 'Collections.Generic.List[object]';$failures=New-Object 'Collections.Generic.List[object]';$added=0;$reused=0
    if(@($found.repositories|Where-Object{!$existing.ContainsKey($_.sourcePath)}).Count){Get-SyncGitExecutable|Out-Null}
    foreach($repository in $found.repositories) {
        if($existing.ContainsKey($repository.sourcePath)){$projects.Add($existing[$repository.sourcePath]);$reused++;continue}
        try {
            $binding=New-RemoteSyncProject -DataDir $DataDir -ProjectId ('p-'+[guid]::NewGuid().ToString('N')) -HostId $HostId -SourcePath $repository.sourcePath -ScopeMode git
            $binding|Add-Member -NotePropertyName commonRootPath -NotePropertyValue $found.rootPath
            $binding|Add-Member -NotePropertyName relativeProjectPath -NotePropertyValue $repository.relativeProjectPath
            Write-SyncJson (Join-Path (Get-SyncStatePath $DataDir $binding.projectId $HostId) 'project.json') $binding
            $projects.Add($binding);$existing[$repository.sourcePath]=$binding;$added++
        } catch {$failures.Add([pscustomobject]@{relativeProjectPath=$repository.relativeProjectPath;reason='Git project could not be registered'})}
    }
    [pscustomobject]@{hasRoot=$true;rootPath=$found.rootPath;foundCount=$found.repositories.Count;addedCount=$added;existingCount=$reused;failedCount=$failures.Count;failures=$failures.ToArray();projects=$projects.ToArray();complete=($found.complete -and !$failures.Count);reasons=$found.reasons;visitedDirectories=$found.visitedDirectories;skippedDirectories=$found.skippedDirectories}
}
function Export-RemoteSyncSeed {
    param([string]$DataDir,[string]$ProjectId,[string]$HostId)
    $binding=Get-SyncBinding $DataDir $ProjectId $HostId
    $state=Get-SyncStatePath $DataDir $ProjectId $HostId
    $gitMode=$binding.PSObject.Properties.Name -contains 'scopeMode' -and $binding.scopeMode -eq 'git'
    $folderMode=$binding.PSObject.Properties.Name -contains 'scopeMode' -and $binding.scopeMode -eq 'folder'
    if($folderMode -and (Test-Path -LiteralPath (Join-Path $binding.sourcePath '.git'))){throw 'Folder project became a Git repository; review its scope before seeding'}
    if($gitMode){$files=@(Get-SyncGitInventory $binding.sourcePath -Hash)}else{$files=@(Get-SyncInventory $binding.sourcePath $binding.allowedRoots -Hash -WholeRoot:$folderMode -GitSourceTypes:$folderMode)}
    if(!$files.Count) { throw 'No allowed files' }
    Add-Type -AssemblyName System.IO.Compression
    $archive=Join-Path $state 'seed.zip'
    if(Test-Path -LiteralPath $archive) { throw 'Seed archive exists; do not overwrite' }
    $stream=[IO.File]::Open($archive,[IO.FileMode]::CreateNew)
    $zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach($file in $files) {
            $full=Join-Path $binding.sourcePath $file.path
            # Recheck scope immediately before open; source must be quiescent during seed.
            $check=@(Get-SyncInventory $binding.sourcePath @($file.path) -Hash -GitSourceTypes:($gitMode -or $folderMode))
            if($check.Count -ne 1 -or $check[0].sha256 -ne $file.sha256) { throw 'Source changed during seed' }
            $entry=$zip.CreateEntry($file.path); $dest=$entry.Open(); $input=[IO.File]::OpenRead($full)
            try { $input.CopyTo($dest) } finally { $input.Dispose(); $dest.Dispose() }
        }
    } finally { $zip.Dispose();$stream.Dispose() }
    $snapshot=[ordered]@{schema=1;projectId=$ProjectId;hostId=$HostId;snapshotId=[guid]::NewGuid().ToString('N');allowedRoots=@($binding.allowedRoots);files=$files}
    if($gitMode){$snapshot.scopeMode='git';$snapshot.gitPaths=@($files | ForEach-Object {$_.path})}
    if($folderMode){$snapshot.scopeMode='folder'}
    $manifest=Join-Path $state 'seed-manifest.json'; Write-SyncJson $manifest $snapshot
    [pscustomobject]@{archivePath=$archive;manifestPath=$manifest;sha256=(Get-SyncSHA256 $archive);fileCount=$files.Count}
}
function Get-RemoteSyncStatus {
    param([string]$DataDir,[string]$ProjectId,[string]$HostId)
    $binding=Get-SyncBinding $DataDir $ProjectId $HostId
    [pscustomobject]@{projectId=$ProjectId;hostId=$HostId;replicaPath=$binding.replicaPath;state=$binding.state;ready=$false;reason='Runtime health and current snapshot required'}
}
function Test-RemoteSyncBarrier {
    param([string]$DataDir,[string]$ProjectId,[string]$HostId,[string]$SnapshotPath,[scriptblock]$HealthProbe)
    $binding=Get-SyncBinding $DataDir $ProjectId $HostId
    $result=[ordered]@{ready=$false;projectId=$ProjectId;hostId=$HostId;replicaPath=$binding.replicaPath;reason='No live health probe';snapshotId=$null}
    if(!$HealthProbe) { return [pscustomobject]$result }
    try {
        $health=& $HealthProbe
        if(!$health.connected -or $health.state -ne 'idle' -or $health.needTotalItems -ne 0 -or $health.pullErrors -ne 0 -or $health.receiveOnlyTotalItems -ne 0) { throw 'Sync disconnected, pending, conflicted or locally modified' }
        $snapshot=Get-Content -LiteralPath $SnapshotPath -Raw | ConvertFrom-Json
        if($snapshot.projectId -cne $ProjectId -or $snapshot.hostId -cne $HostId) { throw 'Snapshot host/project mismatch' }
        $gitMode=$binding.PSObject.Properties.Name -contains 'scopeMode' -and $binding.scopeMode -eq 'git'
        $folderMode=$binding.PSObject.Properties.Name -contains 'scopeMode' -and $binding.scopeMode -eq 'folder'
        $actual=@(Get-SyncInventory $binding.replicaPath $binding.allowedRoots -Hash -WholeRoot:($gitMode -or $folderMode) -GitSourceTypes:($gitMode -or $folderMode))
        $expected=@($snapshot.files)
        if($actual.Count -ne $expected.Count) { throw 'Snapshot file count mismatch' }
        $index=@{}; foreach($file in $actual) { $index[$file.path]=$file }
        foreach($file in $expected) {
            if(!$index.ContainsKey($file.path) -or $index[$file.path].sha256 -cne $file.sha256 -or $index[$file.path].size -ne $file.size) { throw 'Snapshot hash mismatch' }
        }
        $healthAfter=& $HealthProbe
        if(!$healthAfter.connected -or $healthAfter.state -ne 'idle' -or $healthAfter.sequence -ne $health.sequence -or $healthAfter.needTotalItems -ne 0 -or $healthAfter.pullErrors -ne 0 -or $healthAfter.receiveOnlyTotalItems -ne 0) { throw 'Sync changed during barrier' }
        $result.ready=$true;$result.reason='verified';$result.snapshotId=$snapshot.snapshotId
    } catch { $result.reason=$_.Exception.Message }
    [pscustomobject]$result
}
