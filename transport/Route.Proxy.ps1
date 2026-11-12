#requires -Version 5.1
param([string]$SettingsFile,[string]$Target,[int]$Port)
$ErrorActionPreference='Stop'
# Durable password-hop adapter. The EXE supplies only its existing askpass client;
# this helper owns the SID-restricted relay, so enrollment code is unnecessary.
try{
    if($Target -notmatch '\A[a-zA-Z0-9][a-zA-Z0-9.:-]{0,252}\z' -or $Port -lt 1 -or $Port -gt 65535){exit 2}
    $c=ConvertFrom-Json ([IO.File]::ReadAllText($SettingsFile).Replace("`r",''))
    if($c.host -notmatch '\A[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}\z' -or $c.user -notmatch '\A[a-z_][a-z0-9_-]{0,31}\z' -or [int]$c.port -lt 1 -or [int]$c.port -gt 65535){exit 2}
    $ctor='new NamedPipeServerStream(Name,PipeDirection.Out,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous,4096,4096,security)'
    if($PSVersionTable.PSVersion.Major -gt 5){Add-Type -AssemblyName System.IO.Pipes.AccessControl;$ctor='NamedPipeServerStreamAcl.Create(Name,PipeDirection.Out,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous,4096,4096,security)'}
    $source=@'
using System;
using System.IO;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading.Tasks;
public sealed class ConfigHopRelay : IDisposable {
 readonly NamedPipeServerStream pipe;
 public readonly string Name="RemoteAgents.Password."+Guid.NewGuid().ToString("N");
 public ConfigHopRelay(string password) {
  var security=new PipeSecurity();security.SetAccessRuleProtection(true,false);
  security.AddAccessRule(new PipeAccessRule(WindowsIdentity.GetCurrent().User,PipeAccessRights.FullControl,AccessControlType.Allow));
  pipe=RELAY_CTOR;
  Serve(password);
 }
 async void Serve(string password) {
  try {for(int i=0;i<32;i++) {
   await pipe.WaitForConnectionAsync();
   using(var writer=new StreamWriter(pipe,new UTF8Encoding(false),4096,true)){await writer.WriteLineAsync(password);await writer.FlushAsync();}
   pipe.WaitForPipeDrain();pipe.Disconnect();
  }}catch(ObjectDisposedException){}catch(IOException){}catch(InvalidOperationException){}
 }
 public void Dispose(){pipe.Dispose();}
}
'@
    Add-Type ($source.Replace('RELAY_CTOR',$ctor))
    $relay=New-Object ConfigHopRelay([string]$c.password)
    $options=@('-o','ProxyCommand=none','-o','ProxyJump=none','-F',[string]$c.configPath,'-T','-o','StrictHostKeyChecking=yes','-o','GlobalKnownHostsFile=none','-o',('UserKnownHostsFile="'+$c.knownHostsPath.Replace('\','/')+'"'),'-o','ForwardAgent=no','-o','ConnectTimeout=8','-o','BatchMode=no','-o','NumberOfPasswordPrompts=1','-o','PreferredAuthentications=password,keyboard-interactive','-o','PubkeyAuthentication=no','-p',[string]$c.port,'-l',[string]$c.user,'-W',($Target+':'+$Port),[string]$c.host)
    $si=New-Object Diagnostics.ProcessStartInfo;$si.FileName=[string]$c.sshExecutable
    $si.Arguments=(($options|ForEach-Object {'"'+[regex]::Replace([regex]::Replace([string]$_,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'}) -join ' ')
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardInput=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
    $si.EnvironmentVariables['SSH_ASKPASS']=[string]$c.askpassExecutable;$si.EnvironmentVariables['SSH_ASKPASS_REQUIRE']='force';$si.EnvironmentVariables['DISPLAY']='remoteagents:0';$si.EnvironmentVariables['REMOTEAGENTS_PASSWORD_PIPE']=$relay.Name
    $process=New-Object Diagnostics.Process;$process.StartInfo=$si
    try{
        [void]$process.Start();[void]$process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
        $inputCopy=[Console]::OpenStandardInput().CopyToAsync($process.StandardInput.BaseStream)
        $outputCopy=$process.StandardOutput.BaseStream.CopyToAsync([Console]::OpenStandardOutput())
        $inputClosed=$false
        while(-not $process.HasExited){if(-not $inputClosed -and $inputCopy.IsCompleted){$process.StandardInput.Close();$inputClosed=$true};Start-Sleep -Milliseconds 20}
        $outputCopy.GetAwaiter().GetResult();exit $process.ExitCode
    }finally{if($process.Id -and -not $process.HasExited){$process.Kill()};$process.Dispose();$relay.Dispose()}
}catch{[Console]::Error.WriteLine('SSH hop: проверьте маршрут, пароль и закреплённый ключ хоста.');exit 1}
