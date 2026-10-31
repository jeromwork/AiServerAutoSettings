$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'server-browser.ps1'
$errors = $null
[Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errors) | Out-Null
if ($errors.Count) { throw ($errors | Out-String) }
$pythonCommand = Get-Command python.exe -ErrorAction Stop
. $scriptPath -SSHExecutable $pythonCommand.Source
$vectors = @('plain', 'C:\folder with spaces\ssh_config', 'quote"inside', 'C:\trailing\', '', 'C:\known hosts\')
$start = New-BrowserSshStart (@('-c', 'import json,sys; print(json.dumps(sys.argv[1:]))') + $vectors)
$start.RedirectStandardOutput = $true
$process = New-Object Diagnostics.Process
$process.StartInfo = $start
try {
    if (-not $process.Start()) { throw 'Argument roundtrip child did not start.' }
    # Windows PowerShell 5.1 emits the JSON array as one pipeline object.
    $actual = $process.StandardOutput.ReadToEnd() | ConvertFrom-Json
    $process.WaitForExit()
    if ($process.ExitCode -ne 0 -or $actual.Count -ne $vectors.Count) { throw 'Argument roundtrip failed.' }
    for ($index = 0; $index -lt $vectors.Count; $index++) {
        if ($actual[$index] -cne $vectors[$index]) { throw "Argument mismatch at $index" }
    }
} finally { $process.Dispose() }
$port = Get-BrowserFreePort
if ($port -lt 1 -or $port -gt 65535) { throw 'Invalid allocated loopback port.' }
Write-Output 'PASS: PowerShell syntax, real Windows argv roundtrip, loopback allocation. No SSH or account access.'
