#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProfileDirectory,
    [switch]$PrepareOnly,
    [switch]$ClientOnly,
    [ValidateRange(30, 1800)][int]$InstallTimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$releasePage = 'https://github.com/amnezia-vpn/amnezia-client/releases/latest'

function Get-AmneziaInstallRoot {
    # The official installer requires this default location. Never inspect app data.
    $programDirectory = $env:ProgramW6432
    if (-not $programDirectory) { $programDirectory = [Environment]::GetFolderPath('ProgramFiles') }
    if ($programDirectory) {
        return (Join-Path $programDirectory 'AmneziaVPN')
    }
    return $null
}

function Get-AmneziaClientState {
    $root = Get-AmneziaInstallRoot
    $candidate = Join-Path $root 'AmneziaVPN.exe'
    $service = Get-Service -Name 'AmneziaVPN-service' -ErrorAction SilentlyContinue
    $state = 'Missing'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $state = 'Incomplete'
        if ((Get-AuthenticodeSignature -LiteralPath $candidate).Status -eq 'Valid' -and $service -and $service.StartType -ne 'Disabled') { $state = 'Healthy' }
    }
    elseif ($service -or (Test-Path -LiteralPath $root -PathType Container)) { $state = 'Incomplete' }
    return [pscustomobject]@{ State = $state; Path = $candidate; Root = $root }
}

function Get-AmneziaBusyInstaller {
    # Do not request process command lines: they may contain unrelated secrets.
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        $name = [string]$process.ProcessName
        $title = [string]$process.MainWindowTitle
        $path = ''
        try { $path = [string]$process.Path } catch { }
        if ($name -match '\AAmneziaVPN(?:-official|.*_windows_x64)(?:\s*\(\d+\))?\z' -or
            ($name -match '\Amaintenancetool\z' -and $path -match '[\\/]AmneziaVPN[\\/]') -or
            ($title -match 'Amnezia' -and $title -match '(?i)install|setup|maintenance|установ')) {
            return [pscustomobject]@{ Id = $process.Id; Name = $name }
        }
    }
    return $null
}

function Test-AmneziaCliHelp([string]$Text) {
    foreach ($option in @('--root', '--accept-licenses', '--default-answer', '--confirm-command')) {
        if ($Text -notmatch ('(?<![\w-])' + [regex]::Escape($option) + '(?![\w-])')) { return $false }
    }
    return ($Text -match '(?im)^\s*(?:in,\s*)?install\s*(?:-|<|\s)')
}

function Get-AmneziaInstallerHelp([string]$InstallerPath, [string]$LogDirectory) {
    if ((Get-AuthenticodeSignature -LiteralPath $InstallerPath).Status -ne 'Valid') { throw 'Подпись перед --help не подтверждена.' }
    $out = Join-Path $LogDirectory 'help.stdout.txt'
    $err = Join-Path $LogDirectory 'help.stderr.txt'
    $process = Start-Process -FilePath $InstallerPath -ArgumentList '--help' -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
    # PS5.1 can lose ExitCode after WaitForExit unless the handle is retained.
    $processHandle = $process.Handle
    if (-not $process.WaitForExit(30000)) { return [pscustomobject]@{ TimedOut = $true; Supported = $false; ExitCode = $null } }
    $process.Refresh()
    $text = [IO.File]::ReadAllText($out) + [Environment]::NewLine + [IO.File]::ReadAllText($err)
    return [pscustomobject]@{ TimedOut = $false; Supported = ($process.ExitCode -eq 0 -and (Test-AmneziaCliHelp $text)); ExitCode = $process.ExitCode }
}

function Invoke-AmneziaInteractiveInstall([string]$InstallerPath, [int]$TimeoutSeconds) {
    if ((Get-AuthenticodeSignature -LiteralPath $InstallerPath).Status -ne 'Valid') { throw 'Подпись установщика не подтверждена.' }
    Write-Host 'Откроется мастер Amnezia для Windows. Завершите установку в его окне.'
    $process = Start-Process -FilePath $InstallerPath -WindowStyle Normal -PassThru
    $processHandle = $process.Handle
    if (-not (Wait-AmneziaInstallProcess $process $TimeoutSeconds)) { return [pscustomobject]@{ TimedOut=$true; Completed=$false; ExitCode=$null; Error=$null } }
    $process.Refresh()
    return [pscustomobject]@{ TimedOut=$false; Completed=$true; ExitCode=$process.ExitCode; Error=$null }
}

