# Sync-ContextMenu.ps1 - Context menu manager for AI-Server
[CmdletBinding()]
param(
    [ValidateSet('Enable', 'Disable', 'Add', 'Remove', 'Status')]
    [string]$Action = 'Status',
    [string]$Path = ''
)

$ErrorActionPreference = 'Stop'

function Show-Notification {
    param([string]$Title, [string]$Message)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $notify = New-Object Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.SystemIcons]::Information
        $notify.BalloonTipTitle = $Title
        $notify.BalloonTipText = $Message
        $notify.Visible = $true
        $notify.ShowBalloonTip(4000)
        Start-Sleep -Milliseconds 1500
        $notify.Dispose()
    } catch {
        Write-Host "[$Title] $Message"
    }
}

function Enable-AiServerContextMenu {
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
    $scriptPath = Join-Path $scriptDir 'Sync-ContextMenu.ps1'

    $commandAdd = "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`" -Action Add -Path `"%V`""
    $commandRemove = "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`" -Action Remove -Path `"%V`""

    # Use base64 UTF-8 strings to guarantee correct encoding on all Windows versions
    $labelAdd = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("8J+kliDQodC40L3RhdGA0L7QvdC40LfQuNGA0L7QstCw0YLRjCDRgSBBSS3RgdC10YDQstC10YDQvtC8"))
    $labelRemove = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("8J+bkSDQntGC0LrQu9GO0YfQuNGC0Ywg0L7RgiBBSS3RgdC10YDQstC10YDQsA=="))
    $labelBgAdd = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("8J+kliDQodC40L3RhdGA0L7QvdC40LfQuNGA0L7QstCw0YLRjCDRjdGC0YMg0L/QsNC/0LrRgyDRgSBBSS3RgdC10YDQstC10YDQvtC8"))
    $labelBgRemove = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("8J+bkSDQntGC0LrQu9GO0YfQuNGC0Ywg0Y3RgtGDINC/0LDQv9C60YMg0L7RgiBBSS3RgdC10YDQstC10YDQsA=="))

    # Directory context menu (right click on folder)
    $regDirAdd = "HKCU:\Software\Classes\Directory\shell\AiServerSync"
    $regDirRemove = "HKCU:\Software\Classes\Directory\shell\AiServerUnsync"

    New-Item -Path $regDirAdd -Force | Out-Null
    Set-ItemProperty -Path $regDirAdd -Name "(Default)" -Value $labelAdd
    Set-ItemProperty -Path $regDirAdd -Name "Icon" -Value "shell32.dll,269"
    New-Item -Path "$regDirAdd\command" -Force | Out-Null
    Set-ItemProperty -Path "$regDirAdd\command" -Name "(Default)" -Value $commandAdd

    New-Item -Path $regDirRemove -Force | Out-Null
    Set-ItemProperty -Path $regDirRemove -Name "(Default)" -Value $labelRemove
    Set-ItemProperty -Path $regDirRemove -Name "Icon" -Value "shell32.dll,272"
    New-Item -Path "$regDirRemove\command" -Force | Out-Null
    Set-ItemProperty -Path "$regDirRemove\command" -Name "(Default)" -Value $commandRemove

    # Background context menu (right click inside folder)
    $regBgAdd = "HKCU:\Software\Classes\Directory\Background\shell\AiServerSync"
    $regBgRemove = "HKCU:\Software\Classes\Directory\Background\shell\AiServerUnsync"

    New-Item -Path $regBgAdd -Force | Out-Null
    Set-ItemProperty -Path $regBgAdd -Name "(Default)" -Value $labelBgAdd
    Set-ItemProperty -Path $regBgAdd -Name "Icon" -Value "shell32.dll,269"
    New-Item -Path "$regBgAdd\command" -Force | Out-Null
    Set-ItemProperty -Path "$regBgAdd\command" -Name "(Default)" -Value $commandAdd

    New-Item -Path $regBgRemove -Force | Out-Null
    Set-ItemProperty -Path $regBgRemove -Name "(Default)" -Value $labelBgRemove
    Set-ItemProperty -Path $regBgRemove -Name "Icon" -Value "shell32.dll,272"
    New-Item -Path "$regBgRemove\command" -Force | Out-Null
    Set-ItemProperty -Path "$regBgRemove\command" -Name "(Default)" -Value $commandRemove

    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    Write-Host "Пункт добавлен в контекстное меню Windows!" -ForegroundColor Green
    Show-Notification "AI-Сервер" "Контекстное меню включено: теперь можно нажать правой кнопкой мыши по любой папке для синхронизации."
}

