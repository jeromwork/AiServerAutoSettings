$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot 'server-desktop.ps1'
$bootstrap = Join-Path $PSScriptRoot 'server-desktop-bootstrap.sh'
$tokens = $null; $parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$parseErrors) | Out-Null
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$shell = 'C:\Program Files\Git\bin\bash.exe'
if (-not [IO.File]::Exists($shell)) { throw 'Git Bash is required for the offline shell syntax check.' }
& $shell -n $bootstrap
if ($LASTEXITCODE -ne 0) { throw 'Bootstrap shell syntax failed.' }
& $shell -n (Join-Path $PSScriptRoot 'server-desktop-audio.sh')
if ($LASTEXITCODE -ne 0) { throw 'Audio bootstrap shell syntax failed.' }
# Stock xrdp hit-tests children in insertion order: its logo is before buttons.
# Explicit logo bounds must therefore stay clear of the session and buttons.
$bootstrapText = [IO.File]::ReadAllText($bootstrap)
Add-Type -AssemblyName System.Drawing
$layout = @{}
foreach ($match in [regex]::Matches($bootstrapText,'(?m)^(ls_[a-z_]+)=(\d+)\r?$')) {
    $layout[$match.Groups[1].Value] = [int]$match.Groups[2].Value
}
if ($bootstrapText -notmatch '(?m)^ls_logo_transform=scale\r?$') { throw 'Explicit logo scaling is required.' }
$logo = New-Object Drawing.Rectangle($layout.ls_logo_x_pos,$layout.ls_logo_y_pos,$layout.ls_logo_width,$layout.ls_logo_height)
foreach ($name in @('ok','cancel')) {
    $button = New-Object Drawing.Rectangle($layout["ls_btn_${name}_x_pos"],$layout["ls_btn_${name}_y_pos"],$layout["ls_btn_${name}_width"],$layout["ls_btn_${name}_height"])
    if ($logo.IntersectsWith($button)) { throw "The logo intercepts $name clicks." }
    if ($button.Bottom -ge $layout.ls_height) { throw 'Button outside the login window.' }
}
if ($logo.Bottom -ge $layout.ls_input_y_pos) { throw 'The logo intercepts the session selector.' }
$oldLogo = New-Object Drawing.Rectangle(63,50,240,140)
$oldButton = New-Object Drawing.Rectangle(140,105,85,30)
if (-not $oldLogo.Contains($oldButton)) { throw 'The regression fixture no longer reproduces the stock logo interception.' }
$testDir = Join-Path ([IO.Path]::GetTempPath()) ('remoteagents-desktop-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testDir) | Out-Null
$fixture = Join-Path $testDir 'public-fixture.exe'
$rdp = Join-Path $testDir 'public-fixture.rdp'
try {
    Add-Type -OutputAssembly $fixture -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
using System.Text;
public class PublicDesktopFixture {
    public static void Main(string[] args) {
        using (MemoryStream bytes = new MemoryStream()) {
            Console.OpenStandardInput().CopyTo(bytes);
            Console.WriteLine(Convert.ToBase64String(bytes.ToArray()));
        }
        Console.WriteLine(args.Length);
        foreach (string arg in args) Console.WriteLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(arg)));
    }
}
'@
    . $helper -SSHExecutable $fixture
    Initialize-DesktopProbe
    $publicText = 'public-' + [char]0x4e2d + '-' + [char]0x044f + "`n"
    $publicBytes = [Text.Encoding]::UTF8.GetBytes($publicText)
    $arguments = @('space path','quote"inside','trailing\','two\\"quotes','')
    $result = Invoke-DesktopSsh $arguments $publicBytes
    Assert-DesktopSshResult $result
    $lines = $result.Output -split "`r?`n"
    if ($lines[0] -cne [Convert]::ToBase64String($publicBytes)) { throw 'UTF8 stdin bytes changed.' }
    if ([int]$lines[1] -ne $arguments.Count) { throw 'Native argument count changed.' }
    for ($index=0; $index -lt $arguments.Count; $index++) {
        $actual = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($lines[$index+2]))
        if ($actual -cne $arguments[$index]) { throw "Native argument $index changed." }
    }
    $freePort = Get-DesktopFreePort
    if ($freePort -lt 1 -or $freePort -gt 65535) { throw 'Invalid loopback port.' }
    Write-DesktopRdpFile $rdp 12345 'remoteagents'
    $content = [IO.File]::ReadAllText($rdp)
    foreach ($required in @('full address:s:127.0.0.1:12345','username:s:remoteagents','authentication level:i:2','redirectclipboard:i:1','prompt for credentials:i:0','enablecredsspsupport:i:0','audiomode:i:0','audiocapturemode:i:0')) {
        if (-not $content.Contains($required)) { throw "Missing RDP setting $required" }
    }
    if ($content -match 'password 51|authentication level:i:0') { throw 'Unsafe RDP file.' }
    if ([RemoteAgentsDesktopProbe]::Test(0,('0' * 64))) { throw 'Invalid RDP endpoint accepted.' }
    if ([IO.File]::ReadAllText($helper) -match 'chpasswd|Set-DesktopPasswordWithDialog|passwd -S') { throw 'Linux password flow returned.' }
    Write-Output 'PASS: PS parser, Bash syntax, logo/button hit-test regression, .NET probe compile, native argv/UTF8 stdin roundtrip, RDP settings, loopback allocation.'
} finally {
    foreach ($path in @($fixture,$rdp)) { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
    if ([IO.Directory]::Exists($testDir)) { [IO.Directory]::Delete($testDir) }
}
