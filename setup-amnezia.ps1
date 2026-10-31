#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProfileDirectory,
    [ValidateSet('Choose', 'Separate', 'CorporateSplit')][string]$NetworkMode = 'Choose',
    [switch]$PrepareOnly,
    [ValidateRange(30, 1800)][int]$InstallTimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
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
    if (-not $process.WaitForExit(30000)) { return [pscustomobject]@{ TimedOut = $true; Supported = $false; ExitCode = $null } }
    $process.Refresh()
    $text = [IO.File]::ReadAllText($out) + [Environment]::NewLine + [IO.File]::ReadAllText($err)
    return [pscustomobject]@{ TimedOut = $false; Supported = ($process.ExitCode -eq 0 -and (Test-AmneziaCliHelp $text)); ExitCode = $process.ExitCode }
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
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { return [pscustomobject]@{ TimedOut = $true; Completed = $false; ExitCode = $null; Error = 'Installer still running' } }
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
    return [pscustomobject]@{ Address = $address; Login = $loginName }
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
        [void][IO.Directory]::CreateDirectory($downloadDirectory)
        Write-Host 'Загружаю официальный AmneziaVPN для автоматической установки...'
        Invoke-WebRequest -Uri $assetUri.AbsoluteUri -Headers $headers -UseBasicParsing -OutFile $installerPath -TimeoutSec 600
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
        if (-not $helpResult.Supported) { throw 'Этот выпуск не подтвердил необходимые параметры unattended через --help. Установка не запущена.' }
        if (Get-AmneziaBusyInstaller) { return (New-AmneziaResult 'InstallInProgress' 2 $null $downloadDirectory) }
        $installer = Invoke-AmneziaElevatedInstall $installerPath (Get-AmneziaInstallRoot) $downloadDirectory $InstallTimeoutSeconds
        if ($installer.TimedOut) { return (New-AmneziaResult 'InstallStillRunning' 4 $null $downloadDirectory) }
        if (-not $installer.Completed -or $installer.ExitCode -ne 0) { throw ('Установщик не подтвердил успех (код: {0}). {1}' -f $installer.ExitCode, $installer.Error) }
        $installed = Get-AmneziaClientState
        if ($installed.State -ne 'Healthy') { throw 'Установщик вернул 0, но подписанный клиент и служба не обнаружены. Установка не подтверждена.' }
        return (New-AmneziaResult 'ClientReady' 0 $installed.Path $downloadDirectory)
    }
    catch {
        Write-Host 'Автоматическая установка не завершилась.' -ForegroundColor Yellow
        Write-Host ('Причина: {0}' -f $_.Exception.Message)
        Write-Host 'Скачайте Windows x64 EXE, установите AmneziaVPN в стандартную папку и повторите этот пункт меню.'
        Write-Host 'Проверка загрузки или подписи не отключается. Другой VPN вместо Amnezia не устанавливается.'
        Write-Host ('Журналы (если загрузка началась): {0}' -f $downloadDirectory)
        if (-not (Get-AmneziaBusyInstaller)) { Start-Process -FilePath $releasePage | Out-Null }
        return (New-AmneziaResult 'NeedsManualClientInstall' 3 $null $downloadDirectory)
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $previousProtocol
        # Keep installer and logs for diagnosis, or for a process still finishing after timeout.
    }
}

function New-AmneziaResult([string]$Status, [int]$ExitCode, [string]$ClientPath, [string]$InstallerLog) {
    return [pscustomobject]@{ Status = $Status; ExitCode = $ExitCode; ClientPath = $ClientPath; Mode = $NetworkMode; ServerVerified = $false; InstallerLog = $InstallerLog }
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
        Write-Host 'Открыт AmneziaVPN. Теперь выберите + -> Свой сервер и выполните показанные шаги.' -ForegroundColor Cyan
        Write-Host 'VPS ещё не настроен этим помощником. Пароль/ключ вводите только в приложении; подключение VPN не включается автоматически.'
    }
    elseif ($result.Status -in @('InstallInProgress', 'InstallStillRunning')) {
        Write-Host 'Установщик Amnezia ещё работает (или открыт мастер). Завершите его и повторите пункт; второй процесс не запускается.' -ForegroundColor Yellow
        Write-Host 'Процессы не завершаются принудительно. Готовность VPN не подтверждена.'
        if ($result.InstallerLog) { Write-Host ('Журналы: {0}' -f $result.InstallerLog) }
    }
    return $result
}