function Disable-AiServerContextMenu {
    $keys = @(
        "HKCU:\Software\Classes\Directory\shell\AiServerSync",
        "HKCU:\Software\Classes\Directory\shell\AiServerUnsync",
        "HKCU:\Software\Classes\Directory\Background\shell\AiServerSync",
        "HKCU:\Software\Classes\Directory\Background\shell\AiServerUnsync"
    )
    foreach ($key in $keys) {
        if (Test-Path $key) {
            Remove-Item -Path $key -Recurse -Force | Out-Null
        }
    }
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    Write-Host "Пункт удален из контекстного меню Windows." -ForegroundColor Yellow
    Show-Notification "AI-Сервер" "Контекстное меню удалено."
}

function Invoke-SyncAddFolder {
    param([string]$TargetFolder)
    if (-not $TargetFolder -or -not (Test-Path -LiteralPath $TargetFolder -PathType Container)) {
        Show-Notification "AI-Сервер: Ошибка" "Папка не существует или путь пуст."
        return
    }

    $folderPath = [IO.Path]::GetFullPath($TargetFolder).TrimEnd('\')
    $folderName = [IO.Path]::GetFileName($folderPath)

    $localData = [Environment]::GetFolderPath('LocalApplicationData')
    $dataDir = Join-Path $localData 'RemoteAgents'
    $compJson = Join-Path $dataDir 'computer.json'
    if (-not (Test-Path -LiteralPath $compJson)) {
        Show-Notification "AI-Сервер" "Сначала настройте подключение к серверу через 01-setup-ssh.cmd"
        return
    }

    $hostId = (Get-Content $compJson -Raw | ConvertFrom-Json).hostId
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

    . (Join-Path $scriptDir 'Sync.Workspace.ps1')
    . (Join-Path $scriptDir 'Select-RemoteAgentsProjects.ps1')

    $candidates = @(Get-RemoteSyncProjectCandidates -Paths @($folderPath) -DataDir $dataDir -HostId $hostId)
    if ($candidates.Count -eq 0) {
        Show-Notification "AI-Сервер: Внимание" "Папка не может быть синхронизирована."
        return
    }

    $candidates[0].selected = $true
    Save-RemoteSyncSelection -DataDir $dataDir -HostId $hostId -Candidates $candidates | Out-Null

    Show-Notification "AI-Сервер" "Папка «$folderName» добавлена в синхронизацию! Правила .gitignore и безопасность применены."
}

function Invoke-SyncRemoveFolder {
    param([string]$TargetFolder)
    if (-not $TargetFolder) { return }

    $folderPath = [IO.Path]::GetFullPath($TargetFolder).TrimEnd('\')
    $folderName = [IO.Path]::GetFileName($folderPath)

    $localData = [Environment]::GetFolderPath('LocalApplicationData')
    $dataDir = Join-Path $localData 'RemoteAgents'
    $compJson = Join-Path $dataDir 'computer.json'
    if (-not (Test-Path -LiteralPath $compJson)) { return }

    $hostId = (Get-Content $compJson -Raw | ConvertFrom-Json).hostId
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

    . (Join-Path $scriptDir 'Sync.Workspace.ps1')
    . (Join-Path $scriptDir 'Select-RemoteAgentsProjects.ps1')

    $selection = Get-RemoteSyncSelection $dataDir $hostId
    $match = @($selection.projects | Where-Object { $_.sourcePath.TrimEnd('\') -eq $folderPath })
    if ($match.Count -gt 0) {
        $match[0].selected = $false
        Save-RemoteSyncSelection -DataDir $dataDir -HostId $hostId -Candidates $selection.projects | Out-Null
        Show-Notification "AI-Сервер" "Папка «$folderName» отключена от синхронизации."
    } else {
        Show-Notification "AI-Сервер" "Папка «$folderName» не найдена в списке синхронизации."
    }
}

switch ($Action) {
    'Enable'  { Enable-AiServerContextMenu }
    'Disable' { Disable-AiServerContextMenu }
    'Add'     { Invoke-SyncAddFolder -TargetFolder $Path }
    'Remove'  { Invoke-SyncRemoveFolder -TargetFolder $Path }
    'Status'  {
        $enabled = Test-Path "HKCU:\Software\Classes\Directory\shell\AiServerSync"
        $statusText = if ($enabled) { "ВКЛЮЧЕНО" } else { "ВЫКЛЮЧЕНО" }
        Write-Host "Статус контекстного меню: $statusText"
    }
}
