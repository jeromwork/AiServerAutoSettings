#requires -Version 5.1
$ErrorActionPreference='Stop'
$common=Join-Path $PSScriptRoot 'Transport.Common.ps1'
if(-not (Test-Path $common)){$common=Join-Path $PSScriptRoot 'Transport.Common.ps1'}
. $common
$work=Join-Path ([IO.Path]::GetTempPath()) ('transport-json-'+[guid]::NewGuid().ToString('N'))
$file=Join-Path $work 'status/transport.json';$writer=$null
try{
    Write-TransportJson $file @{generation=0;payload=('я'*32768)}
    $writer=Start-Job -ArgumentList $common,$file -ScriptBlock {
        param($common,$file)
        . $common
        for($i=1;$i -le 250;$i++){Write-TransportJson $file @{generation=$i;payload=('я'*32768)}}
    }
    $reads=0
    do{
        $s=Read-TransportJson $file
        if($null -eq $s -or $s.payload -cne ('я'*32768) -or $null -eq $s.generation){throw 'Прочитан неполный JSON'}
        $reads++
    }while($writer.State -in @('NotStarted','Running') -or $reads -lt 250)
    Receive-Job $writer -ErrorAction Stop|Out-Null
    if($writer.State -ne 'Completed' -or (Read-TransportJson $file).generation -ne 250){throw 'Писатель не завершён'}
    [IO.File]::WriteAllText($file,"{`r`n`"ok`":true`r`n}")
    if(-not (Read-TransportJson $file).ok){throw 'CRLF не прочитан'}
    [IO.File]::WriteAllText($file,'broken');$rejected=$false
    try{Read-TransportJson $file|Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw 'Повреждённый JSON принят'}
    # На Windows проверяем реальную sharing violation и освобождение блокировки в пределах повтора.
    if($env:OS -eq 'Windows_NT'){
        Write-TransportJson $file @{ok=$true}
        $lock=Start-Job -ArgumentList $file,$work -ScriptBlock {
            param($file,$work)
            $s=[IO.File]::Open($file,'Open','Read','None')
            try{[IO.File]::WriteAllText((Join-Path $work 'locked'),'');Start-Sleep -Milliseconds 350}finally{$s.Dispose()}
        }
        try{
            $watch=[Diagnostics.Stopwatch]::StartNew()
            while(-not (Test-Path (Join-Path $work 'locked'))){if($watch.Elapsed.TotalSeconds -gt 15){throw 'Блокировка не создана'};Start-Sleep -Milliseconds 10}
            if(-not (Read-TransportJson $file).ok){throw 'Повтор чтения не удался'}
            Receive-Job $lock -Wait -ErrorAction Stop|Out-Null
        }finally{Remove-Job $lock -Force}
    }
    Write-Host ('PASS: чтение при атомарной записи, CRLF и ошибки JSON; снимков: '+$reads)
}finally{if($writer){Remove-Job $writer -Force};Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue}
