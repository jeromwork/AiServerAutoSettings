#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'build/Wizard.Common.ps1')
[void][IO.Directory]::CreateDirectory($TestHome)
$script:checks=0
function Assert($Ok,[string]$Why){if(-not $Ok){throw $Why};$script:checks++}
function Get-WizardSystemSsh {$script:systemSsh}
function Test-WizardSshRuns([string]$Ssh){$script:runs}
function New-SshBundle([string]$Path) {
    [void][IO.Directory]::CreateDirectory((Join-Path $Path 'build'))
    [void][IO.Directory]::CreateDirectory((Join-Path $Path 'openssh'))
    $rows=@(foreach($name in @('ssh-keygen.exe','libcrypto.dll','ssh.exe')){
        $file=Join-Path $Path ('openssh/'+$name)
        [IO.File]::WriteAllBytes($file,[Text.Encoding]::UTF8.GetBytes('fixture '+$name))
        @{name=$name;url='https://example.invalid/openssh.zip';sha256=('0'*64);member=('OpenSSH-Win64/'+$name);memberSha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLower();target=('openssh/'+$name)}
    })
    Write-TransportJson (Join-Path $Path 'build/bundle-binaries.json') @{schema=1;binaries=$rows}
}
$oldPath=$env:PATH
try {
    # A clean Windows installation has neither ssh nor ssh-keygen on PATH.
    $env:PATH=(New-Item -ItemType Directory (Join-Path $TestHome 'empty-path')).FullName
    $bundle=Join-Path $TestHome 'bundle';New-SshBundle $bundle
    $root1=Join-Path $TestHome 'embedded-first'
    $script:runs=$true;$script:systemSsh='/usr/bin/sys-ssh'
    $own=Join-Path $root1 'transport-bin/openssh/ssh.exe'
    Assert ((Find-WizardSsh $root1 $bundle) -eq $own) 'embedded SSH wins over system SSH with an empty PATH'
    foreach($name in @('ssh-keygen.exe','libcrypto.dll','ssh.exe')){
        $copy=Join-Path $root1 ('transport-bin/openssh/'+$name)
        Assert (Test-Path -LiteralPath $copy -PathType Leaf) ('copied '+$name)
        Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($copy)) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $bundle ('openssh/'+$name))))) ('same bytes for '+$name)
    }
    Assert (@(Get-ChildItem -LiteralPath (Split-Path $own -Parent) -Filter '*.tmp').Count -eq 0) 'no temporary files remain'

    Remove-Item -LiteralPath $bundle -Recurse -Force
    Assert ((Find-WizardSsh $root1 $bundle) -eq $own) 'copied SSH survives removal of its bundle'

    New-SshBundle $bundle
    $root=Join-Path $TestHome 'system-fallback';$script:runs=$false
    Assert ((Find-WizardSsh $root $bundle) -eq '/usr/bin/sys-ssh') 'system SSH is used when embedded SSH cannot run'
    $log=Join-Path $root 'logs/setup.log'
    Assert ((Test-Path -LiteralPath $log) -and [IO.File]::ReadAllText($log).Contains('openssh.embedded.unavailable')) 'system fallback is logged'

    $root=Join-Path $TestHome 'bad-hash';$script:runs=$true;$script:systemSsh=$null
    $pins=Join-Path $bundle 'build/bundle-binaries.json';$data=Read-TransportJson $pins
    @($data.binaries|Where-Object {$_.target -eq 'openssh/ssh.exe'})[0].memberSha256='0'*64
    Write-TransportJson $pins $data
    $failure='';try{[void](Find-WizardSsh $root $bundle)}catch{$failure=$_.Exception.Message}
    Assert ($failure -like '*Не найден клиент SSH*') 'bad hash gives a clear missing SSH error'
    Assert (-not (Test-Path -LiteralPath (Join-Path $root 'transport-bin/openssh/ssh.exe'))) 'bad hash never installs ssh.exe'

    $root=Join-Path $TestHome 'empty-bundle'
    Write-TransportJson $pins @{schema=1;binaries=@()}
    $failure='';try{[void](Find-WizardSsh $root $bundle)}catch{$failure=$_.Exception.Message}
    Assert ($failure -like '*Не найден клиент SSH*') 'missing embedded and system SSH gives a clear error'

    Assert ((Get-WizardKeygen $own) -eq (Join-Path $root1 'transport-bin/openssh/ssh-keygen.exe')) 'keygen next to selected SSH works with an empty PATH'
} finally {
    $env:PATH=$oldPath
}
"PASS test-ssh-resolve ($script:checks checks)"
