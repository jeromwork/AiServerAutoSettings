using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Security.Cryptography;
using System.Text;

namespace RemoteAgents.Core;

public sealed record SshProfile(string ServerAddress,string Login,string KeyPath,string KnownHostsPath,string ConfigPath,string SshExecutable,int Port=22)
{
    public static SshProfile Import(string path)
    {
        using var doc=JsonDocument.Parse(File.ReadAllText(path)); var e=doc.RootElement;
        string S(string n)=>e.GetProperty(n).GetString()??throw new InvalidDataException("Missing profile setting");
        return new(S("serverAddress"),S("login"),S("keyPath"),S("knownHostsPath"),S("configPath"),S("sshExecutable"),e.TryGetProperty("port",out var p)?p.GetInt32():22);
    }
    public string[] Arguments()
    {
        if(!Regex.IsMatch(ServerAddress,"^[a-zA-Z0-9][a-zA-Z0-9.:_-]*$") || !Regex.IsMatch(Login,"^[a-zA-Z_][a-zA-Z0-9_.-]*[$]?$") || Port<1||Port>65535) throw new InvalidDataException("Invalid SSH profile");
        return ["-F",ConfigPath,"-T","-i",KeyPath,"-l",Login,"-p",Port.ToString(),"-o","UserKnownHostsFile="+KnownHostsPath,"-o","StrictHostKeyChecking=yes","-o","IdentitiesOnly=yes","-o","BatchMode=yes","-o","ConnectTimeout=10","-o","ServerAliveInterval=15","-o","ServerAliveCountMax=3"];
    }
}
public sealed record SshResult(int ExitCode,string Output);
public sealed class SshTransport(SshProfile profile,Journal journal)
{
    public static string Quote(string value) => "'"+value.Replace("'","'\"'\"'")+"'";
    public static string Classify(string stderr) => stderr switch
    {
        var s when s.Contains("Permission denied",StringComparison.OrdinalIgnoreCase)=>"authentication-denied",
        var s when s.Contains("Host key verification failed",StringComparison.OrdinalIgnoreCase)=>"host-key-rejected",
        var s when s.Contains("Could not resolve",StringComparison.OrdinalIgnoreCase)=>"dns-failed",
        var s when s.Contains("Connection refused",StringComparison.OrdinalIgnoreCase)=>"connection-refused",
        var s when s.Contains("timed out",StringComparison.OrdinalIgnoreCase)=>"timeout",
        var s when s.Contains("forwarding failed",StringComparison.OrdinalIgnoreCase)=>"forward-failed",
        var s when s.Contains("reset",StringComparison.OrdinalIgnoreCase)=>"connection-reset",
        var s when s.Contains("Broken pipe",StringComparison.OrdinalIgnoreCase)=>"broken-pipe",
        _ => "unclassified-exit" // Do not invent a reason or persist arbitrary stderr.
    };
    public async Task ProbeAsync(CancellationToken token)
    {
        var clock=Stopwatch.StartNew(); IPAddress[] addresses;
        try { addresses=await Dns.GetHostAddressesAsync(profile.ServerAddress,token); journal.Write("network","dns","resolved",clock.ElapsedMilliseconds); }
        catch(Exception e) when(e is SocketException or OperationCanceledException) { journal.Write("network","dns","probe-failed",clock.ElapsedMilliseconds);return; }
        clock.Restart();
        try { using var tcp=new TcpClient(); await tcp.ConnectAsync(addresses,profile.Port,token); journal.Write("network","tcp","connected",clock.ElapsedMilliseconds); }
        catch(Exception e) when(e is SocketException or OperationCanceledException) { journal.Write("network","tcp","probe-failed",clock.ElapsedMilliseconds); }
        // SSH profile aliases/proxies may use a different route; probes are observations, not a readiness gate.
    }
    public async Task<SshResult> RunAsync(string command,string? input=null,CancellationToken token=default, bool logEvents=true)
    {
        using var deadline=CancellationTokenSource.CreateLinkedTokenSource(token); deadline.CancelAfter(TimeSpan.FromSeconds(90));
        var info=new ProcessStartInfo(profile.SshExecutable) {UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true};
        foreach(var a in profile.Arguments().Concat(new[]{profile.ServerAddress,command})) info.ArgumentList.Add(a);
        using var process=new Process{StartInfo=info}; var clock=Stopwatch.StartNew(); if(logEvents) journal.Write("ssh","start","profile-route");
        process.Start(); var output=process.StandardOutput.ReadToEndAsync(deadline.Token); var error=process.StandardError.ReadToEndAsync(deadline.Token);
        try {
            if(input!=null) await process.StandardInput.WriteAsync(input.AsMemory(),deadline.Token);
            process.StandardInput.Close(); await process.WaitForExitAsync(deadline.Token);
            var stderr=await error; if(logEvents) journal.Write("ssh","exit",process.ExitCode==0?"ok":Classify(stderr),clock.ElapsedMilliseconds,process.ExitCode);
            return new(process.ExitCode,await output);
        } catch(OperationCanceledException) { if(!process.HasExited) process.Kill(true); await process.WaitForExitAsync(); if(logEvents) journal.Write("ssh","exit","cancelled-or-timeout",clock.ElapsedMilliseconds,process.ExitCode);throw; }
    }
    public async Task<bool> UploadLogAsync(string text,string remoteRoot,string hostId,CancellationToken token)
    {
        if(!Regex.IsMatch(hostId,"^[a-z0-9][a-z0-9_-]{0,63}$")) throw new InvalidDataException();
        var directory=remoteRoot.TrimEnd('/')+"/"+hostId;
        var hash=Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant();
        var path=directory+"/"+hash+".jsonl";
        var result=await RunAsync("umask 077; test \"$(id -u)\" -ne 0 && mkdir -p -- "+Quote(directory)+" && cat > "+Quote(path+".tmp")+" && mv -- "+Quote(path+".tmp")+" "+Quote(path),text,token,logEvents:false);
        return result.ExitCode==0;
    }
    public string[] TunnelArguments(int localForward,int serverListen,int remoteForward,int localListen) => profile.Arguments().Concat(new[]{"-o","ExitOnForwardFailure=yes","-L",$"127.0.0.1:{localForward}:127.0.0.1:{serverListen}","-R",$"127.0.0.1:{remoteForward}:127.0.0.1:{localListen}","-N",profile.ServerAddress}).ToArray();
}
