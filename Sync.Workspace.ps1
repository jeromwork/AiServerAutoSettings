# Windows PowerShell 5.1. No network or process is started by dot-sourcing.
. (Join-Path $PSScriptRoot 'Windows.Paths.ps1')
Set-StrictMode -Version 2
function Write-SyncProgress([scriptblock]$Progress,[string]$Stage,[string]$Message,[long]$DoneBytes=-1,[long]$TotalBytes=-1,[int]$DoneFiles=-1,[int]$TotalFiles=-1) {
    if($Progress){& $Progress ([pscustomobject]@{stage=$Stage;message=$Message;doneBytes=$DoneBytes;totalBytes=$TotalBytes;doneFiles=$DoneFiles;totalFiles=$TotalFiles}) | Out-Null}
}
function Get-SyncSHA256([string]$LiteralPath,[scriptblock]$OnChunk) {
    $stream=[IO.File]::OpenRead((ConvertTo-RemoteAgentsIOPath $LiteralPath))
    $hash=[Security.Cryptography.SHA256]::Create()
    try {
        if(!$OnChunk){return [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-','').ToLowerInvariant()}
        $buffer=New-Object byte[] 1048576;$clock=[Diagnostics.Stopwatch]::StartNew();$last=-1000L
        while(($read=$stream.Read($buffer,0,$buffer.Length)) -gt 0){
            [void]$hash.TransformBlock($buffer,0,$read,$buffer,0)
            if($clock.ElapsedMilliseconds-$last -ge 1000){& $OnChunk $stream.Position $stream.Length | Out-Null;$last=$clock.ElapsedMilliseconds}
        }
        [void]$hash.TransformFinalBlock([byte[]]@(),0,0)
        & $OnChunk $stream.Length $stream.Length | Out-Null
        [BitConverter]::ToString($hash.Hash).Replace('-','').ToLowerInvariant()
    }
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
    param([string]$DataDir,[string]$DownloadedArchive,[switch]$ForcePortable,[switch]$InstalledOnly)
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
    if($InstalledOnly){return $null}
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
    # Never echo arbitrary arguments, Git stderr, remote URLs or account configuration.
    $operation='local Git inspection'
    if($Arguments.Count -and $Arguments[0] -eq 'rev-parse'){$operation='repository inspection (git rev-parse)'}
    if($Arguments.Count -and $Arguments[0] -eq 'ls-files'){$operation='local file enumeration (git ls-files)'}
    $timeoutMessage="Local Git timed out: $operation; limit $TimeoutMilliseconds ms. No Git hosting login was requested."
    $git=Get-SyncGitExecutable
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$git;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    # The managed launcher has a background reader on its control stdin pipe.
    # Git for Windows must not inherit that pipe: startup can block even for
    # rev-parse while the launcher waits for commands. Local plumbing needs EOF.
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding=New-Object Text.UTF8Encoding($false)
    # Paths enter the process through WorkingDirectory, never command text.
    $start.WorkingDirectory=$Root
    $start.Arguments='-c core.fsmonitor=false '+($Arguments -join ' ')
    $process=New-Object Diagnostics.Process;$process.StartInfo=$start;$started=$false
    try {
        [void]$process.Start();$started=$true;$processHandle=$process.Handle;$process.StandardInput.Close()
        $errorTask=$process.StandardError.ReadToEndAsync();$clock=[Diagnostics.Stopwatch]::StartNew()
        $buffer=New-Object char[] 4096;$outputBuilder=New-Object Text.StringBuilder
        while($true) {
            $remaining=$TimeoutMilliseconds-[int]$clock.ElapsedMilliseconds
            if($remaining -le 0){throw $timeoutMessage}
            $readTask=$process.StandardOutput.ReadAsync($buffer,0,$buffer.Length)
            if(!$readTask.Wait($remaining)){throw $timeoutMessage}
            $read=$readTask.GetAwaiter().GetResult();if(!$read){break}
            if($outputBuilder.Length+$read -gt $MaxOutputCharacters){throw "Git scope output limit exceeded: $operation"}
            [void]$outputBuilder.Append($buffer,0,$read)
        }
        $remaining=[Math]::Max(1,$TimeoutMilliseconds-[int]$clock.ElapsedMilliseconds)
        if(!$process.WaitForExit($remaining)){throw $timeoutMessage}
        $output=$outputBuilder.ToString();$errorText=$errorTask.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0){throw "Git scope could not be inspected: $operation; exit $($process.ExitCode)"}
        if($errorText){throw "Git scope could not be fully inspected: $operation; resolve Git warnings before seed"}
        return $output
    } finally {
        if($started -and !$process.HasExited){try{$process.Kill();[void]$process.WaitForExit(1000)}catch{}}
        $process.Dispose()
    }
}
function Get-SyncGitPaths([string]$Root,[int]$TimeoutMilliseconds=15000,[scriptblock]$Progress) {
    $base=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    Write-SyncProgress $Progress 'git' 'Проверяем локальный Git и корень репозитория'
    $top=(Invoke-SyncGit $base @('rev-parse','--show-toplevel') $TimeoutMilliseconds).Trim().Replace('/','\').TrimEnd('\')
    if(![string]::Equals($base,$top,[StringComparison]::OrdinalIgnoreCase)){throw 'Select the exact Git repository root, not its parent or a subfolder'}
    $paths=(Invoke-SyncGit $base @('ls-files','--cached','--others','--exclude-standard','-z') $TimeoutMilliseconds).Split([char]0)
    $safe=New-Object 'Collections.Generic.List[string]';$baseIO=ConvertTo-RemoteAgentsIOPath $base
    $clock=[Diagnostics.Stopwatch]::StartNew();$last=-1000L;$visited=0
    foreach($path in $paths) {
        $visited++
        if($clock.ElapsedMilliseconds-$last -ge 1000){Write-SyncProgress $Progress 'scope' 'Проверяем состав и исключения проекта' -DoneFiles $visited -TotalFiles $paths.Count;$last=$clock.ElapsedMilliseconds}
        if(!$path){continue}
        if($path -match '(^/|:|\\|(^|/)\.\.?(/|$))'){throw 'Unsafe Git path'}
        $parts=$path.Split('/');$denied=$false;$candidate=$baseIO
        foreach($part in $parts) {
            if(Test-SyncDenied $part){$denied=$true;break}
            $candidate=[IO.Path]::Combine($candidate,$part)
            $entry=[IO.FileInfo]::new($candidate)
            if(!$entry.Exists -and ![IO.Directory]::Exists($candidate)){ $denied=$true;break }
            if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse Git entry forbidden'}
            if($entry.Attributes -band [IO.FileAttributes]::Directory){$marker=[IO.Path]::Combine($candidate,'.git');if([IO.Directory]::Exists($marker) -or [IO.File]::Exists($marker)){$denied=$true;break}}
        }
        if(!$denied -and !($entry.Attributes -band [IO.FileAttributes]::Directory)){$safe.Add($path)}
    }
    @($safe | Sort-Object -Unique)
}
function Get-SyncGitInventory([string]$Root,[switch]$Hash,[int]$TimeoutMilliseconds=15000,[scriptblock]$Progress) {
    $paths=@(Get-SyncGitPaths $Root $TimeoutMilliseconds $Progress)
    if(!$paths.Count){return @()}
    @(Get-SyncInventory -Root $Root -AllowedRoots $paths -Hash:$Hash -GitSourceTypes -Progress $Progress)
}
function Get-SyncInventory {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string[]]$AllowedRoots,[switch]$Hash,[switch]$WholeRoot,[switch]$GitSourceTypes,[scriptblock]$Progress)
    $base=ConvertFrom-RemoteAgentsIOPath ([IO.Path]::GetFullPath((ConvertTo-RemoteAgentsIOPath $Root)).TrimEnd('\'))
    $baseIO=ConvertTo-RemoteAgentsIOPath $base
    $rootAttributes=[IO.File]::GetAttributes($baseIO)
    if ($rootAttributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse root forbidden' }
    if(!($rootAttributes -band [IO.FileAttributes]::Directory)){throw 'Inventory root must be a directory'}
    $seen=@{}; $items=New-Object 'System.Collections.Generic.List[object]'
    $progressClock=[Diagnostics.Stopwatch]::StartNew();$lastProgress=-1000L;[long]$processedBytes=0
    foreach($allowed in $AllowedRoots) {
        if($WholeRoot -and $allowed -eq '.') {
            $candidate=$baseIO;$parts=@()
        } else {
        if (!$allowed -or $allowed -match '(^[\\/]|:|\*|\?|(^|[\\/])\.\.?([\\/]|$))') { throw 'Allowlist requires explicit relative paths' }
        $parts=$allowed -split '[\\/]'
        foreach($part in $parts) { if (Test-SyncDenied $part) { throw 'Denied allowlist path' } }
        $candidate=$baseIO
        foreach($part in $parts) {
            $candidate=[IO.Path]::Combine($candidate,$part)
            if([IO.File]::GetAttributes($candidate) -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse path forbidden' }
        }
        }
        $pending=New-Object 'System.Collections.Generic.Stack[string]'; $pending.Push($candidate)
        while($pending.Count) {
            if($progressClock.ElapsedMilliseconds-$lastProgress -ge 1000){Write-SyncProgress $Progress 'inventory' 'Проверяем файлы и контрольные суммы' -DoneBytes $processedBytes -DoneFiles $items.Count;$lastProgress=$progressClock.ElapsedMilliseconds}
            $path=$pending.Pop()
            if(Test-SyncDenied ([IO.Path]::GetFileName($path))) { continue }
            $attributes=[IO.File]::GetAttributes($path)
            if($attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse entry forbidden' }
            if($attributes -band [IO.FileAttributes]::Directory) {
                $marker=[IO.Path]::Combine($path,'.git')
                if($WholeRoot -and $path -ne $baseIO -and ([IO.Directory]::Exists($marker) -or [IO.File]::Exists($marker))){continue}
                foreach($child in [IO.Directory]::EnumerateFileSystemEntries($path)) {
                    if(!(Test-SyncDenied ([IO.Path]::GetFileName($child)))) { $pending.Push($child) }
                }
                continue
            }
            $entry=[IO.FileInfo]::new($path)
            # Fail closed: only source/text/assets explicitly suitable for project transfer.
            $sourceExtension=$entry.Extension -match '(?i)^\.(php|js|mjs|cjs|jsx|ts|mts|cts|tsx|vue|json|lock|yaml|yml|xml|gradle|kts|kt|java|dart|css|scss|sass|less|html|md|txt|sql|graphql|gql|sh|ps1|bat|cmd|properties|toml|ini|png|jpg|jpeg|gif|webp|svg|woff2?|ttf)$'
            if($GitSourceTypes -and $entry.Extension -match '(?i)^\.(py|go|rs|c|h|cpp|hpp|cs|rb|swift)$'){$sourceExtension=$true}
            if(!$sourceExtension -and $entry.Name -notin @('artisan','gradlew','Dockerfile','Makefile','.editorconfig','.gitattributes','.gitignore','.node-version')) { continue }
            $relative=$path.Substring($baseIO.Length+1).Replace('\','/')
            if($seen.ContainsKey($relative)) { continue }; $seen[$relative]=$true
            $record=[ordered]@{path=$relative;size=[long]$entry.Length}
            if($Hash) {
                # Small source files finish between normal inventory updates;
                # do not allocate a 1-MiB chunk buffer/callback per tiny file.
                $hashProgress=if($Progress -and $entry.Length -gt 1MB){{param($done,$total)
                    if($progressClock.ElapsedMilliseconds-$lastProgress -ge 1000){Write-SyncProgress $Progress 'inventory' 'Проверяем файлы и контрольные суммы' -DoneBytes ($processedBytes+$done) -DoneFiles $items.Count; $lastProgress=$progressClock.ElapsedMilliseconds}
                }}else{$null}
                $record.sha256=Get-SyncSHA256 $entry.FullName $hashProgress
            }
            $processedBytes+=$entry.Length
            $items.Add([pscustomobject]$record)
        }
    }
    Write-SyncProgress $Progress 'inventory' 'Проверка файлов завершена' $processedBytes $processedBytes $items.Count $items.Count
    @($items | Sort-Object -Property path)
}
function Write-SyncJson($Path,$Value) {
    $json=$Value | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText((ConvertTo-RemoteAgentsIOPath $Path),$json,(New-Object Text.UTF8Encoding($false)))
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
            $seenFiles=@{};$checkedDirectories=@{}
            foreach($relative in $paths) {
                if(!$relative){continue}
                if($clock.Elapsed.TotalSeconds -ge $MaxSeconds){$reasons.Add('time-limit');break}
                if($visited -ge $MaxFiles){$reasons.Add('file-limit');break};$visited++
                if($relative -match '(^/|:|\\|(^|/)\.\.?(/|$))'){$reasons.Add('unsafe-path');continue}
                $safe=$true;$path=$root
                foreach($part in $relative.Split('/')) {
                    if(Test-SyncDenied $part){$safe=$false;break};$path=[IO.Path]::Combine($path,$part)
                    if($checkedDirectories.ContainsKey($path)){continue}
                    $entry=[IO.FileInfo]::new($path)
                    if(!$entry.Exists -and ![IO.Directory]::Exists($path)){$safe=$false;break}
                    if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){$safe=$false;break}
                    if($entry.Attributes -band [IO.FileAttributes]::Directory) {
                        if([IO.Directory]::Exists([IO.Path]::Combine($path,'.git')) -or [IO.File]::Exists([IO.Path]::Combine($path,'.git'))){$safe=$false;break}
                        if(!$directories.ContainsKey($path)) {
                            if($dirs -ge $MaxDirectories){$reasons.Add('directory-limit');$safe=$false;break}
                            $directories[$path]=$true;$dirs++
                        }
                        $checkedDirectories[$path]=$true
                    }
                }
                if(!$safe -or ($entry.Attributes -band [IO.FileAttributes]::Directory) -or !(Test-RemoteSyncSourceFile $entry)){$excluded++;continue}
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
    param([Parameter(Mandatory)][string]$SourcePath,[string]$DataDir,[string]$HostId,[switch]$Refresh,[ValidateRange(1,30)][int]$MaxSeconds=6,[ValidateRange(1,30)][int]$MetadataMaxSeconds=3,[ValidateRange(1,1000000)][int]$MetadataMaxFiles=50000,[ValidateRange(1,100000)][int]$MetadataMaxDirectories=10000)
    if($DataDir -and $HostId){
        $path=[IO.Path]::GetFullPath($SourcePath).TrimEnd('\')
        $rows=@((Get-RemoteSyncSelection $DataDir $HostId).projects|Where-Object{$_.sourcePath.TrimEnd('\') -eq $path})
        if($rows.Count -eq 1){
            $file=Join-Path (Get-SyncStatePath $DataDir $rows[0].projectId $HostId) 'project.json'
            if(Test-Path -LiteralPath $file){
                $binding=Get-SyncBinding $DataDir $rows[0].projectId $HostId
                if($binding.PSObject.Properties.Name -contains 'subscription' -and $binding.subscription){
                    return [pscustomobject]@{projectId=$binding.projectId;sourcePath=$path;name=$binding.projectId;scopeMode=$binding.scopeMode;kind='subscription';selected=[bool]$rows[0].selected;inventory=[pscustomobject]@{fileCount=0;bytes=0;lastSourceWriteUtc=$null;complete=$false;reasons=@('server-subscription');largeFileCount=0;excludedCount=0;cached=$false}}
                }
            }
        }
    }
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
    $remaining=[Math]::Min($MetadataMaxSeconds,[Math]::Floor($MaxSeconds-$clock.Elapsed.TotalSeconds))
    if($remaining -ge 1){$metadata=Get-RemoteSyncProjectMetadata $root -ScopeMode $mode -Refresh:$Refresh -MaxSeconds ([int]$remaining) -MaxFiles $MetadataMaxFiles -MaxDirectories $MetadataMaxDirectories}
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
        $subscription=$false;$hasBinding=$false
        if($match.Count -and (Test-Path -LiteralPath (Join-Path (Get-SyncStatePath $DataDir $id $HostId) 'project.json'))){$hasBinding=$true;$existing=Get-SyncBinding $DataDir $id $HostId;$subscription=$existing.PSObject.Properties.Name -contains 'subscription' -and $existing.subscription}
        if($selected -and !$subscription){
            $probe=Get-RemoteSyncProjectCandidate $root;if(!$hasBinding){$mode=$probe.scopeMode}
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
function Get-RemoteSyncQuickSearchRoots {
    param([string]$ProfilePath=$env:USERPROFILE,[string]$DocumentsPath=([Environment]::GetFolderPath('MyDocuments')),[string]$DesktopPath=([Environment]::GetFolderPath('Desktop')),[string[]]$DriveRoots)
    $paths=New-Object 'Collections.Generic.List[string]'
    $names=@('GitHub','GitLab','Git','repos','repositories','source','projects','work','dev','code','src','workspace','workspaces')
    foreach($parent in @($ProfilePath,$DocumentsPath,$DesktopPath)){
        if(!$parent){continue}
        foreach($name in $names){$paths.Add((Join-Path $parent $name))}
    }
    if(!$PSBoundParameters.ContainsKey('DriveRoots')){
        $DriveRoots=@([IO.DriveInfo]::GetDrives()|Where-Object{$_.DriveType -eq [IO.DriveType]::Fixed -and $_.IsReady}|ForEach-Object{$_.RootDirectory.FullName})
    }
    foreach($drive in $DriveRoots){foreach($name in $names){$paths.Add((Join-Path $drive $name))}}
    $roots=New-Object 'Collections.Generic.List[string]'
    # Only named project locations, never an entire profile or disk.
    $seen=@{}
    foreach($path in $paths){
        if($seen.ContainsKey($path)){continue};$seen[$path]=$true
        if(!(Test-Path -LiteralPath $path -PathType Container)){continue}
        try{$safe=Assert-RemoteSyncProjectPath $path;$roots.Add($safe)}catch{continue}
    }
    $roots.ToArray()
}
function Find-RemoteSyncQuickRepositories {
    param([string[]]$RootPaths,[string]$DataDir,[string]$HostId,[ValidateRange(1,30)][int]$MaxSeconds=15,[ValidateRange(1,100000)][int]$MaxDirectories=4000,[ValidateRange(1,1000)][int]$MaxProjects=100,[ValidateRange(1,12)][int]$MaxDepth=5)
    $clock=[Diagnostics.Stopwatch]::StartNew();$queue=New-Object 'Collections.Generic.Queue[object]'
    $results=New-Object 'Collections.Generic.List[object]';$reasons=New-Object 'Collections.Generic.List[string]';$seen=@{};$visited=0
    if(!$PSBoundParameters.ContainsKey('RootPaths')){$RootPaths=@(Get-RemoteSyncQuickSearchRoots)}
    $roots=New-Object 'Collections.Generic.List[string]'
    foreach($root in @($RootPaths|Sort-Object Length)){
        try{
            $safe=Assert-RemoteSyncProjectPath $root
            if(!@($roots|Where-Object{$safe -eq $_ -or $safe.StartsWith($_+'\',[StringComparison]::OrdinalIgnoreCase)}).Count){$roots.Add($safe)}
        }catch{$reasons.Add('unavailable-root')}
    }
    $git=Get-SyncGitExecutable -InstalledOnly
    if(!$git){return [pscustomobject]@{candidates=@();complete=$false;reasons=@('git-unavailable');visitedDirectories=0;rootPaths=$roots}}
    $excluded=if($DataDir){[IO.Path]::GetFullPath($DataDir).TrimEnd('\')}else{$null}
    foreach($root in $roots){$queue.Enqueue(@{path=$root;depth=0})}
    # Discover paths first: expensive inventories of early siblings must not
    # hide nested repositories. Reserve most of the budget for Git validation.
    $discoverySeconds=[Math]::Min(6,$MaxSeconds/3.0)
    while($queue.Count){
        if($clock.Elapsed.TotalSeconds -ge $discoverySeconds){$reasons.Add('discovery-time-limit');break}
        if($visited -ge $MaxDirectories){$reasons.Add('directory-limit');break}
        $current=$queue.Dequeue();$path=$current.path
        if($seen.ContainsKey($path)){continue};$seen[$path]=$true
        if($excluded -and ($path -eq $excluded -or $path.StartsWith($excluded+'\',[StringComparison]::OrdinalIgnoreCase))){continue}
        try{
            if(Test-RemoteSyncSystemPath $path){continue}
            $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if(!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){continue}
            $visited++
            $marker=Join-Path $path '.git'
            if(Test-Path -LiteralPath $marker){
                $gitMarker=Get-Item -LiteralPath $marker -Force
                if(!($gitMarker.Attributes -band [IO.FileAttributes]::ReparsePoint)){
                    $kind=if($gitMarker.PSIsContainer){'git'}else{'worktree'}
                    # A shallow mtime hint prioritizes validation only. Never
                    # present it as an ignore-aware source date in the result.
                    $hint=$null;$count=0
                    foreach($file in [IO.Directory]::EnumerateFiles($path)){
                        if($count++ -ge 200 -or $clock.Elapsed.TotalSeconds -ge $discoverySeconds){break}
                        $info=[IO.FileInfo]::new($file)
                        if(!(Test-SyncDenied $info.Name) -and !($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -and (Test-RemoteSyncSourceFile $info)){
                            if($null -eq $hint -or $info.LastWriteTimeUtc -gt $hint){$hint=$info.LastWriteTimeUtc}
                        }
                    }
                    $results.Add([pscustomobject]@{projectId=$null;sourcePath=$path;name=[IO.Path]::GetFileName($path);scopeMode='git';kind=$kind;selected=$false;quickPriorityUtc=$hint;inventory=[pscustomobject]@{fileCount=0;bytes=0;lastSourceWriteUtc=$null;complete=$false;reasons=@('git-verification-pending');largeFileCount=0;excludedCount=0;cached=$false}})
                    if($results.Count -ge $MaxProjects){$reasons.Add('project-limit');break}
                }
            }
            # Nested repos are independently selectable; overlap is denied on save.
            foreach($child in [IO.Directory]::EnumerateDirectories($path)){
                if($clock.Elapsed.TotalSeconds -ge $discoverySeconds){$reasons.Add('discovery-time-limit');break}
                if(Test-SyncDenied ([IO.Path]::GetFileName($child))){continue}
                if($current.depth -ge $MaxDepth){$reasons.Add('depth-limit');continue}
                if($visited+$queue.Count -ge $MaxDirectories){$reasons.Add('directory-limit');break}
                $queue.Enqueue(@{path=$child;depth=$current.depth+1})
            }
        }catch{$reasons.Add('unreadable-repository-or-directory')}
    }
    $priority=@($results|Sort-Object @{Expression={if($_.kind -eq 'worktree'){1}else{0}}},@{Expression={if($_.quickPriorityUtc){[datetime]$_.quickPriorityUtc}else{[datetime]::MinValue}};Descending=$true},sourcePath)
    foreach($row in $priority){
        $seconds=[Math]::Min(4,[Math]::Floor($MaxSeconds-$clock.Elapsed.TotalSeconds))
        if($seconds -lt 2){$reasons.Add('metadata-budget');break}
        try{
            $probe=Get-RemoteSyncProjectCandidate -SourcePath $row.sourcePath -DataDir $DataDir -HostId $HostId -MaxSeconds ([int]$seconds) -MetadataMaxSeconds 2 -MetadataMaxFiles 5000 -MetadataMaxDirectories 500
            $row.kind=$probe.kind;$row.projectId=$probe.projectId;$row.scopeMode=$probe.scopeMode;$row.inventory=$probe.inventory
        }catch{$reasons.Add('unreadable-repository')}
    }
    if(@($results|Where-Object{!$_.inventory.complete}).Count){$reasons.Add('metadata-incomplete')}
    [pscustomobject]@{candidates=@($results|Sort-Object @{Expression={if($_.kind -eq 'worktree'){1}else{0}}},@{Expression={if($_.inventory.lastSourceWriteUtc){[datetime]$_.inventory.lastSourceWriteUtc}else{[datetime]::MinValue}};Descending=$true},sourcePath);complete=($reasons.Count -eq 0);reasons=@($reasons|Sort-Object -Unique);visitedDirectories=$visited;rootPaths=$roots}
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
function New-RemoteSyncSubscription {
    param([Parameter(Mandatory)][string]$DataDir,[Parameter(Mandatory)][string]$ProjectId,[Parameter(Mandatory)][string]$HostId,[Parameter(Mandatory)]$ServerProject)
    Assert-SyncId $ProjectId;Assert-SyncId $HostId
    if($ServerProject.projectId -cne $ProjectId -or $ServerProject.scopeMode -notin @('allowlist','git','folder')){throw 'Explicit shared project identity and scope required'}
    $state=Get-SyncStatePath $DataDir $ProjectId $HostId
    $path=Join-Path $state 'project.json'
    if(Test-Path -LiteralPath $path){
        $existing=Get-SyncBinding $DataDir $ProjectId $HostId
        if($existing.PSObject.Properties.Name -notcontains 'subscription' -or !$existing.subscription){throw 'Existing seed binding cannot be converted to subscription'}
        if($existing.scopeMode -cne $ServerProject.scopeMode -or ($existing.allowedRoots -join '|') -cne ($ServerProject.allowedRoots -join '|')){throw 'Shared project scope changed; inspect binding'}
        $selection=Get-RemoteSyncSelection $DataDir $HostId
        foreach($row in $selection.projects){if($row.projectId -ceq $ProjectId){$row.selected=$true}}
        Write-SyncJson (Join-Path $DataDir "sync\selections\$HostId.json") $selection
        return $existing
    }
    $replica=[IO.Path]::GetFullPath((Join-Path $DataDir "workspaces\$ProjectId\$HostId"))
    if(Test-Path -LiteralPath $replica){throw 'Existing replica requires inspection; refusing adoption'}
    $binding=[ordered]@{schema=1;projectId=$ProjectId;hostId=$HostId;sourcePath=$replica;replicaPath=$replica;allowedRoots=@($ServerProject.allowedRoots);scopeMode=$ServerProject.scopeMode;folderId="ra-$ProjectId";state='registered';fileCount=0;bytes=0;subscription=$true}
    [void][IO.Directory]::CreateDirectory($state)
    [void][IO.Directory]::CreateDirectory((Join-Path $DataDir 'sync\selections'))
    Write-SyncJson $path $binding
    $selection=Get-RemoteSyncSelection $DataDir $HostId
    if($ProjectId -notin @($selection.projects|ForEach-Object{$_.projectId})){
        $selection.projects=@($selection.projects)+@([pscustomobject]@{projectId=$ProjectId;sourcePath=$replica;scopeMode=$ServerProject.scopeMode;selected=$true})
    }else{foreach($row in $selection.projects){if($row.projectId -ceq $ProjectId){$row.selected=$true}}}
    Write-SyncJson (Join-Path $DataDir "sync\selections\$HostId.json") $selection
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
function Get-RemoteSyncPreparedSeed {
    param([string]$DataDir,[string]$ProjectId,[string]$HostId,[scriptblock]$Progress,[string]$KnownArchiveHash)
    $state=Get-SyncStatePath $DataDir $ProjectId $HostId
    $archive=Join-Path $state 'seed.zip';$manifest=Join-Path $state 'seed-manifest.json';$index=Join-Path $state 'seed-index.json'
    $archiveInfo=[IO.FileInfo]::new((ConvertTo-RemoteAgentsIOPath $archive))
    if(!$archiveInfo.Exists -or ![IO.File]::Exists((ConvertTo-RemoteAgentsIOPath $manifest))){throw 'Prepared seed is incomplete; existing files preserved'}
    if($archiveInfo.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse archive forbidden'}
    if([IO.File]::GetAttributes((ConvertTo-RemoteAgentsIOPath $manifest)) -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse manifest forbidden'}
    $document=[IO.File]::ReadAllText((ConvertTo-RemoteAgentsIOPath $manifest))|ConvertFrom-Json
    if($document.projectId -cne $ProjectId -or $document.hostId -cne $HostId){throw 'Prepared seed identity mismatch'}
    $manifestHash=Get-SyncSHA256 $manifest
    $cached=$null
    if([IO.File]::Exists((ConvertTo-RemoteAgentsIOPath $index))){
        if([IO.File]::GetAttributes((ConvertTo-RemoteAgentsIOPath $index)) -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse seed index forbidden'}
        try{$cached=[IO.File]::ReadAllText((ConvertTo-RemoteAgentsIOPath $index))|ConvertFrom-Json}catch{$cached=$null}
    }
    $reuse=$false
    if($cached){
        try{$reuse=$cached.schema -eq 1 -and $cached.projectId -ceq $ProjectId -and $cached.hostId -ceq $HostId -and $cached.manifestHash -ceq $manifestHash -and $cached.archiveBytes -eq $archiveInfo.Length -and $cached.archiveWriteTicks -eq $archiveInfo.LastWriteTimeUtc.Ticks -and $cached.archiveHash -cmatch '^[a-f0-9]{64}$'}catch{$reuse=$false}
    }
    if($KnownArchiveHash){$archiveHash=$KnownArchiveHash;$reuse=$false}
    elseif($reuse){$archiveHash=$cached.archiveHash;Write-SyncProgress $Progress 'archive-index' 'Готовый архив не изменился; используем сохранённый индекс SHA-256'}
    else{$checksumProgress={param($done,$total) Write-SyncProgress $Progress 'archive-checksum' 'Проверяем готовый архив' $done $total};$archiveHash=Get-SyncSHA256 $archive $checksumProgress}
    if(!$reuse){
        $temporary=Join-Path $state ('index-'+[guid]::NewGuid().ToString('N')+'.pending')
        try{
            Write-SyncJson $temporary @{schema=1;projectId=$ProjectId;hostId=$HostId;manifestHash=$manifestHash;archiveBytes=$archiveInfo.Length;archiveWriteTicks=$archiveInfo.LastWriteTimeUtc.Ticks;archiveHash=$archiveHash}
            if([IO.File]::Exists((ConvertTo-RemoteAgentsIOPath $index))){[IO.File]::Replace((ConvertTo-RemoteAgentsIOPath $temporary),(ConvertTo-RemoteAgentsIOPath $index),[NullString]::Value)}
            else{[IO.File]::Move((ConvertTo-RemoteAgentsIOPath $temporary),(ConvertTo-RemoteAgentsIOPath $index))}
        }finally{if([IO.File]::Exists((ConvertTo-RemoteAgentsIOPath $temporary))){[IO.File]::Delete((ConvertTo-RemoteAgentsIOPath $temporary))}}
    }
    # This cache only skips a redundant LOCAL read of an immutable seed archive.
    # The receiver still verifies its complete SHA256, and readiness still hashes
    # live files. Metadata-only reuse must never bypass either of those barriers.
    [pscustomobject]@{archivePath=$archive;manifestPath=$manifest;sha256=$archiveHash;fileCount=@($document.files).Count;archiveBytes=$archiveInfo.Length;cached=$reuse}
}
function Export-RemoteSyncSeed {
    param([string]$DataDir,[string]$ProjectId,[string]$HostId,[scriptblock]$Progress)
    $binding=Get-SyncBinding $DataDir $ProjectId $HostId
    if($binding.PSObject.Properties.Name -contains 'subscription' -and $binding.subscription){throw 'Receive-only subscriptions cannot seed server sources'}
    $state=Get-SyncStatePath $DataDir $ProjectId $HostId
    $gitMode=$binding.PSObject.Properties.Name -contains 'scopeMode' -and $binding.scopeMode -eq 'git'
    $folderMode=$binding.PSObject.Properties.Name -contains 'scopeMode' -and $binding.scopeMode -eq 'folder'
    if($folderMode -and (Test-Path -LiteralPath (Join-Path $binding.sourcePath '.git'))){throw 'Folder project became a Git repository; review its scope before seeding'}
    # A complete initial seed is not a bounded discovery estimate. Allow cold/large
    # local Git enumeration a minute; discovery callers retain their short limits.
    if($gitMode){$files=@(Get-SyncGitInventory $binding.sourcePath -Hash -TimeoutMilliseconds 60000 -Progress $Progress)}else{$files=@(Get-SyncInventory $binding.sourcePath $binding.allowedRoots -Hash -WholeRoot:$folderMode -GitSourceTypes:$folderMode -Progress $Progress)}
    if(!$files.Count) { throw 'No allowed files' }
    Add-Type -AssemblyName System.IO.Compression
    $archive=Join-Path $state 'seed.zip'
    $manifest=Join-Path $state 'seed-manifest.json'
    if(Test-Path -LiteralPath $manifest) { throw 'Seed archive exists; do not overwrite' }
    # An interrupted older build has no committed manifest. Preserve its archive
    # under a new name, never mistake it for a resumable complete seed.
    if(Test-Path -LiteralPath $archive){Move-Item -LiteralPath $archive -Destination (Join-Path $state ('seed-incomplete-'+[guid]::NewGuid().ToString('N')+'.zip'))}
    $pending=Join-Path $state ('seed-building-'+[guid]::NewGuid().ToString('N')+'.zip')
    $pendingManifest=Join-Path $state ('seed-manifest-'+[guid]::NewGuid().ToString('N')+'.pending')
    [long]$totalBytes=($files | Measure-Object size -Sum).Sum;[long]$doneBytes=0;$doneFiles=0
    $clock=[Diagnostics.Stopwatch]::StartNew();$last=-1000L
    Write-SyncProgress $Progress 'archive' 'Создаём архив разрешённых файлов' 0 $totalBytes 0 $files.Count
    $stream=[IO.File]::Open((ConvertTo-RemoteAgentsIOPath $pending),[IO.FileMode]::CreateNew)
    $zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create)
    $buffer=New-Object byte[] 1048576
    try {
      try {
        foreach($file in $files) {
            $full=Join-Path $binding.sourcePath $file.path
            # Recheck scope immediately before open; source must be quiescent during seed.
            $check=@(Get-SyncInventory $binding.sourcePath @($file.path) -GitSourceTypes:($gitMode -or $folderMode))
            if($check.Count -ne 1 -or $check[0].size -ne $file.size) { throw 'Source changed during seed' }
            $entry=$zip.CreateEntry($file.path); $dest=$entry.Open(); $input=[IO.File]::OpenRead((ConvertTo-RemoteAgentsIOPath $full))
            $hash=[Security.Cryptography.SHA256]::Create()
            try {
                while(($read=$input.Read($buffer,0,$buffer.Length)) -gt 0){
                    $dest.Write($buffer,0,$read);[void]$hash.TransformBlock($buffer,0,$read,$buffer,0);$doneBytes+=$read
                    if($clock.ElapsedMilliseconds-$last -ge 1000){Write-SyncProgress $Progress 'archive' 'Создаём архив разрешённых файлов' $doneBytes $totalBytes $doneFiles $files.Count;$last=$clock.ElapsedMilliseconds}
                }
                [void]$hash.TransformFinalBlock([byte[]]@(),0,0)
                if([BitConverter]::ToString($hash.Hash).Replace('-','').ToLowerInvariant() -cne $file.sha256){throw 'Source changed during seed'}
            } finally {$hash.Dispose();$input.Dispose();$dest.Dispose()}
            $doneFiles++
        }
      } finally { $zip.Dispose();$stream.Dispose() }
      $snapshot=[ordered]@{schema=1;projectId=$ProjectId;hostId=$HostId;snapshotId=[guid]::NewGuid().ToString('N');allowedRoots=@($binding.allowedRoots);files=$files}
      if($gitMode){$snapshot.scopeMode='git';$snapshot.gitPaths=@($files | ForEach-Object {$_.path})}
      if($folderMode){$snapshot.scopeMode='folder'}
      Write-SyncJson $pendingManifest $snapshot
      [IO.File]::Move((ConvertTo-RemoteAgentsIOPath $pending),(ConvertTo-RemoteAgentsIOPath $archive));[IO.File]::Move((ConvertTo-RemoteAgentsIOPath $pendingManifest),(ConvertTo-RemoteAgentsIOPath $manifest))
    } finally {
      # Only unique staging files allocated by this invocation, inside own state.
      foreach($temporary in @($pending,$pendingManifest)){
          if([IO.Path]::GetDirectoryName($temporary) -cne [IO.Path]::GetFullPath($state)){throw 'Unsafe seed staging path'}
          if([IO.File]::Exists((ConvertTo-RemoteAgentsIOPath $temporary))){[IO.File]::Delete((ConvertTo-RemoteAgentsIOPath $temporary))}
      }
    }
    Write-SyncProgress $Progress 'archive' 'Архив подготовлен' $totalBytes $totalBytes $files.Count $files.Count
    $checksumProgress={param($done,$total) Write-SyncProgress $Progress 'archive-checksum' 'Проверяем готовый архив' $done $total}
    $prepared=Get-RemoteSyncPreparedSeed $DataDir $ProjectId $HostId -Progress $Progress -KnownArchiveHash (Get-SyncSHA256 $archive $checksumProgress)
    $prepared | Add-Member -NotePropertyName sourceBytes -NotePropertyValue $totalBytes -PassThru
}
function Get-RemoteSyncStatus {
    param([string]$DataDir,[string]$ProjectId,[string]$HostId)
    $binding=Get-SyncBinding $DataDir $ProjectId $HostId
    [pscustomobject]@{projectId=$ProjectId;hostId=$HostId;replicaPath=$binding.replicaPath;state=$binding.state;ready=$false;reason='Runtime health and current snapshot required'}
}
function Test-RemoteSyncBarrier {
    param([string]$DataDir,[string]$ProjectId,[string]$HostId,[string]$SnapshotPath,[scriptblock]$HealthProbe,[scriptblock]$Progress)
    $binding=Get-SyncBinding $DataDir $ProjectId $HostId
    $result=[ordered]@{ready=$false;projectId=$ProjectId;hostId=$HostId;replicaPath=$binding.replicaPath;reason='No live health probe';snapshotId=$null}
    if(!$HealthProbe) { return [pscustomobject]$result }
    try {
        $health=& $HealthProbe
        if(!$health.connected -or $health.state -ne 'idle' -or $health.needTotalItems -ne 0 -or $health.pullErrors -ne 0 -or $health.receiveOnlyTotalItems -ne 0) { throw 'Sync disconnected, pending, conflicted or locally modified' }
        $snapshot=Get-Content -LiteralPath (ConvertTo-RemoteAgentsIOPath $SnapshotPath) -Raw | ConvertFrom-Json
        if($snapshot.projectId -cne $ProjectId -or $snapshot.hostId -cne $HostId) { throw 'Snapshot host/project mismatch' }
        $gitMode=$binding.PSObject.Properties.Name -contains 'scopeMode' -and $binding.scopeMode -eq 'git'
        $folderMode=$binding.PSObject.Properties.Name -contains 'scopeMode' -and $binding.scopeMode -eq 'folder'
        $actual=@(Get-SyncInventory $binding.replicaPath $binding.allowedRoots -Hash -WholeRoot:($gitMode -or $folderMode) -GitSourceTypes:($gitMode -or $folderMode) -Progress $Progress)
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
