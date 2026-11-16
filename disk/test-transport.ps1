#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
if(-not $TestHome){$TestHome=Join-Path ([IO.Path]::GetTempPath()) ('disk-transport-'+[guid]::NewGuid().ToString('N'))}
[void][IO.Directory]::CreateDirectory($TestHome)
. (Join-Path $PSScriptRoot 'Disk.Common.ps1')
$script:DiskHome=Join-Path $TestHome 'RemoteDisk'
$oldLocal=$env:LOCALAPPDATA;$env:LOCALAPPDATA=$TestHome
$count=0
function Assert($Value,[string]$Text){if(-not $Value){throw ('FAIL: '+$Text)};$script:count++}
try{
    $script:calls=0;$script:pauses=@()
    function Start-Sleep($Seconds,$Milliseconds){if($Milliseconds){$Seconds=$Milliseconds/1000};$script:pauses+=@($Seconds)}
    $result=Invoke-DiskRetry {$script:calls++;if($script:calls -lt 3){throw 'Тест: временный разрыв'};'success'} 'Тест повтора'
    Assert ($script:calls -eq 3 -and $result -ceq 'success' -and ($script:pauses -join ',') -ceq '1,2') 'idempotent command succeeds on third attempt after two increasing pauses'
    $script:calls=0;$script:pauses=@();$failed=$false
    try{Invoke-DiskRetry {$script:calls++;throw 'Тест: постоянный разрыв'} 'Тест предела'}catch{$failed=$_.Exception.Message -ceq 'Тест: постоянный разрыв'}
    Assert ($failed -and $script:calls -eq 3 -and ($script:pauses -join ',') -ceq '1,2') 'three failed attempts propagate the actual final cause without a fourth call'
    $script:pauses=@();$result=Invoke-DiskRetry {'first'} 'Тест успеха'
    Assert ($result -ceq 'first' -and $script:pauses.Count -eq 0) 'first-attempt success has no delay'
    $log=[IO.File]::ReadAllText((Join-Path $script:DiskHome 'install.log'))
    Assert ($log.Contains('Тест предела: попытка 3 из 3') -and $log.Contains('Тест: постоянный разрыв')) 'retry journal records attempts and cause'
    Remove-Item Function:Start-Sleep
    # Import the installer's real banner wait without running the installer.
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Install-RemoteDisk.ps1'),[ref]$tokens,[ref]$errors)
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Wait-DiskTransport'},$true)
    Invoke-Expression $definition.Extent.Text
    Add-Type -TypeDefinition @'
using System;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;
public static class DiskBannerFixture {
    public static Task<int> Serve(TcpListener listener, bool wrongFirst, int delay) {
        return Task.Run(async () => {
            int count = 0;
            if (wrongFirst) {
                using (TcpClient wrong = await listener.AcceptTcpClientAsync()) {
                    count++;
                    byte[] data = Encoding.ASCII.GetBytes("HTTP");
                    await wrong.GetStream().WriteAsync(data, 0, data.Length);
                }
            }
            using (TcpClient client = await listener.AcceptTcpClientAsync()) {
                count++;
                await Task.Delay(delay);
                byte[] first = Encoding.ASCII.GetBytes("SS");
                await client.GetStream().WriteAsync(first, 0, first.Length);
                await Task.Delay(250);
                byte[] last = Encoding.ASCII.GetBytes("H-");
                await client.GetStream().WriteAsync(last, 0, last.Length);
            }
            return count;
        });
    }
}
'@
    function Get-TransportEffectivePort {return $script:bannerPort}
    $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$listener.Start()
    try{
        $script:bannerPort=$listener.LocalEndpoint.Port
        $server=[DiskBannerFixture]::Serve($listener,$true,3500)
        $watch=[Diagnostics.Stopwatch]::StartNew();Wait-DiskTransport
        Assert ($watch.Elapsed.TotalSeconds -ge 3.5 -and $watch.Elapsed.TotalSeconds -lt 8 -and $server.GetAwaiter().GetResult() -eq 2) 'wrong protocol is retried; delayed fragmented SSH banner is accepted on the same connection after over 3.5 seconds'
    }finally{$listener.Stop()}
    $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$listener.Start()
    try{
        $script:bannerPort=$listener.LocalEndpoint.Port
        $watch=[Diagnostics.Stopwatch]::StartNew();$failed=$false
        try{Wait-DiskTransport -TimeoutSeconds 1}catch{$failed=$_.Exception.Message -like '*нет баннера SSH*за 1 с.*'}
        Assert ($failed -and $watch.Elapsed.TotalSeconds -ge 0.9 -and $watch.Elapsed.TotalSeconds -lt 3) 'silent connection respects the total wait budget even during banner read'
    }finally{$listener.Stop()}
    Write-Output ('PASS: '+$count+' retry/banner checks (real loopback sockets and delayed fragmented SSH banner)')
}finally{$env:LOCALAPPDATA=$oldLocal}
