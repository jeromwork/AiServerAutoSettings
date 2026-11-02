$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$path=Join-Path $PSScriptRoot 'Start-RemotePreview.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Preview parse failed'}
foreach($name in @('Get-PreviewPort','Quote-PreviewArgument')){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($node.Extent.Text))
}
$busy=New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback),0
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('ra-preview-'+[guid]::NewGuid().ToString('N'))
$proc=$null;$oldArgs=$env:RA_PREVIEW_TEST_ARGS
try {
    $busy.Start();$occupied=$busy.LocalEndpoint.Port
    $free=Get-PreviewPort $occupied
    if($free -eq $occupied -or $free -le 0){throw 'Occupied loopback port was not replaced'}
    [void][IO.Directory]::CreateDirectory($fixture)
    foreach($name in @('identity','hosts','config')){[IO.File]::WriteAllText((Join-Path $fixture $name),'synthetic only')}
    $fake=Join-Path $fixture 'fake-ssh.exe';$env:RA_PREVIEW_TEST_ARGS=Join-Path $fixture 'args.txt'
    Add-Type -TypeDefinition 'using System;using System.IO;public class PreviewFakeSSH {public static void Main(string[] args){File.WriteAllLines(Environment.GetEnvironmentVariable("RA_PREVIEW_TEST_ARGS"),args);Console.WriteLine("REMOTEAGENTS_PREVIEW_READY");while(Console.ReadLine()!=null){}}}' -OutputAssembly $fake -OutputType ConsoleApplication
    $values=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$path,'-VPSHost','fixture.invalid','-VPSUser','fixture','-IdentityFile',(Join-Path $fixture 'identity'),'-KnownHostsFile',(Join-Path $fixture 'hosts'),'-SSHConfig',(Join-Path $fixture 'config'),'-SSHExecutable',$fake,'-AskpassExecutable',$fake,'-ServerPort','3801','-LocalPort',[string]$occupied,'-ManagedSession')
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName='powershell.exe';$info.Arguments=(@($values|ForEach-Object{Quote-PreviewArgument $_}) -join ' ')
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $proc=New-Object Diagnostics.Process;$proc.StartInfo=$info;[void]$proc.Start()
    $line=$proc.StandardOutput.ReadLineAsync()
    if(!$line.Wait(15000)){throw 'Preview startup timeout'}
    $ready=$line.Result|ConvertFrom-Json
    if($ready.state -ne 'preview' -or $ready.localPort -eq $occupied -or $ready.url -notmatch '^http://127\.0\.0\.1:[0-9]+/$' -or $ready.serviceChecked){throw 'Incorrect preview readiness'}
    $argsRead=[IO.File]::ReadAllLines($env:RA_PREVIEW_TEST_ARGS)
    if($argsRead -notcontains ('127.0.0.1:'+$ready.localPort+':127.0.0.1:3801') -or $argsRead -notcontains 'StrictHostKeyChecking=yes' -or $argsRead -notcontains 'ExitOnForwardFailure=yes' -or $argsRead -contains '-R'){throw 'Preview SSH boundary changed'}
    $proc.StandardInput.WriteLine('stop');$proc.StandardInput.Close()
    if(!$proc.WaitForExit(10000) -or $proc.ExitCode -ne 0){throw 'Preview did not close cleanly'}
    'PASS: real PS5.1 managed preview with fixture SSH, occupied port fallback, exact loopback forward, verified hosts, stop cleanup; service not claimed'
}finally{
    if($proc){if(!$proc.HasExited){$proc.Kill();$proc.WaitForExit()};$proc.Dispose()}
    $env:RA_PREVIEW_TEST_ARGS=$oldArgs;$busy.Stop()
    $resolved=[IO.Path]::GetFullPath($fixture);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(!$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe preview fixture cleanup'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
