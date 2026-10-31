$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Run with Windows PowerShell 5.1.' }
$sourcePath = Join-Path $PSScriptRoot 'setup-vps-ssh.ps1'
$tokens = $null; $parseErrors = $null
$tree = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Convert-SshArgument','Invoke-ProfileSsh')) {
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
    public static int Main() {
        using (var input = Console.OpenStandardInput())
        using (var output = new MemoryStream()) {
            input.CopyTo(output);
            var value = output.ToArray();
            if (Convert.ToBase64String(value) != "$expected") return 21;
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
    'Main parser PASS; actual Invoke-ProfileSsh stdin PASS; no SSH or key generation executed.'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $expectedRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path' }
    [IO.Directory]::Delete($resolved, $true)
}
