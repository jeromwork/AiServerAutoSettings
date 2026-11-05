$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Remote.Chat.ps1')
function Assert($Value,[string]$Message){if(!$Value){throw $Message}}
Assert (Test-RemoteChatUser 'remoteagents') 'Shared chat user rejected'
foreach($name in @('root','RemoteAgents','ra-chat-son','ra-chat-user-2','ra-chat-','ra-chat-a;id',"remoteagents`n")){Assert (!(Test-RemoteChatUser $name)) 'Unexpected chat user accepted'}
$link='https://cloud.happier.dev/terminal/connect#key=public-test-key&server=https%3A%2F%2Fapi.happier.dev'
Assert ((Get-RemoteChatApprovalUrl ("Open: "+$link)) -eq $link) 'Official pairing link rejected'
Assert ((Get-RemoteChatApprovalUrl (([char]27)+'[32m'+$link+([char]27)+'[0m')) -eq $link) 'Colored pairing link rejected'
foreach($line in @('https://evil.example/terminal/connect#key=test','https://happier.dev.evil.example/terminal/connect','https://cloud.happier.dev@evil.example/terminal/connect','http://cloud.happier.dev/terminal/connect','https://cloud.happier.dev:444/terminal/connect','https://cloud.happier.dev/')){
    Assert (!$((Get-RemoteChatApprovalUrl $line))) 'Untrusted approval link accepted'
}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'setup-vps-ssh.ps1'),[ref]$tokens,[ref]$errors)
Assert (!$errors.Count) 'Setup syntax invalid'
foreach($name in @('Install-RemoteChat','Start-RemoteCodex')){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($node.Extent.Text.Replace('$PSScriptRoot',("'"+$PSScriptRoot.Replace("'","''")+"'"))))
}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('ra-chat-test-'+[guid]::NewGuid().ToString('N'))
try{
    [void][IO.Directory]::CreateDirectory($fixture)
    # A native argv round trip catches Windows quoting bugs before SSH sees them.
    $exe=Join-Path $fixture 'argv fixture.exe'
    Add-Type -TypeDefinition @'
using System; using System.Text; using System.Threading;
public class ChatArgvFixture {
    public static int Main(string[] a) {
        string mode = Environment.GetEnvironmentVariable("REMOTE_CHAT_TEST_MODE");
        if (string.IsNullOrEmpty(mode)) { Console.WriteLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(string.Join("\n",a)))); return 0; }
        if (mode == "hang") { Thread.Sleep(15000); return 1; }
        if (mode == "failure") { Console.Error.WriteLine("Permission denied (publickey)."); return 255; }
        if (mode == "login" && string.Join(" ",a).Contains("auth login")) {
            Console.WriteLine("https://cloud.happier.dev/terminal/connect#key=public-test-key");
            Thread.Sleep(5000); return 0;
        }
        if (mode == "ready") { Console.WriteLine("{\"v\":1,\"ok\":true,\"kind\":\"auth_status\"}"); return 0; }
        Console.WriteLine("{\"v\":1,\"ok\":false,\"kind\":\"auth_status\",\"error\":{\"code\":\"not_authenticated\"}}"); return 1;
    }
}
'@ -OutputAssembly $exe -OutputType ConsoleApplication
    $connection=@{SSHExecutable=$exe;VPSHost='fixture.invalid';VPSUser='root';IdentityFile=(Join-Path $fixture 'key with spaces');SSHConfig=(Join-Path $fixture 'config');KnownHostsFile=(Join-Path $fixture 'known hosts');SSHPort=443;ChatUser='remoteagents'}
    foreach($action in @('status','login')){
        $info=New-RemoteChatStart @connection -Action $action
        Assert ($info.CreateNoWindow -and $info.RedirectStandardOutput -and $info.RedirectStandardError) 'Sign-in process could leak into console'
        $process=New-Object Diagnostics.Process;$process.StartInfo=$info
        try{
            [void]$process.Start();$process.StandardInput.Close()
            $output=$process.StandardOutput.ReadToEnd();Assert ($process.WaitForExit(10000)) 'Native argument fixture timed out'
            $argv=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($output.Trim())) -split "`n"
            Assert ($argv -contains $connection.IdentityFile) 'Identity path split or altered'
            Assert ($argv -contains ('UserKnownHostsFile='+$connection.KnownHostsFile)) 'Known-hosts path split or altered'
            Assert ($argv -contains 'BatchMode=yes' -and $argv -contains 'ConnectTimeout=10' -and $argv -contains 'StrictHostKeyChecking=yes') 'SSH checks lost their timeout or host verification'
            $last=$argv[-1]
            Assert ($last -match 'runuser -u remoteagents' -and $last -match 'HOME=/home/remoteagents') 'Chat command does not use shared server setup'
            if($action -eq 'login'){Assert ($last -match 'timeout 610' -and $last -match '--no-open --method web --wait-timeout 600') 'Interactive login is unbounded or opens on wrong computer'}
            else{Assert ($last -match 'timeout 8' -and $last -match 'auth status --json') 'Status probe is not short and machine-readable'}
        }finally{if(!$process.HasExited){$process.Kill()};$process.Dispose()}
    }
    # Run the real form/message loop against a fake SSH process. Only our own
    # form is instrumented; no desktop UI automation or account sign-in occurs.
    $formSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'server-chat.ps1'))
    $formSource=$formSource.Replace('$PSScriptRoot',("'"+$PSScriptRoot.Replace("'","''")+"'"))
    $probe=@'
