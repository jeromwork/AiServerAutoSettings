#requires -Version 5.1
$ErrorActionPreference='Stop'
$budget = if ($env:DISK_TEST_BUDGET_S) { [double]$env:DISK_TEST_BUDGET_S } else { 30 }
$watch=[Diagnostics.Stopwatch]::StartNew();$tmp=Join-Path ([IO.Path]::GetTempPath()) ('disk-install-'+[IO.Path]::GetRandomFileName());[void][IO.Directory]::CreateDirectory($tmp)
function Assert($Value,$Message){if(-not $Value){throw $Message}}
$checks=@()
try {
    foreach($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1'){$tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors);Assert ($errors.Count -eq 0) ('Parse: '+$file.Name)}
    . (Join-Path $PSScriptRoot 'Disk.Common.ps1')
    # Independent suites use disjoint HOME/state. Overlap their process/JIT
    # startup with the adapter/binary checks below, within the same aggregate budget.
    $exe=(Get-Process -Id $PID).Path
    foreach($case in @(@{file='test-engine.ps1';home='lifecycle'},@{file='test-startup.ps1';home='startup'})){
        $si=New-Object Diagnostics.ProcessStartInfo;$si.FileName=$exe
        $si.Arguments=(@('-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot $case.file),'-TestHome',(Join-Path $tmp $case.home))|ForEach-Object {Quote-Disk $_}) -join ' '
        $si.UseShellExecute=$false;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
        $si.StandardOutputEncoding=New-Object Text.UTF8Encoding($false);$si.StandardErrorEncoding=New-Object Text.UTF8Encoding($false)
        $p=[Diagnostics.Process]::Start($si)
        $checks+=@{process=$p;out=$p.StandardOutput.ReadToEndAsync();err=$p.StandardError.ReadToEndAsync();name=$case.file}
    }
    $secret='synthetic-output-marker';$ini=New-DiskIni 'C:\Test User\tray\syncthingtray.exe' 'C:\Test User\state' '127.0.0.1:8384' $secret
    Assert ($ini.Contains('connections\1\apiKey='+$secret) -and $ini.Contains('syncthingPath=C:/Test User/tray/syncthingtray.exe')) 'INI fields'
    Assert ($ini.Contains('--home \"C:/Test User/state\"') -and -not $ini.Contains("`r") -and $ini.Contains('useLibSyncthing=false')) 'INI launcher'
    $file=Join-Path $tmp 'syncthingtray.ini';$captured=@(Write-DiskUtf8 $file $ini);$bytes=[IO.File]::ReadAllBytes($file)
    Assert ($captured.Count -eq 0 -and $bytes[0] -eq 91 -and $bytes -notcontains 13) 'UTF8 without BOM or CR, silent write'
    $script:DiskHome=Join-Path $tmp 'RemoteDisk';$profile=Join-Path $tmp 'profile.json';$connection=@{sshExecutable='ssh';arguments=@('test');serverAddress='test.invalid';login='root';keyPath='unused';knownHostsPath='unused';configPath='unused'}
    Write-DiskUtf8 $profile ($connection|ConvertTo-Json);$refused=$false;try{Read-DiskProfile $profile}catch{$refused=$_.Exception.Message -eq 'SSH-профиль должен входить как рабочий пользователь, не root'};Assert $refused 'Root profile rejected'
    $connection.login='tester';Write-DiskUtf8 $profile ($connection|ConvertTo-Json);Read-DiskProfile $profile;Assert ($script:Connection.login -eq 'tester') 'Working user accepted'
    # Two SSH profiles (old setup + config) and no RemoteDisk yet: the launcher's chosen profile wins, no 'need one profile' refusal.
    $oldLocal=$env:LOCALAPPDATA;$env:LOCALAPPDATA=Join-Path $tmp 'local';try{
        $ra=Join-Path $env:LOCALAPPDATA 'RemoteAgents';foreach($n in @('old','new')){$d=Join-Path $ra ('ssh-profiles/'+$n+'/project-connections/control');[void][IO.Directory]::CreateDirectory($d);$connection.login='user-'+$n;Write-DiskUtf8 (Join-Path $d 'ssh-transport.json') ($connection|ConvertTo-Json)}
        Write-DiskUtf8 (Join-Path $ra 'config.json') (@{transport=@{profilePath=(Join-Path $ra 'ssh-profiles/new/project-connections/control/ssh-transport.json')}}|ConvertTo-Json)
        Read-DiskProfile '';Assert ($script:Connection.login -eq 'user-new') 'Launcher-chosen profile wins over a stale one'
    }finally{$env:LOCALAPPDATA=$oldLocal;$connection.login='tester'}
    $state=Join-Path $script:DiskHome 'state';[void][IO.Directory]::CreateDirectory($state);$config=Join-Path $state 'config.xml';$xml='<?xml version="1.0" encoding="utf-8"?>'+"`n"+'<configuration><!--keep--><gui><address>127.0.0.1:8384</address><apikey>test</apikey></gui>'+"`n  "+'<folder id="keep"><device id="peer"><encryptionPassword></encryptionPassword></device><label>  keep  </label></folder>'+"`n"+'<options><natEnabled>true</natEnabled></options></configuration>'
    Write-DiskUtf8 $config $xml;Read-DiskState;$before=$script:Engine.configuration.folder.OuterXml;Save-DiskState @{natEnabled=$false;listenAddresses=@('tcp://127.0.0.1:22000')};$saved=[IO.File]::ReadAllText($config);Read-DiskState
    Assert ($script:Engine.PreserveWhitespace -and $script:Engine.configuration.folder.OuterXml -ceq $before -and $saved.Contains('<encryptionPassword></encryptionPassword>') -and -not $saved.Contains('&#xD;') -and $saved.Replace($script:Engine.configuration.options.OuterXml,'<options><natEnabled>true</natEnabled></options>') -ceq $xml) 'XML save preserves empty passwords and unrelated document'
    Assert ($script:Engine.configuration.options.natEnabled -ceq 'false' -and $script:Engine.configuration.options.listenAddress -ceq 'tcp://127.0.0.1:22000') 'XML options updated and appended'
    # Exercise the real UTF-8 REST adapter, including PS 5.1's JSON-array pipeline behavior.
    function Invoke-WebRequest {
        param($Uri,$Method,$Headers,$TimeoutSec,$UseBasicParsing,$Body,$ContentType,$MaximumRedirection)
        Assert ($MaximumRedirection -eq 0) 'REST never follows redirects outside loopback'
        $script:apiUri=[string]$Uri
        $stream=New-Object IO.MemoryStream(,[Text.Encoding]::UTF8.GetBytes($script:ApiResponse))
        [pscustomobject]@{RawContentStream=$stream}
    }
    $script:Gui=$null;$script:ApiKey=$null;$script:ApiResponse='{"myID":"lazy"}';$null=Invoke-DiskApi 'system/status'
    Assert ($script:Gui -eq '127.0.0.1:8384' -and $script:ApiKey -eq 'test') 'REST lazily loads existing engine state'
    $script:ApiResponse='[{"id":"first","label":"Первый"},{"id":"second"}]'
    $captured=@(Invoke-DiskApi 'config/folders');Assert ($captured.Count -eq 2 -and $captured[0].label -ceq 'Первый' -and $captured[1].id -ceq 'second') 'REST emits UTF-8 JSON folders individually on PS5/PS7'
    foreach($case in @(@{json='[]';count=0},@{json='null';count=0},@{json='';count=0},@{json='false';count=1},@{json='0';count=1},@{json='{"myID":"local"}';count=1})){
        $script:ApiResponse=$case.json;$captured=@(Invoke-DiskApi 'system/status');Assert ($captured.Count -eq $case.count) 'REST handles empty and scalar responses'
    }
    foreach($gui in @('192.0.2.1:8384','localhost:8384','127.0.0.1:8384@server.invalid','127.0.0.1:8384/elsewhere')){
        $script:Gui=$gui;$failed=$false;try{$null=Invoke-DiskApi 'system/status'}catch{$failed=$true};Assert $failed 'REST refuses a non-loopback endpoint'
    }
    $script:Gui='127.0.0.1:8384'
    Remove-Item Function:Invoke-WebRequest
    $file=Join-Path $tmp 'native.json';$captured=@(Invoke-DiskProcess $exe @('-NoProfile','-Command',('[Console]::Write("'+$secret+'")')) '' $file)
    Assert ($captured.Count -eq 0 -and [IO.File]::ReadAllText($file) -eq $secret) 'Native output stays in file'
    $failure='';try{Invoke-DiskProcess $exe @('-NoProfile','-Command',('[Console]::Error.Write("'+$secret+'");exit 4'))}catch{$failure=$_|Out-String;$nativeFailure=$_}
    Assert ($failure.Contains('код выхода 4') -and -not $failure.Contains($secret)) 'Native failure contains exit code without secrets'
    Write-DiskLog 'Native test' $nativeFailure;$log=Join-Path $script:DiskHome 'install.log';$text=[IO.File]::ReadAllText($log)
    Assert ($text -match '^\d{4}-\d\d-\d\dT' -and $text.Contains('[Native test]') -and $text.Contains('код выхода 4') -and $text.Contains('Disk.Common.ps1') -and -not $text.Contains($secret)) 'Failure log: time, step, reason, position, no stderr'
    [IO.File]::WriteAllText($log,('x'*(256KB+1)));Write-DiskLog 'Install test';Assert ((Get-Item -LiteralPath $log).Length -lt 256KB -and [IO.File]::ReadAllText($log).Contains('[Install test] Успех')) 'Log rotation and success'
    $oldProfile=$env:USERPROFILE;try{$env:USERPROFILE=Join-Path $tmp 'Test User';Assert ((Get-DiskBase) -eq (Join-Path $tmp 'Test User/Disk')) 'Default base is the profile Disk folder'}finally{$env:USERPROFILE=$oldProfile}
    . (Join-Path $PSScriptRoot 'Disk.Binary.ps1')
    function Invoke-WebRequest {param($Uri,$OutFile,[switch]$UseBasicParsing,$TimeoutSec) Copy-Item -LiteralPath $script:Archive -Destination $OutFile;$script:Downloads++}
    function Get-Process {param($Name,$ErrorAction) $script:FakeProcesses}
    function Stop-Process {param($Id,[switch]$Force,$ErrorAction) $script:Stopped+=@($Id)}
    foreach($name in @('syncthingtray.exe','sing-box.exe')){
        $source=Join-Path $tmp $name;Write-DiskUtf8 $source 'new binary';$script:Archive=Join-Path $tmp ($name+'.zip');Compress-Archive -LiteralPath $source -DestinationPath $script:Archive;$hash=(Get-FileHash -LiteralPath $script:Archive).Hash
        $dest=Join-Path $script:DiskHome $name;[void][IO.Directory]::CreateDirectory($dest);$target=Join-Path $dest $name;Write-DiskUtf8 $target 'old binary'
        $script:Stopped=@();$script:Waited=@();$script:Downloads=0;$script:FakeProcesses=@([pscustomobject]@{Id=1001;Path=$target},[pscustomobject]@{Id=1002;Path=$source})
        foreach($process in $script:FakeProcesses){$process|Add-Member ScriptMethod WaitForExit {$script:Waited+=@($this.Id)}}
        Install-DiskBinary 'https://test.invalid' $hash $name $name;Install-DiskBinary 'https://test.invalid' $hash $name $name
        Assert ($script:Stopped.Count -eq 1 -and $script:Stopped[0] -eq 1001 -and $script:Waited.Count -eq 1 -and $script:Downloads -eq 1 -and [IO.File]::ReadAllText($target) -eq 'new binary') 'Update stops only the target executable; matching release skipped'
    }
    foreach($check in $checks){
        Assert ($check.process.WaitForExit(45000)) ('Child suite timeout: '+$check.name)
        Assert ($check.process.ExitCode -eq 0) ('Child suite failed: '+$check.name)
        Write-Output $check.out.GetAwaiter().GetResult()
    }
    Assert ($watch.Elapsed.TotalSeconds -lt $budget) ('PowerShell time budget: '+[Math]::Round($watch.Elapsed.TotalSeconds,2)+'s; budget '+$budget+'s');Write-Output ('install: exit 0, {0:N2}s' -f $watch.Elapsed.TotalSeconds)
}finally{
    foreach($check in $checks){try{if(-not $check.process.HasExited){$check.process.Kill();$check.process.WaitForExit()}}finally{$check.process.Dispose()}}
    Remove-Item -LiteralPath $tmp -Recurse -Force
}
