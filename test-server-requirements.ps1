$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'setup-vps-ssh.ps1'),[ref]$tokens,[ref]$errors)
$node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-SupportedServer'},$true)
Invoke-Expression $node.Extent.Text
$common=@();$keyPath='unused-fixture';$ServerAddress='example.invalid'
function Invoke-ProfileSsh {
    param($Arguments)
    $command=$Arguments[-1].Replace('. /etc/os-release',('ID='+$script:osId+'; VERSION_ID='+$script:osVersion))
    $command=('uname() { printf ''%s\n'' '''+$script:arch+'''; }; ')+$command
    $probeFile=[IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($probeFile,$command,(New-Object Text.UTF8Encoding($false)))
        $output=& 'C:\Program Files\Git\bin\bash.exe' $probeFile.Replace('\','/') 2>&1
        return $LASTEXITCODE
    } finally { [IO.File]::Delete($probeFile) }
}
foreach($case in @(
    @{Id='ubuntu';Version='24.04';Arch='x86_64';Allowed=$true},
    @{Id='ubuntu';Version='22.04';Arch='x86_64';Allowed=$false},
    @{Id='rhel';Version='9';Arch='x86_64';Allowed=$false},
    @{Id='ubuntu';Version='24.04';Arch='aarch64';Allowed=$false}
)) {
    $script:osId=$case.Id;$script:osVersion=$case.Version;$script:arch=$case.Arch
    $accepted=$true
    try{Assert-SupportedServer}catch{$accepted=$false}
    if($accepted -ne $case.Allowed){throw ('OS gate failed: '+$case.Id+' '+$case.Version+' '+$case.Arch)}
}
Write-Output 'PASS: actual Bash OS probe accepts Ubuntu 24.04 x86_64 and rejects RHEL, other Ubuntu and ARM; no SSH or packages.'