function Wait-AmneziaInstallProcess($Process, [int]$TimeoutSeconds) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $shown = $false
    try {
        while (-not $Process.WaitForExit(250)) {
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { return $false }
            $position = [int]([Math]::Floor($clock.ElapsedMilliseconds / 250) % 21)
            $bar = (' '*$position) + '====' + (' '*(20-$position))
            Write-Host -NoNewline ("`rНа компьютере: установка Amnezia [{0}] {1:mm\:ss}" -f $bar, $clock.Elapsed)
            $shown = $true
        }
        return $true
    } finally { if ($shown) { Write-Host '' } }
}

function Invoke-AmneziaElevatedInstall([string]$InstallerPath, [string]$Root, [string]$LogDirectory, [int]$TimeoutSeconds) {
    if ((Get-AuthenticodeSignature -LiteralPath $InstallerPath).Status -ne 'Valid') { throw 'Подпись перед установкой не подтверждена.' }
    $job = @{
        Installer = $InstallerPath; Hash = (Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash
        Arguments = ('--root "{0}" --accept-licenses --default-answer --confirm-command install' -f $Root)
        Out = (Join-Path $LogDirectory 'install.stdout.txt'); Err = (Join-Path $LogDirectory 'install.stderr.txt')
        Result = (Join-Path $LogDirectory 'install.result.json')
    }
    $jobBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($job | ConvertTo-Json -Compress)))
    $worker = @'
$ErrorActionPreference = 'Stop'
$job = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__JOB__')) | ConvertFrom-Json
try {
    # Validate again after UAC, before any elevated execution of the downloaded file.
    if ((Get-AuthenticodeSignature -LiteralPath $job.Installer).Status -ne 'Valid' -or
        (Get-FileHash -LiteralPath $job.Installer -Algorithm SHA256).Hash -ine $job.Hash) { throw 'Signature/hash changed before elevated install.' }
    $process = Start-Process -FilePath $job.Installer -ArgumentList $job.Arguments -WindowStyle Hidden -RedirectStandardOutput $job.Out -RedirectStandardError $job.Err -PassThru
    $processHandle = $process.Handle
    # The caller has a bounded wait. Do not kill a live installer or close its log pipes on timeout.
    [void]$process.WaitForExit()
    $process.Refresh()
    $result = @{ Completed = $true; ExitCode = $process.ExitCode; Error = $null }
}
catch { $result = @{ Completed = $false; ExitCode = $null; Error = $_.Exception.Message } }
[IO.File]::WriteAllText($job.Result, ($result | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
'@
    $worker = $worker.Replace('__JOB__', $jobBase64)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($worker))
    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Write-Host 'Подтвердите стандартный запрос Windows (UAC). Мастер установки заполнять не потребуется.'
    $process = Start-Process -FilePath $powerShellPath -ArgumentList ('-NoProfile -NonInteractive -EncodedCommand ' + $encoded) -Verb RunAs -WindowStyle Hidden -PassThru
    $processHandle = $process.Handle
    if (-not (Wait-AmneziaInstallProcess $process $TimeoutSeconds)) { return [pscustomobject]@{ TimedOut = $true; Completed = $false; ExitCode = $null; Error = 'Installer still running' } }
    if (-not (Test-Path -LiteralPath $job.Result -PathType Leaf)) { throw 'Повышенный процесс не записал результат. Установка не подтверждена.' }
    $result = [IO.File]::ReadAllText($job.Result) | ConvertFrom-Json
    return [pscustomobject]@{ TimedOut = $false; Completed = $result.Completed; ExitCode = $result.ExitCode; Error = $result.Error }
}

