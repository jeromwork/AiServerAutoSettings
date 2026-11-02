#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$helper = Join-Path $PSScriptRoot 'setup-amnezia.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($helper, [ref]$tokens, [ref]$errors)
if ($errors) { throw ($errors | Out-String) }
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('amnezia-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$profile = Join-Path $fixture 'profile.json'
[IO.File]::WriteAllText($profile, '{"version":1,"serverAddress":"203.0.113.5","login":"root"}')
try {
    $before = (Get-FileHash -LiteralPath $profile).Hash
    $first = & $helper -ProfileDirectory $fixture -PrepareOnly 6>$null
    $second = & $helper -ProfileDirectory $fixture -PrepareOnly 6>$null
    Assert ($first.Status -eq 'Prepared' -and $second.Status -eq 'Prepared' -and -not $second.ServerVerified) 'PrepareOnly results failed'
    Assert ((Get-FileHash -LiteralPath $profile).Hash -eq $before -and @(Get-ChildItem -LiteralPath $fixture).Count -eq 1) 'PrepareOnly changed profile directory'
    foreach ($statement in $ast.EndBlock.Statements) {
        if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) { Invoke-Expression $statement.Extent.Text }
    }
    $realHelp = (Get-Command Get-AmneziaInstallerHelp).ScriptBlock
    $realElevated = (Get-Command Invoke-AmneziaElevatedInstall).ScriptBlock
    $realBusy = (Get-Command Get-AmneziaBusyInstaller).ScriptBlock
    $realSaveInstaller = (Get-Command Save-AmneziaInstaller).ScriptBlock
    $InstallTimeoutSeconds = 30
    $releasePage = 'https://github.com/amnezia-vpn/amnezia-client/releases/latest'
    $script:helpText = "Commands:`nin, install - install default packages`n--root <directory>`n--accept-licenses`n--default-answer`n--confirm-command"
    Assert (Test-AmneziaCliHelp $script:helpText) 'Valid CLI help rejected'
    Assert (-not (Test-AmneziaCliHelp ($script:helpText.Replace('--confirm-command', '--unknown')))) 'Missing CLI option accepted'
    Assert (-not (Test-AmneziaCliHelp ($script:helpText.Replace('in, install -', 'remove -')))) 'Missing install command accepted'
    & {
        function Get-Process { return [pscustomobject]@{ ProcessName='AmneziaVPN-official'; Id=14; Path='C:\Temp\AmneziaVPN-official.exe'; MainWindowTitle='' } }
        Assert ((& $realBusy).Id -eq 14) 'Help process was not detected'
    }
    & {
        function Get-Process { return [pscustomobject]@{ ProcessName='AmneziaVPN'; Id=15; Path='C:\Program Files\AmneziaVPN\AmneziaVPN.exe'; MainWindowTitle='AmneziaVPN' } }
        Assert ($null -eq (& $realBusy)) 'Ordinary client was mistaken for installer'
    }
    $script:launched = New-Object Collections.Generic.List[string]
    function New-FakeProcess([int]$Code, [bool]$Finished = $true) {
        $fake = [pscustomobject]@{ ExitCode = $Code; Finished = $Finished }
        $fake | Add-Member ScriptMethod WaitForExit { param($Timeout); return $this.Finished }
        $fake | Add-Member ScriptMethod Refresh { }
        return $fake
    }
    function Get-AmneziaInstallRoot { return (Join-Path $fixture 'client') }
    function Get-AmneziaClientState { return [pscustomobject]@{ State = $script:clientState; Path = (Join-Path $fixture 'client\AmneziaVPN.exe'); Root = (Get-AmneziaInstallRoot) } }
    function Get-AmneziaBusyInstaller { if ($script:busy) { return [pscustomobject]@{ Id = 7; Name = 'AmneziaVPN-official' } }; return $null }
    function Get-AuthenticodeSignature { $script:signatureCalls++; if ($script:rejectElevated -and $script:signatureCalls -gt 1) { return [pscustomobject]@{ Status = 'NotSigned' } }; return [pscustomobject]@{ Status = $script:signature } }
    function Invoke-RestMethod { $script:downloads++; return [pscustomobject]@{ draft=$false; prerelease=$false; assets=@([pscustomobject]@{
        name='AmneziaVPN_5.0.3.0_windows_x64.exe'; browser_download_url='https://github.com/amnezia-vpn/amnezia-client/releases/download/5.0.3.0/AmneziaVPN_5.0.3.0_windows_x64.exe'; size=3
        digest='sha256:039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81'
    }) } }
    function Save-AmneziaInstaller { param($Uri,$Headers,$OutFile,$ExpectedSize,$TimeoutSec); [IO.File]::WriteAllBytes($OutFile, [byte[]]@(1,2,3)); $script:createdInstallers.Add($OutFile) }
    function Start-Process {
        param($FilePath,$ArgumentList,$WindowStyle,$RedirectStandardOutput,$RedirectStandardError,[switch]$PassThru,$Verb)
        $script:launched.Add([string]$FilePath)
        if ($RedirectStandardOutput) { [IO.File]::WriteAllText($RedirectStandardOutput, $script:helpText); [IO.File]::WriteAllText($RedirectStandardError, '') }
        if ($ArgumentList -like '*-EncodedCommand *') {
            Assert ($Verb -eq 'RunAs') 'UAC was omitted'
            $encoded = ($ArgumentList -split '-EncodedCommand ')[1]
            $worker = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
            Invoke-Expression $worker
        }
        return (New-FakeProcess $script:processCode $script:processFinished)
    }
    function Get-AmneziaInstallerHelp { $script:helpCalls++; return [pscustomobject]@{ TimedOut=$script:helpTimeout; Supported=$script:helpSupported; ExitCode=0 } }
    function Invoke-AmneziaElevatedInstall { $script:installCalls++; if ($script:postHealthy) { $script:clientState='Healthy' }; return [pscustomobject]@{TimedOut=$script:installTimeout;Completed=$script:installCompleted;ExitCode=$script:installCode;Error='mock failure'} }
    function Invoke-AmneziaInteractiveInstall { $script:manualCalls++; if ($script:postHealthy) { $script:clientState='Healthy' }; return [pscustomobject]@{TimedOut=$script:installTimeout;Completed=$true;ExitCode=0;Error=$null} }
    function Read-Host { return $script:downloadChoice }
    function Reset-Mocks {
        $script:downloadChoice='1'; $script:manualCalls=0
        $script:clientState='Missing'; $script:busy=$false; $script:signature='Valid'; $script:signatureCalls=0; $script:rejectElevated=$false
        $script:downloads=0; $script:helpCalls=0; $script:installCalls=0; $script:helpTimeout=$false; $script:helpSupported=$true
        $script:installTimeout=$false; $script:installCompleted=$true; $script:installCode=0; $script:postHealthy=$true
        $script:processCode=0; $script:processFinished=$true; $script:launched.Clear()
    }
    $script:createdInstallers = New-Object Collections.Generic.List[string]
    Reset-Mocks; $script:clientState='Healthy'
    $result = Open-AmneziaClient 6>$null
    Assert ($result.Status -eq 'GuiOpened' -and $script:downloads -eq 0 -and $script:installCalls -eq 0) 'Healthy client was reinstalled'
    Reset-Mocks; $script:busy=$true
    $result = Open-AmneziaClient 6>$null
    Assert ($result.Status -eq 'InstallInProgress' -and $result.ExitCode -eq 2 -and $script:downloads -eq 0 -and $script:launched.Count -eq 0) 'Busy installer was ignored'
    Reset-Mocks; $script:clientState='Incomplete'
    $result = Install-AmneziaClient 6>$null
    Assert ($result.Status -eq 'NeedsManualClientInstall' -and $script:downloads -eq 0 -and $script:installCalls -eq 0) 'Incomplete client was overwritten'
    Reset-Mocks; $script:helpTimeout=$true
    $result = Install-AmneziaClient 6>$null
    Assert ($result.Status -eq 'InstallStillRunning' -and $script:installCalls -eq 0 -and $script:launched.Count -eq 0) 'Help timeout proceeded to install'
    Reset-Mocks; $script:helpSupported=$false
    $result = Open-AmneziaClient 6>$null
    Assert ($result.Status -eq 'GuiOpened' -and $script:installCalls -eq 0 -and $script:manualCalls -eq 1) 'Unsupported CLI did not use the interactive fallback'
    Reset-Mocks; $script:downloadChoice=''
    $createdBefore = $script:createdInstallers.Count
    $result = Open-AmneziaClient 6>$null
    Assert ($result.Status -eq 'ClientInstallSkipped' -and $script:createdInstallers.Count -eq $createdBefore -and $script:installCalls -eq 0 -and $script:launched.Count -eq 0) 'Default choice downloaded or installed the Windows client'
    Reset-Mocks; $script:signature='NotSigned'
    $result = Install-AmneziaClient 6>$null
    Assert ($result.Status -eq 'NeedsManualClientInstall' -and $script:helpCalls -eq 0 -and $script:installCalls -eq 0) 'Untrusted installer was run'
    Reset-Mocks; $script:installTimeout=$true
    $result = Install-AmneziaClient 6>$null
    Assert ($result.Status -eq 'InstallStillRunning' -and $result.ExitCode -eq 4) 'Install timeout reported success'
    Reset-Mocks; $script:installCode=1
    $result = Install-AmneziaClient 6>$null
    Assert ($result.Status -eq 'NeedsManualClientInstall') 'Nonzero installer exit reported success'
    Reset-Mocks; $script:postHealthy=$false
    $result = Install-AmneziaClient 6>$null
    Assert ($result.Status -eq 'NeedsManualClientInstall') 'Exit zero without client/service reported success'
    Reset-Mocks
    $result = Open-AmneziaClient 6>$null
    Assert ($result.Status -eq 'GuiOpened' -and $script:installCalls -eq 1 -and -not $result.ServerVerified) 'Successful install did not open client'
    # Exercise the real help runner and real elevated wrapper; every native launch is mocked.
    $binary = Join-Path $fixture 'AmneziaVPN-official.exe'; [IO.File]::WriteAllBytes($binary, [byte[]]@(1,2,3))
    $localDownload = Join-Path $fixture 'download-fixture.exe'
    & $realSaveInstaller -Uri ([uri]$binary).AbsoluteUri -Headers @{} -OutFile $localDownload -ExpectedSize 3 -TimeoutSec 5
    Assert ((Get-FileHash -LiteralPath $localDownload).Hash -eq (Get-FileHash -LiteralPath $binary).Hash) 'Download progress wrapper changed file contents'
    Reset-Mocks
    $result = & $realHelp $binary $fixture
    Assert ($result.Supported -and -not $result.TimedOut) 'Real help runner failed'
    $script:processFinished=$false
    $result = & $realHelp $binary $fixture
    Assert ($result.TimedOut -and -not $result.Supported) 'Real help runner ignored timeout'
    Reset-Mocks
    $result = & $realElevated $binary (Get-AmneziaInstallRoot) $fixture 30 6>$null
    Assert ($result.Completed -and $result.ExitCode -eq 0 -and $script:signatureCalls -eq 2) 'Elevated worker failed or did not recheck signature'
    Reset-Mocks; $script:rejectElevated=$true
    $result = & $realElevated $binary (Get-AmneziaInstallRoot) $fixture 30 6>$null
    Assert (-not $result.Completed -and $script:launched.Count -eq 1) 'Changed signature was executed after UAC'
    Reset-Mocks
    & {
        $script:uacAttempted = $false
        function Start-Process { $script:uacAttempted = $true; throw (New-Object ComponentModel.Win32Exception(1223)) }
        $rejected = $false
        try { & $realElevated $binary (Get-AmneziaInstallRoot) $fixture 30 6>$null | Out-Null } catch { $rejected=$true }
        Assert ($rejected -and $script:uacAttempted) 'UAC cancellation was ignored'
    }
    Write-Output ('PowerShell {0}: Amnezia safe mocks PASS (prepare, rerun, busy, partial, signature, help, timeout, exit, postcheck, UAC worker)' -f $PSVersionTable.PSVersion)
}
finally {
    # Delete only exact test-created files; no recursive traversal or profile-key access.
    foreach ($installer in @($script:createdInstallers)) { if (Test-Path -LiteralPath $installer -PathType Leaf) { Remove-Item -LiteralPath $installer -Force }; $directory = Split-Path -Parent $installer; if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -ErrorAction SilentlyContinue } }
    foreach ($file in @(Get-ChildItem -LiteralPath $fixture -File)) { Remove-Item -LiteralPath $file.FullName -Force }
    Remove-Item -LiteralPath $fixture
}