$probeClock=[Diagnostics.Stopwatch]::StartNew()
$probeTimer=New-Object Windows.Forms.Timer
$probeTimer.Interval=100
$script:probeLoginStarted=$false
$probeTimer.Add_Tick({
    if($env:REMOTE_CHAT_TEST_MODE -eq 'login' -and !$script:probeLoginStarted){$script:probeLoginStarted=$true;Start-ChatAction 'login'}
    $done=if($env:REMOTE_CHAT_TEST_MODE -eq 'login'){$approve.Enabled}else{$pair.Enabled -and !$script:chatProcess}
    if($done -or $probeClock.Elapsed.TotalSeconds -gt 13){
        $probeTimer.Stop()
        [Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
        [Console]::WriteLine((@{status=$status.Text;pairEnabled=$pair.Enabled;approveEnabled=$approve.Enabled;hasApproval=[bool]$script:approvalUrl;timedOut=($probeClock.Elapsed.TotalSeconds -gt 13)}|ConvertTo-Json -Compress))
        $form.Close()
    }
})
$probeTimer.Start()
try{[void]$form.ShowDialog()}finally{$probeTimer.Dispose();$form.Dispose()}
'@
    $formSource=$formSource.Replace('try{[void]$form.ShowDialog()}finally{$form.Dispose()}',$probe)
    $formFile=Join-Path $fixture 'form-runtime.ps1'
    [IO.File]::WriteAllText($formFile,$formSource,(New-Object Text.UTF8Encoding($true)))
    foreach($mode in @('unauth','ready','login','failure','hang')){
        $env:REMOTE_CHAT_TEST_MODE=$mode
        $formArgs=@('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$formFile,'-VPSHost','fixture.invalid','-VPSUser','root','-IdentityFile','fixture','-KnownHostsFile','fixture','-SSHExecutable',$exe,'-SSHPort','443')
        $si=New-Object Diagnostics.ProcessStartInfo
        $si.FileName=Join-Path $PSHOME 'powershell.exe'
        $si.Arguments=(@($formArgs|ForEach-Object{Convert-RemoteChatArgument $_}) -join ' ')
        $si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
        $si.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
        $p=New-Object Diagnostics.Process;$p.StartInfo=$si
        try{
            [void]$p.Start();$read=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
            Assert ($p.WaitForExit(16000)) 'Chat form stopped responding'
            Assert ($p.ExitCode -eq 0) ('Chat form failed: '+$err.GetAwaiter().GetResult())
            $raw=$read.GetAwaiter().GetResult();$result=$raw|ConvertFrom-Json
            Assert (!$result.timedOut) 'Chat form never finished its status transition'
            if($mode -eq 'login'){Assert ($result.approveEnabled -and $result.hasApproval -and $raw -notmatch 'public-test-key') 'Pairing link was leaked or confirmation button stayed disabled'}
            else{Assert $result.pairEnabled 'Retry button stayed disabled'}
            if($mode -eq 'unauth'){Assert ($result.status -like '*Нужен первый вход*') 'First sign-in guidance missing'}
            if($mode -eq 'ready'){Assert ($result.status -like '*Сервер подключён*') 'Ready status not displayed'}
            if($mode -eq 'hang'){Assert ($result.status -like '*10 секунд*') 'Hung SSH status probe did not time out'}
        }finally{if(!$p.HasExited){$p.Kill()};$p.Dispose()}
    }
    Remove-Item Env:REMOTE_CHAT_TEST_MODE
    $common=@();$keyPath='fixture';$ServerAddress='fixture.invalid'
    $script:payloads=New-Object 'Collections.Generic.List[string]';$script:failures=0
    function Invoke-ProfileSsh {param($Arguments,$InputText,$Activity);$script:payloads.Add($InputText);if($script:failures -gt 0){$script:failures--;return 1};return 0}
    $gitRoot=Split-Path (Split-Path (Get-Command git.exe).Source)
    $bash=Join-Path $gitRoot 'bin\bash.exe'
    foreach($agents in @('1','2','3')){
        Install-RemoteChat -Agents $agents
        $payload=$script:payloads[$script:payloads.Count-1]
        Assert (($payload -match 'codex-package') -eq ($agents -in @('1','3'))) 'Codex installed despite provider choice'
        Assert (($payload -match 'claude.ai/install.sh') -eq ($agents -in @('2','3'))) 'Claude installed despite provider choice'
        Assert ($payload -match 'bash -s -- remoteagents' -and $payload -notmatch 'ra-chat-|xrdp|google-chrome|claude-desktop|chatgpt-desktop') 'Chat installation unexpectedly creates a separate person or installs a desktop'
        $file=Join-Path $fixture ('payload-'+$agents+'.sh')
        [IO.File]::WriteAllText($file,$payload,(New-Object Text.UTF8Encoding($false)))
        & $bash -n $file.Replace('\','/')
        Assert ($LASTEXITCODE -eq 0) 'Generated installer payload has invalid Bash syntax'
    }
    # Exercise the real menu: first install, shared warm open, retry.
    $script:messages=New-Object 'Collections.Generic.List[string]'
    function Write-Host {param($Object);$script:messages.Add([string]$Object)}
    function Get-SavedProjectNames {@()}
    function Stop-ManagedComponent {param($Component)}
    function Open-ServerDesktop {throw 'Chat menu opened RDP'}
    function Open-RemoteChat {param($ChatUser);$script:opened.Add($ChatUser)}
    function Save-ProfileMetadata {param($Metadata,$Path);$script:saves++}
    function Read-Host {param($Question);if(!$script:answers.Count){throw ('Unexpected prompt: '+$Question)};$script:answers.Dequeue()}
    function Reset-ChatMenu {
        $script:answers=New-Object 'Collections.Generic.Queue[string]';$script:opened=New-Object 'Collections.Generic.List[string]'
        $script:saves=0;$script:payloads.Clear();$script:messages.Clear();$script:failures=0
    }
    $metadataPath='fixture'
    Reset-ChatMenu;$metadata=[pscustomobject]@{agentApplications='0';executionMode='2'}
    foreach($answer in @('14','1','14','0')){$script:answers.Enqueue($answer)}
    Start-RemoteCodex
    Assert ($script:payloads.Count -eq 1 -and $script:saves -eq 1 -and $script:opened.Count -eq 2) 'Warm open reinstalled components'
    Assert (@($metadata.chatProfiles).Count -eq 1) 'Ready profile was duplicated'
    Reset-ChatMenu
    foreach($answer in @('10','14','0')){$script:answers.Enqueue($answer)}
    Start-RemoteCodex
    Assert ($script:payloads.Count -eq 0 -and $script:saves -eq 0 -and ($script:opened -join ',') -eq 'remoteagents') 'Shared chats were not reopened without installation'
    Assert (!($script:messages | Where-Object{$_ -match '^15\.|Отдельные чаты'})) 'Separate person menu is still visible'
    Reset-ChatMenu;$metadata=[pscustomobject]@{agentApplications='0';executionMode='2'};$script:failures=1
    foreach($answer in @('14','1','14','1','0')){$script:answers.Enqueue($answer)}
    Start-RemoteCodex
    Assert ($script:payloads.Count -eq 2 -and $script:saves -eq 1 -and $script:opened.Count -eq 1) 'Failed install was marked ready or could not be retried'
    Reset-ChatMenu;$metadata=[pscustomobject]@{agentApplications='0';executionMode='2'}
    foreach($answer in @('14','0','0')){$script:answers.Enqueue($answer)}
    Start-RemoteCodex
    Assert (!$script:payloads.Count -and !$script:opened.Count -and !$script:saves) 'Cancel still installed components'
    Microsoft.PowerShell.Utility\Write-Output 'PASS remote chat: native SSH arguments; live form states/sign-in link/10s timeout; selected providers; Bash payloads; shared menu and warm open; cancellation; install retry'
}finally{
    Remove-Item Env:REMOTE_CHAT_TEST_MODE -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($fixture);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(!$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'ra-chat-test-*'){throw 'Unsafe chat test cleanup'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
