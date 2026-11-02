$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Run with Windows PowerShell 5.1.' }
$sourcePath = Join-Path $PSScriptRoot 'setup-vps-ssh.ps1'
$tokens = $null; $parseErrors = $null
$tree = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Convert-SshArgument','Invoke-ProfileSsh','Select-SetupOutputMode')) {
    $definition = $tree.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) | Where-Object Name -eq $name | Select-Object -First 1
    if (-not $definition) { throw ('Missing function: ' + $name) }
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Initialize-PasswordWindow { }
$fixture = Join-Path $PSScriptRoot ('stdin-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
try {
    $unicode = -join @([char]0x0442,[char]0x0435,[char]0x0441,[char]0x0442)
    $publicPayload = "#!/bin/sh`n# $unicode`nprintf '%s\n' '$unicode'`n"
    $expected = [Convert]::ToBase64String((New-Object Text.UTF8Encoding($false)).GetBytes($publicPayload + "`n"))
    $receiver = Join-Path $fixture 'public stdin receiver.exe'
    $receiverSource = @"
using System;
using System.IO;
public static class PublicStdinReceiver {
    public static int Main(string[] args) {
        using (var input = Console.OpenStandardInput())
        using (var output = new MemoryStream()) {
            input.CopyTo(output);
            var value = output.ToArray();
            if (Convert.ToBase64String(value) != "$expected") return 21;
            if(args.Length>0) {
                if(args[0]=="private") {
                    Console.WriteLine("PRIVATE_CONFIG_FIXTURE");
                    Console.Error.WriteLine("public diagnostic");
                    return 0;
                }
                for(int i=0;i<2000;i++) {
                    Console.WriteLine("stdout "+i+" $unicode "+new string('x',120));
                    Console.Error.WriteLine("stderr "+i+" $unicode "+new string('y',120));
                }
                return args[0]=="fail"?9:0;
            }
            Console.WriteLine("PS5.1 inherited-console receiver: UTF8/LF exact bytes PASS");
            return 0;
        }
    }
}
"@
    Add-Type -TypeDefinition $receiverSource -OutputAssembly $receiver -OutputType ConsoleApplication
    $script:sshExecutable = $receiver
    $script:askpassExecutable = 'unused-offline-stub'
    $result = Invoke-ProfileSsh -Arguments @() -InputText $publicPayload.Replace("`n", "`r`n")
    if ($result -ne 0) { throw ('Receiver failed: ' + $result) }
    $captured=Join-Path $fixture 'private-output.txt'
    $result=Invoke-ProfileSsh -Arguments @() -InputText $publicPayload -OutputPath $captured
    if($result -ne 0 -or [IO.File]::ReadAllText($captured) -notmatch 'exact bytes PASS'){throw 'Private stdout capture failed'}
    'Private stdout capture PASS; output saved to file without printing its contents.'
    $script:setupLogDirectory=Join-Path $fixture 'logs'
    [void][IO.Directory]::CreateDirectory($script:setupLogDirectory)
    $script:setupDetailed=$false
    $script:screen=New-Object 'Collections.Generic.List[string]'
    function Write-Host {param($Object,[switch]$NoNewline); [void]$script:screen.Add([string]$Object)}
    $result=Invoke-ProfileSsh -Arguments @('bulk') -InputText $publicPayload -Activity 'Fixture setup'
    if($result -ne 0){throw 'Concurrent stdout/stderr draining failed'}
    $logs=@(Get-ChildItem -LiteralPath $script:setupLogDirectory -File)
    $text=[IO.File]::ReadAllText($logs[0].FullName)
    if($text -notmatch 'stdout 1999' -or $text -notmatch 'stderr 1999' -or $text -notmatch $unicode){throw 'Detailed log lost lines or Unicode'}
    if(($script:screen -join "`n") -match 'stdout 1999|stderr 1999'){throw 'Compact mode printed detailed output'}
    $privateCapture=Join-Path $fixture 'secret-config.txt'
    $result=Invoke-ProfileSsh -Arguments @('private') -InputText $publicPayload -OutputPath $privateCapture -Activity 'Private fixture'
    foreach($file in @(Get-ChildItem -LiteralPath $script:setupLogDirectory -File)) {
        if([IO.File]::ReadAllText($file.FullName) -match 'PRIVATE_CONFIG_FIXTURE'){throw 'Private stdout entered a log'}
    }
    if([IO.File]::ReadAllText($privateCapture) -notmatch 'PRIVATE_CONFIG_FIXTURE'){throw 'Private file missing'}
    $script:setupDetailed=$true
    $script:screen.Clear()
    $result=Invoke-ProfileSsh -Arguments @('fail') -InputText $publicPayload -Activity 'Failure fixture'
    if($result -ne 9 -or ($script:screen -join "`n") -notmatch 'stdout 1999' -or ($script:screen -join "`n") -notmatch '\.log'){throw 'Verbose mode or failure reporting failed'}
    'Progress/logging PASS: large concurrent streams, Unicode, compact/verbose, failure exit, private stdout excluded.'
    # One display answer must not consume the following server-menu answer.
    function Read-Host {param($Prompt); if(-not $script:answers.Count){throw 'Unexpected extra input read'}; $script:answers.Dequeue()}
    foreach($case in @(
        @{Inputs=@('1');Detailed=$false},
        @{Inputs=@('');Detailed=$false},
        @{Inputs=@(' 1 ');Detailed=$false},
        @{Inputs=@('2');Detailed=$true},
        @{Inputs=@('bad','1');Detailed=$false}
    )) {
        $script:answers=New-Object Collections.Queue
        foreach($answer in $case.Inputs){$script:answers.Enqueue($answer)}
        $script:answers.Enqueue('2')
        Select-SetupOutputMode -Prompt
        if($script:setupDetailed -ne $case.Detailed -or $script:answers.Count -ne 1){throw 'Display choice read another menu answer'}
        $nextAnswer=Read-Host 'Server selection fixture'
        if($nextAnswer -ne '2' -or $script:setupDetailed -ne $case.Detailed){throw 'Server answer changed display mode'}
    }
    $script:answers=New-Object Collections.Queue
    Select-SetupOutputMode -Detailed
    if(-not $script:setupDetailed){throw 'Explicit verbose flag ignored'}
    Select-SetupOutputMode
    if($script:setupDetailed){throw 'Default should be compact'}
    'Display mode PASS: one answer, Enter, whitespace, invalid input, explicit flag; later menu does not change mode.'
    'Main parser PASS; actual Invoke-ProfileSsh stdin PASS; no SSH or key generation executed.'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $expectedRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path' }
    [IO.Directory]::Delete($resolved, $true)
}
