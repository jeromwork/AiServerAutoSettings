# Synthetic public names only. Never inspects the selected project or secret contents.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Sync.Workspace.ps1')
$denied=@('.env','.env.local','auth.json','.npmrc','.pypirc','.netrc','credentials.json','credentials-local','secrets.json','privatekeys','id_rsa','id_ed25519','id_custom.json','server.pem','server.key','server.p12','server.pfx','.ssh','ssh','.git','node_modules','vendor','deps','dependencies','build','dist','obj','bin','logs','cache','db','database','backups','data.sqlite','data.sqlite3','data.db','data.db3','site.bak','backup.sql','dump.sql','uploads')
$python=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'server-sync.py'))
$nameMatch=[regex]::Match($python,"(?m)^DENIED = re.compile\(r'([^']+)'\)")
$extMatch=[regex]::Match($python,"(?m)^DENIED_EXT = re.compile\(r'([^']+)'\)")
if(!$nameMatch.Success -or !$extMatch.Success) { throw 'Server fence unavailable' }
foreach($name in $denied) {
    if(!(Test-SyncDenied $name)) { throw 'Windows secret fence missed a synthetic name' }
    if($name -notmatch $nameMatch.Groups[1].Value -and $name -notmatch $extMatch.Groups[1].Value) { throw 'Server secret fence missed a synthetic name' }
}
$fixture=Join-Path $env:TEMP ('remoteagents-fence-'+[guid]::NewGuid().ToString('N'))
try {
    $src=Join-Path $fixture 'src'; [void](New-Item -ItemType Directory -Path $src -Force)
    [IO.File]::WriteAllText((Join-Path $src 'index.js'),'public fixture')
    foreach($name in $denied) { [IO.File]::WriteAllBytes((Join-Path $src $name),[byte[]]@()) }
    foreach($dir in @('deps','db','backups','uploads','credentials-store')) {
        $path=Join-Path $src $dir
        if(Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path }
        [void](New-Item -ItemType Directory -Path $path)
        [IO.File]::WriteAllText((Join-Path $path 'should-not-transfer.json'),'public fixture')
    }
    $files=@(Get-SyncInventory -Root $fixture -AllowedRoots @('src') -Hash)
    if($files.Count -ne 1 -or $files[0].path -ne 'src/index.js') { throw 'Synthetic inventory escaped exclusion fence' }
    $workspace=Join-Path $PSScriptRoot 'Sync.Workspace.ps1'
    $module=New-Module -ArgumentList $workspace -ScriptBlock {param($path) . $path;Export-ModuleMember -Function *}
    $scoped=@(& $module {param($root) Get-SyncInventory -Root $root -AllowedRoots @('src') -Hash} $fixture)
    if($scoped.Count -ne 1 -or $scoped[0].sha256 -cne $files[0].sha256) { throw 'Module-scoped SHA256 unavailable or inconsistent' }
    Write-Output ('PASS: secret fence '+$denied.Count+' names, both policies; synthetic inventory allowed=1')
} finally {
    if(Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
