#requires -Version 5.1
$ErrorActionPreference='Stop'
$watch=[Diagnostics.Stopwatch]::StartNew();$tmp=Join-Path ([IO.Path]::GetTempPath()) ('disk-install-'+[IO.Path]::GetRandomFileName());[void][IO.Directory]::CreateDirectory($tmp)
function Assert($Value,$Message){if(-not $Value){throw $Message}}
try {
    foreach($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1'){$tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors);Assert ($errors.Count -eq 0) ('Parse: '+$file.Name)}
    . (Join-Path $PSScriptRoot 'Disk.Common.ps1')
    $secret='synthetic-output-marker';$ini=New-DiskIni 'C:\Test User\tray\syncthingtray.exe' 'C:\Test User\state' '127.0.0.1:8384' $secret
    Assert ($ini.Contains('connections\1\apiKey='+$secret) -and $ini.Contains('syncthingPath=C:/Test User/tray/syncthingtray.exe')) 'INI fields'
    Assert ($ini.Contains('--home \"C:/Test User/state\"') -and -not $ini.Contains("`r") -and $ini.Contains('useLibSyncthing=false')) 'INI launcher'
    $file=Join-Path $tmp 'syncthingtray.ini';$captured=@(Write-DiskUtf8 $file $ini);$bytes=[IO.File]::ReadAllBytes($file)
    Assert ($captured.Count -eq 0 -and $bytes[0] -eq 91 -and $bytes -notcontains 13) 'UTF8 without BOM or CR, silent write'
    $hop=New-DiskHop "hostname hop.invalid`nuser tester`nidentityfile C:/Test User/key`nidentityfile ignored`nport 2200"
    Assert ($hop.server -eq 'hop.invalid' -and $hop.server_port -eq 2200 -and $hop.private_key_path -eq 'C:/Test User/key') 'SSH profile'
    $hop=New-DiskHop "hostname hop.invalid`r`nuser tester`r`nidentityfile `"C:/Test User/key`"`r`nidentityfile ignored`r`nport 2200`r`n"
    Assert ($hop.server -ceq 'hop.invalid' -and $hop.user -ceq 'tester' -and $hop.server_port -eq 2200 -and $hop.private_key_path -ceq 'C:/Test User/key' -and $hop.private_key_path -notmatch '[\x00-\x1f\x7f]') 'CRLF SSH values have no control characters'
    $oldProfile=$env:USERPROFILE;try{$env:USERPROFILE='C:\Users\Test User';foreach($key in @('~/.ssh/key','~\.ssh\key','%d/.ssh/key','%d\.ssh\key')){$hop=New-DiskHop ("hostname hop.invalid`nuser tester`nidentityfile "+$key+"`nport 22");Assert ($hop.private_key_path.Replace('\','/') -eq 'C:/Users/Test User/.ssh/key') 'Expanded identityfile'}}finally{$env:USERPROFILE=$oldProfile}
    $script:DiskHome=Join-Path $tmp 'RemoteDisk';$profile=Join-Path $tmp 'profile.json';$connection=@{sshExecutable='ssh';arguments=@('test');serverAddress='test.invalid';login='root';keyPath='unused';knownHostsPath='unused';configPath='unused'}
    Write-DiskUtf8 $profile ($connection|ConvertTo-Json);$refused=$false;try{Read-DiskProfile $profile}catch{$refused=$_.Exception.Message -eq 'SSH-профиль должен входить как рабочий пользователь, не root'};Assert $refused 'Root profile rejected'
    $connection.login='tester';Write-DiskUtf8 $profile ($connection|ConvertTo-Json);Read-DiskProfile $profile;Assert ($script:Connection.login -eq 'tester') 'Working user accepted'
    $state=Join-Path $script:DiskHome 'state';[void][IO.Directory]::CreateDirectory($state);$config=Join-Path $state 'config.xml';$xml='<?xml version="1.0" encoding="utf-8"?>'+"`n"+'<configuration><!--keep--><gui><address>127.0.0.1:8384</address><apikey>test</apikey></gui>'+"`n  "+'<folder id="keep"><device id="peer"><encryptionPassword></encryptionPassword></device><label>  keep  </label></folder>'+"`n"+'<options><natEnabled>true</natEnabled></options></configuration>'
    Write-DiskUtf8 $config $xml;Read-DiskState;$before=$script:Engine.configuration.folder.OuterXml;Save-DiskState @{natEnabled=$false;listenAddresses=@('tcp://127.0.0.1:22000')};$saved=[IO.File]::ReadAllText($config);Read-DiskState
    Assert ($script:Engine.PreserveWhitespace -and $script:Engine.configuration.folder.OuterXml -ceq $before -and $saved.Contains('<encryptionPassword></encryptionPassword>') -and -not $saved.Contains('&#xD;') -and $saved.Replace($script:Engine.configuration.options.OuterXml,'<options><natEnabled>true</natEnabled></options>') -ceq $xml) 'XML save preserves empty passwords and unrelated document'
    Assert ($script:Engine.configuration.options.natEnabled -ceq 'false' -and $script:Engine.configuration.options.listenAddress -ceq 'tcp://127.0.0.1:22000') 'XML options updated and appended'
    function Invoke-RestMethod {Write-Output -NoEnumerate $script:ApiResponse}
    $script:Gui='127.0.0.1:8384';$script:ApiResponse=@([pscustomobject]@{id='first';path='first'},[pscustomobject]@{id='second';path='second'});$captured=@(Invoke-DiskApi 'config/folders');Assert ($captured.Count -eq 2 -and $captured[0].id -ceq 'first' -and $captured[1].id -ceq 'second') 'PS5 REST array is emitted as individual folders'
    foreach($case in @(@{value=@();count=0},@{value=$null;count=0},@{value='';count=0},@{value=$false;count=1},@{value=0;count=1},@{value=[pscustomobject]@{myID='local'};count=1})){$script:ApiResponse=$case.value;$captured=@(Invoke-DiskApi 'system/status');Assert ($captured.Count -eq $case.count -and ($case.count -eq 0 -or [object]::ReferenceEquals($captured[0],$case.value))) 'REST empty array, empty response and scalar object'}
    function Invoke-DiskSsh {param($Command,[switch]$Direct,$OutputFile) $script:ServerResponse}
    foreach($case in @(@{value='[{"name":"first","id":"one"},{"name":"second","id":"two"}]';count=2},@{value='[{"name":"only","id":"one"}]';count=1},@{value='[]';count=0},@{value='';count=0},@{value='null';count=0},@{value='{"deviceId":"peer"}';count=1})){$script:ServerResponse=$case.value;$captured=@(Invoke-DiskServer list);Assert ($captured.Count -eq $case.count) 'Server JSON stream for interactive folder selection and empty responses';if($case.count -eq 2){Assert ($captured[1].name -ceq 'second' -and $captured[1].id -ceq 'two') 'Server folder selection uses a scalar ID'}};Remove-Item Function:Invoke-DiskSsh
    $json=Convert-DiskChannel '{"route":{"final":"server"},"inbounds":[{},{}],"outbounds":[{"tag":"vless-direct","uuid":"synthetic-output-marker"}]}'
    $captured=@(Write-DiskUtf8 (Join-Path $tmp 'config.json') $json);Assert ($captured.Count -eq 0 -and ($json|ConvertFrom-Json).outbounds[0].uuid -eq $secret) 'Silent config generation'
    $exe=(Get-Process -Id $PID).Path;$file=Join-Path $tmp 'native.json';$captured=@(Invoke-DiskProcess $exe @('-NoProfile','-Command',('[Console]::Write("'+$secret+'")')) '' $file)
    Assert ($captured.Count -eq 0 -and [IO.File]::ReadAllText($file) -eq $secret) 'Native output stays in file'
    $failure='';try{Invoke-DiskProcess $exe @('-NoProfile','-Command',('[Console]::Error.Write("'+$secret+'");exit 4'))}catch{$failure=$_|Out-String;$nativeFailure=$_}
    Assert ($failure.Contains('код выхода 4') -and -not $failure.Contains($secret)) 'Native failure contains exit code without secrets'
    Write-DiskLog 'Native test' $nativeFailure;$log=Join-Path $script:DiskHome 'install.log';$text=[IO.File]::ReadAllText($log)
    Assert ($text -match '^\d{4}-\d\d-\d\dT' -and $text.Contains('[Native test]') -and $text.Contains('код выхода 4') -and $text.Contains('Disk.Common.ps1') -and -not $text.Contains($secret)) 'Failure log: time, step, reason, position, no stderr'
    [IO.File]::WriteAllText($log,('x'*(256KB+1)));Write-DiskLog 'Install test';Assert ((Get-Item -LiteralPath $log).Length -lt 256KB -and [IO.File]::ReadAllText($log).Contains('[Install test] Успех')) 'Log rotation and success'
    $folder=Join-Path $tmp 'folder';[void][IO.Directory]::CreateDirectory($folder);$ignore=Join-Path $folder '.stignore';[IO.File]::WriteAllText($ignore,'foreign-policy');$refused=$false
    try{Test-DiskIgnores $folder}catch{$refused=$_.Exception.Message.Contains('Чужой .stignore')};Assert ($refused -and [IO.File]::ReadAllText($ignore) -eq 'foreign-policy') 'Foreign ignores refused'
    Remove-Item -LiteralPath $ignore -Force;Test-DiskIgnores $folder -Write;Test-DiskIgnores $folder -Write
    Assert ([IO.File]::ReadAllText($ignore) -ceq [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'stignore.txt'))) 'Canonical ignores'
    Write-DiskUtf8 (Join-Path $folder 'file.txt') 'existing';Write-DiskUtf8 (Join-Path $script:DiskHome 'server.txt') 'peer'
    $script:LocalFolder=[pscustomobject]@{id='repeat';path=$folder;devices=@(@{deviceID='local'},@{deviceID='peer'});maxConflicts=10};$script:Attachments=0;$script:LocalWrites=0
    function Read-DiskProfile {param($Profile)};function Read-DiskState {}
    function Invoke-DiskServer {param($Action,$Data) if($Action -eq 'list'){[pscustomobject]@{name='project';id='repeat';hasFiles=$true}}else{$script:Attachments++;Assert ($Data.localHasFiles -and -not $Data.merge) 'Repeat attach needs no merge';@{id='repeat'}}}
    function Invoke-RestMethod {param($Uri) switch -Wildcard ($Uri){'*/system/status' {[pscustomobject]@{myID='local'}} '*/config/folders' {Write-Output -NoEnumerate @([pscustomobject]@{id='unrelated';path=(Join-Path $tmp 'other')},$script:LocalFolder)} default {$script:LocalWrites++}}}
    $tokens=$null;$errors=$null;$addAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Add-RemoteDiskFolder.ps1'),[ref]$tokens,[ref]$errors);$body=$addAst.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]}
    $Path=$folder;$Remote='project';$Merge=$false;$interactive=$false;1..2|ForEach-Object {$null=& ([scriptblock]::Create($body.Extent.Text))};Assert ($script:Attachments -eq 2 -and $script:LocalWrites -eq 2) 'Nonempty local folder reconnects without merge'
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Install-RemoteDisk.ps1'),[ref]$tokens,[ref]$errors)
    . ([scriptblock]::Create(($ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Install-DiskBinary'},$true)).Extent.Text))
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
    Assert ($watch.Elapsed.TotalSeconds -lt 30) 'PowerShell time budget';Write-Output ('install: exit 0, {0:N2}s' -f $watch.Elapsed.TotalSeconds)
}finally{Remove-Item -LiteralPath $tmp -Recurse -Force}