function Get-AmneziaServerMetadata([string]$Directory) {
    # Only connection metadata is read. Private keys and SSH config are never opened.
    $metadataPath = Join-Path ([IO.Path]::GetFullPath($Directory)) 'profile.json'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw 'Сначала выберите и настройте SSH-подключение в главном меню.'
    }
    $metadata = [IO.File]::ReadAllText($metadataPath) | ConvertFrom-Json
    $address = [string]$metadata.serverAddress
    $loginName = [string]$metadata.login
    $parsedAddress = $null
    $isAddress = [Net.IPAddress]::TryParse($address, [ref]$parsedAddress)
    if ($metadata.version -ne 1 -or $address -match '[\x00-\x20\x7f%]' -or
        $address.StartsWith('-') -or (-not $isAddress -and $address -notmatch '\A[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z') -or
        ($isAddress -and $parsedAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) -or
        $loginName -notmatch '\A[A-Za-z_][A-Za-z0-9_.-]{0,63}\$?\z') {
        throw 'В профиле некорректный адрес IPv4/имя сервера или SSH-пользователь. Проверьте подключение в главном меню.'
    }
    $keyDirectory = [IO.Path]::GetFullPath($Directory)
    if ($metadata.activeKey -and $metadata.activeKey -cne 'legacy') {
        if ([string]$metadata.activeKey -cnotmatch '\Akey-[a-f0-9]{32}\z') { throw 'Некорректный профиль SSH-ключа.' }
        $keyDirectory = Join-Path (Join-Path $keyDirectory 'keysets') $metadata.activeKey
    }
    return [pscustomobject]@{ Address = $address; Login = $loginName; KeyPath = (Join-Path $keyDirectory 'id_ed25519') }
}