function Show-AmneziaSteps($Server, [string]$Mode) {
    Write-Host ''
    Write-Host 'AmneziaVPN: подготовка официального приложения' -ForegroundColor Cyan
    Write-Host '1. В приложении: + (или Начать) -> Self-hosted VPN / Свой сервер.'
    Write-Host ('2. Адрес: {0}; SSH-пользователь: {1}; порт SSH: 22.' -f $Server.Address, $Server.Login)
    Write-Host '3. Выберите SSH-ключ в самом AmneziaVPN. Ключ этого подключения находится в папке профиля, файл id_ed25519.'
    Write-Host ('   Папка профиля: {0}' -f [IO.Path]::GetFullPath($ProfileDirectory))
    Write-Host '   Секреты вводите только в AmneziaVPN. Этот помощник ключи не открывает и в приложение не передаёт.'
    Write-Host '   Нужен root или sudo без пароля. Ограниченный пользователь для агентов не подходит; не расширяйте ему права ради VPN.'
    Write-Host '   Если приложение не принимает существующий ключ, не включайте парольный SSH-вход: остановитесь и разберите ошибку.'
    Write-Host '4. Для нового VPN выберите Автоматически (AmneziaWG), затем дождитесь результата в приложении.'
    Write-Host '   На сервере с уже установленной Amnezia: Пропустить настройку -> Управление -> Проверить установленные службы.'
    Write-Host '5. До нажатия Подключиться настройте выбранный ниже режим. Автоподключение пока оставьте выключенным.'
    if ($Mode -eq 'Separate') {
        Write-Host 'Режим: по очереди (рекомендуется). Корпоративный OpenVPN отключён, пока подключена Amnezia.'
        Write-Host 'Перед включением OpenVPN отключите Amnezia. Перед включением Amnezia отключите OpenVPN.'
    }
    else {
        Write-Host 'Режим: совместно с OpenVPN — настройка вручную; совместимость не гарантируется.' -ForegroundColor Yellow
        Write-Host 'Получите у администратора корпоративные IPv4-подсети, адреса VPN-шлюза и DNS.'
        Write-Host 'В Amnezia: разделение по сайтам/IP -> Только адреса из списка через VPN.'
        Write-Host 'Добавьте только нужные внешние IPv4-адреса/сети. Корпоративные сети, DNS, шлюз OpenVPN и адрес VPS в список не включайте.'
        Write-Host 'В OpenVPN должны быть согласованные с администратором маршруты только к корпоративным ресурсам и рабочий DNS.'
        Write-Host 'Если OpenVPN забирает весь интернет/меняет DNS, остановитесь: попросите администратора дать split-tunnel профиль.'
        Write-Host 'Просто исключить openvpn.exe недостаточно. Разделение по приложениям Windows умеет только обход VPN выбранными программами.'
        Write-Host 'Проверьте рабочий ресурс, обычный сайт и SSH к VPS. При сбое отключите Amnezia и используйте режим по очереди.'
    }
    Write-Host 'Это сервер VPN для вашего Windows. Не устанавливайте на VPS клиентский VPN и не меняйте его основной маршрут.'
    Write-Host 'Агенты на VPS продолжают работать через его обычный интернет. RDP/VNC наружу не открывайте.'
    Write-Host 'При firewall/ограничениях хостинга разрешается только выбранный приложением порт VPN; SSH-правила не меняйте.'
    Write-Host 'Готовность сервера и соединения проверяет AmneziaVPN. Этот помощник не подключается к VPS.'
    Write-Host ('Подробные шаги и официальные источники: {0}' -f (Join-Path $PSScriptRoot 'AMNEZIA.txt'))
}

$server = Get-AmneziaServerMetadata $ProfileDirectory
if (-not [Environment]::Is64BitOperatingSystem -or [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
    [Environment]::OSVersion.Version.Build -lt 17763) {
    throw 'Нужна 64-разрядная Windows 10 (1809+) или Windows 11.'
}
if ($NetworkMode -eq 'Choose') {
    if ($PrepareOnly) { $NetworkMode = 'Separate' }
    else {
        Write-Host ''
        Write-Host '1 — Amnezia и корпоративный OpenVPN по очереди (рекомендуется)'
        Write-Host '2 — Совместно: ручная настройка разделённых маршрутов с администратором'
        Write-Host '0 — Вернуться без запуска Amnezia'
        $choice = Read-Host 'Выберите режим; Enter — 1'
        if ($choice -eq '0') { return (New-AmneziaResult 'Cancelled' 0 $null $null) }
        if ($choice -eq '2') { $NetworkMode = 'CorporateSplit' }
        elseif ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq '1') { $NetworkMode = 'Separate' }
        else { throw 'Выберите 1, 2 или 0.' }
    }
}

Show-AmneziaSteps $server $NetworkMode
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
    return (Open-AmneziaClient)
}
finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
