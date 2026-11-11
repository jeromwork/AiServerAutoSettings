#requires -Version 5.1
function Install-DiskBinary($Url,$Hash,$Directory,$Name,[string]$Base=$script:DiskHome) {
    $dest=Join-Path $Base $Directory;$marker=Join-Path $dest 'release.txt'
    if((Test-Path -LiteralPath (Join-Path $dest $Name)) -and (Test-Path -LiteralPath $marker) -and [IO.File]::ReadAllText($marker) -eq $Hash){return}
    [void][IO.Directory]::CreateDirectory($dest);$tmp=Join-Path $Base ([IO.Path]::GetRandomFileName());[void][IO.Directory]::CreateDirectory($tmp)
    try{$zip=Join-Path $tmp 'release.zip';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest $Url -OutFile $zip -UseBasicParsing -TimeoutSec 90
        if((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ine $Hash){throw 'SHA256 mismatch'}
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $tmp 'unpacked');$exe=@(Get-ChildItem -LiteralPath (Join-Path $tmp 'unpacked') -Filter $Name -Recurse -File);if($exe.Count -ne 1){throw 'Неверный архив'}
        $target=[IO.Path]::GetFullPath((Join-Path $dest $Name));Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Name)) -ErrorAction SilentlyContinue|Where-Object {$_.Path -and [IO.Path]::GetFullPath($_.Path) -ieq $target}|ForEach-Object {Stop-Process -Id $_.Id -Force -ErrorAction Stop;$_.WaitForExit()}
        Copy-Item -LiteralPath $exe[0].FullName -Destination (Join-Path $dest $Name) -Force;Write-DiskUtf8 $marker $Hash
    }finally{Remove-Item -LiteralPath $tmp -Recurse -Force}
}