function Install-AmneziaClient {
    $downloadDirectory = Join-Path ([IO.Path]::GetTempPath()) ('RemoteAgents-Amnezia-' + [guid]::NewGuid().ToString('N'))
    $installerPath = Join-Path $downloadDirectory 'AmneziaVPN-official.exe'
    $previousProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        if (Get-AmneziaBusyInstaller) { return (New-AmneziaResult 'InstallInProgress' 2 $null $null) }
        $existing = Get-AmneziaClientState
        if ($existing.State -eq 'Healthy') { return (New-AmneziaResult 'ClientReady' 0 $existing.Path $null) }
        if ($existing.State -eq 'Incomplete') { throw 'Обнаружена неполная установка Amnezia. Автоматическая переустановка не запускается: используйте штатное восстановление вручную.' }
        [Net.ServicePointManager]::SecurityProtocol = $previousProtocol -bor [Net.SecurityProtocolType]::Tls12
        $headers = @{ 'User-Agent' = 'RemoteAgents-Amnezia-Setup'; 'Accept' = 'application/vnd.github+json' }
        Write-Host 'Проверяю стабильный выпуск официального AmneziaVPN...'
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/amnezia-vpn/amnezia-client/releases/latest' -Headers $headers -TimeoutSec 30
        if ($release.draft -or $release.prerelease) { throw 'Не удалось определить стабильный выпуск.' }
        $assets = @($release.assets | Where-Object { $_.name -match '\AAmneziaVPN[^/\\]*_windows_x64\.exe\z' })
        # If upstream renames an asset, use the official page instead of guessing.
        if ($assets.Count -ne 1) { throw 'Изменилось имя официального установщика.' }
        $asset = $assets[0]
        $assetUri = [uri]$asset.browser_download_url
        if ($assetUri.Scheme -ne 'https' -or $assetUri.Host -ne 'github.com' -or
            -not $assetUri.AbsolutePath.StartsWith('/amnezia-vpn/amnezia-client/releases/download/')) {
            throw 'Неожиданный адрес загрузки.'
        }
        Write-Host ('Для VPN на ноутбуке нужен клиент Amnezia для Windows ({0:N0} МБ). Серверные пакеты скачивает сам сервер.' -f ([double]$asset.size / 1MB))
        do { $choice = (Read-Host '1 — установить клиент на Windows; 2 — пропустить; Enter — 2').Trim() } until ($choice -in @('', '1', '2'))
        if ($choice -ne '1') { return (New-AmneziaResult 'ClientInstallSkipped' 0 $null $null) }
        # Reuse a previous download only when it matches this release's digest.
        $cached = $null
        if ($asset.digest -match '\Asha256:([a-fA-F0-9]{64})\z') {
            $releaseHash = $Matches[1]
            foreach ($directory in @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'RemoteAgents-Amnezia-*')) {
                $candidate = Join-Path $directory.FullName 'AmneziaVPN-official.exe'
                if ([IO.File]::Exists($candidate) -and (Get-Item -LiteralPath $candidate).Length -eq [long]$asset.size -and
                    (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ieq $releaseHash) { $cached = $candidate; break }
            }
        }
        if ($cached) {
            $installerPath = $cached
            $downloadDirectory = Split-Path -Parent $cached
            Write-Host 'Используем уже скачанный установщик Amnezia.'
        } else {
            [void][IO.Directory]::CreateDirectory($downloadDirectory)
            Write-Host 'Скачиваем клиент Amnezia на Windows...'
            Save-AmneziaInstaller -Uri $assetUri.AbsoluteUri -Headers $headers -OutFile $installerPath -ExpectedSize ([long]$asset.size) -TimeoutSec 600
        }
        if ((Get-Item -LiteralPath $installerPath).Length -ne [long]$asset.size) { throw 'Загрузка неполная.' }
        if ($asset.digest -match '\Asha256:([a-fA-F0-9]{64})\z') {
            $expectedHash = $Matches[1]
            if ((Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash -ine $expectedHash) { throw 'Контрольная сумма не совпала.' }
        }
        # A failed or absent signature is not bypassed automatically.
        if ((Get-AuthenticodeSignature -LiteralPath $installerPath).Status -ne 'Valid') {
            throw 'Windows не подтвердила цифровую подпись установщика.'
        }
        if (Get-AmneziaBusyInstaller) { return (New-AmneziaResult 'InstallInProgress' 2 $null $downloadDirectory) }
        $helpResult = Get-AmneziaInstallerHelp $installerPath $downloadDirectory
        if ($helpResult.TimedOut) { return (New-AmneziaResult 'InstallStillRunning' 4 $null $downloadDirectory) }
        if (Get-AmneziaBusyInstaller) { return (New-AmneziaResult 'InstallInProgress' 2 $null $downloadDirectory) }
        if ($helpResult.Supported) {
            $installer = Invoke-AmneziaElevatedInstall $installerPath (Get-AmneziaInstallRoot) $downloadDirectory $InstallTimeoutSeconds
        } else {
            if ($ClientOnly) { throw 'Тихая установка не поддерживается этим выпуском. Мастер вручную не запускается.' }
            $installer = Invoke-AmneziaInteractiveInstall $installerPath $InstallTimeoutSeconds
        }
        if ($installer.TimedOut) { return (New-AmneziaResult 'InstallStillRunning' 4 $null $downloadDirectory) }
        if (-not $installer.Completed -or $installer.ExitCode -ne 0) { throw ('Установщик не подтвердил успех (код: {0}). {1}' -f $installer.ExitCode, $installer.Error) }
        $installed = Get-AmneziaClientState
        if ($installed.State -ne 'Healthy') { throw 'Установщик вернул 0, но подписанный клиент и служба не обнаружены. Установка не подтверждена.' }
        return (New-AmneziaResult 'ClientReady' 0 $installed.Path $downloadDirectory)
    }
    catch {
        Write-Host 'Автоматическая установка не завершилась.' -ForegroundColor Yellow
        Write-Host ('Причина: {0}' -f $_.Exception.Message)
        if ($ClientOnly) { Write-Host 'Автоматическая подготовка VPN пропущена. Можно повторить пункт VPN позже.' }
        else { Write-Host 'Скачайте Windows x64 EXE, установите AmneziaVPN в стандартную папку и повторите этот пункт меню.' }
        Write-Host ('Журналы (если загрузка началась): {0}' -f $downloadDirectory)
        if (-not $ClientOnly -and -not (Get-AmneziaBusyInstaller)) { Start-Process -FilePath $releasePage | Out-Null }
        return (New-AmneziaResult 'NeedsManualClientInstall' 3 $null $downloadDirectory)
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $previousProtocol
        # Keep installer and logs for diagnosis, or for a process still finishing after timeout.
    }
}

