#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][Alias('Home')][string]$LauncherHome)
$ErrorActionPreference='Stop'
try {
    if($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -lt 1){throw 'Самопроверка требует Windows PowerShell 5.1'}
    foreach($name in @('components.json','bundle-version.txt','bundle-files.txt')) {
        if(-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)){throw 'Нет обязательного файла'}
    }
    foreach($name in [IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'bundle-files.txt'))) {
        if($name -and -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)){throw 'Неполный бандл'}
    }
    $definition=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'components.json')))
    # @() also handles PowerShell 5.1 ConvertFrom-Json array enumeration rules.
    $items=@($definition)
    if($definition.PSObject.Properties['components']){$items=@($definition.components)}
    if($items.Count -eq 0){throw 'Нет компонентов'}
    foreach($c in $items){
        $arguments=@($c.args)
        for($i=0;$i -lt $arguments.Count-1;$i++){
            if($arguments[$i] -ieq '-File' -and ([string]$arguments[$i+1]).StartsWith('{bundle}')){
                $scriptPath=([string]$arguments[$i+1]).Replace('{bundle}',$PSScriptRoot)
                if(-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)){throw 'Нет скрипта компонента'}
            }
        }
    }
    foreach($file in @(Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -Filter '*.ps1' -File)) {
        $tokens=$null;$errors=$null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        if(@($errors).Count -gt 0){throw 'Скрипт не разбирается PowerShell 5.1'}
    }
    Write-Output 'Бандл проверен парсером Windows PowerShell 5.1.'
    exit 0
} catch {
    # Never echo parsed source lines, paths from a profile, or exception contents.
    Write-Output 'Самопроверка бандла не пройдена: проверьте комплектность и PowerShell 5.1.'
    exit 1
}