function Save-AmneziaInstaller([string]$Uri, $Headers, [string]$OutFile, [long]$ExpectedSize, [int]$TimeoutSec) {
    $client = New-Object Net.WebClient
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $ProgressPreference = 'Continue'
    try {
        foreach ($header in $Headers.Keys) { $client.Headers[$header] = $Headers[$header] }
        $task = $client.DownloadFileTaskAsync([uri]$Uri, $OutFile)
        while (-not $task.IsCompleted) {
            if ($clock.Elapsed.TotalSeconds -gt $TimeoutSec) { $client.CancelAsync(); throw 'Истекло время загрузки клиента Amnezia.' }
            $size = if ([IO.File]::Exists($OutFile)) { (Get-Item -LiteralPath $OutFile).Length } else { 0 }
            $percent = if ($ExpectedSize -gt 0) { [int][Math]::Min(99, [Math]::Floor(100.0*$size/$ExpectedSize)) } else { -1 }
            Write-Progress -Id 41 -Activity 'На компьютере: загрузка клиента Amnezia' -Status ('{0:N1} / {1:N1} МБ' -f ($size/1MB), ($ExpectedSize/1MB)) -PercentComplete $percent
            Start-Sleep -Milliseconds 200
        }
        $task.GetAwaiter().GetResult() | Out-Null
    } finally {
        Write-Progress -Id 41 -Activity 'На компьютере: загрузка клиента Amnezia' -Completed
        $client.Dispose()
    }
}

function New-AmneziaResult([string]$Status, [int]$ExitCode, [string]$ClientPath, [string]$InstallerLog) {
    return [pscustomobject]@{ Status = $Status; ExitCode = $ExitCode; ClientPath = $ClientPath; ServerVerified = $false; InstallerLog = $InstallerLog }
}

function Open-AmneziaClient {
    if (Get-AmneziaBusyInstaller) { return (New-AmneziaResult 'InstallInProgress' 2 $null $null) }
    $client = Get-AmneziaClientState
    if ($client.State -eq 'Healthy') { $result = New-AmneziaResult 'ClientReady' 0 $client.Path $null }
    else { $result = Install-AmneziaClient }
    if ($result.Status -eq 'ClientReady') {
        # No SSH credentials or automatic Connect command are passed to the GUI.
        if ((Get-AuthenticodeSignature -LiteralPath $result.ClientPath).Status -ne 'Valid') { throw 'Подпись клиента перед запуском не подтверждена.' }
        Start-Process -FilePath $result.ClientPath | Out-Null
        $result.Status = 'GuiOpened'
        Write-Host 'Открыт AmneziaVPN. Выберите «Свой сервер».' -ForegroundColor Cyan
    }
    elseif ($result.Status -in @('InstallInProgress', 'InstallStillRunning')) {
        Write-Host 'Установщик Amnezia ещё работает (или открыт мастер). Завершите его и повторите пункт; второй процесс не запускается.' -ForegroundColor Yellow
        Write-Host 'Процессы не завершаются принудительно. Готовность VPN не подтверждена.'
        if ($result.InstallerLog) { Write-Host ('Журналы: {0}' -f $result.InstallerLog) }
    }
    return $result
}

function Show-AmneziaSteps($Server) {
    Write-Host ('Amnezia: свой сервер {0}, пользователь {1}, SSH-порт 22.' -f $Server.Address, $Server.Login)
    Write-Host ('Ключ: {0}' -f $Server.KeyPath)
    Write-Host 'Выберите автоматическую настройку AmneziaWG. Для уже настроенного сервера пропустите повторную установку.'
    Write-Host 'Пароль вводите в Amnezia. Подробности — в AMNEZIA.txt.'
}

$server = Get-AmneziaServerMetadata $ProfileDirectory
if (-not [Environment]::Is64BitOperatingSystem -or [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
    [Environment]::OSVersion.Version.Build -lt 17763) {
    throw 'Нужна 64-разрядная Windows 10 (1809+) или Windows 11.'
}
if (-not $ClientOnly) { Show-AmneziaSteps $server }
if ($PrepareOnly) {
    $client = Get-AmneziaClientState
    $path = $null
    if ($client.State -eq 'Healthy') { $path = $client.Path }
    return (New-AmneziaResult 'Prepared' 0 $path $null)
}
# Serialize calls from this launcher; other/manual installers are checked by process inventory.
$mutex = New-Object Threading.Mutex($false, 'Local\RemoteAgents.AmneziaSetup')
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) {
        Write-Host 'Другой помощник Amnezia уже выполняется. Завершите его и повторите пункт.' -ForegroundColor Yellow
        return (New-AmneziaResult 'InstallInProgress' 2 $null $null)
    }
    if ($ClientOnly) { return (Install-AmneziaClient) }
    return (Open-AmneziaClient)
}
finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
