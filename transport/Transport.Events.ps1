# Passive Clash subscriptions and explicitly requested checks. Dot-source Transport.Common.ps1 first.
# Integration: create one reader per engine/config generation, drain every daemon tick (300 ms),
# dispose BEFORE engine restart/reload/network change. Tags are candidate tags, never selector tags.
# Checks are handles: Start -> Receive each tick (no result while pending) -> Stop in finally.
# No subscription failure is an engine-exit: the daemon owns process lifecycle events.
function Initialize-TransportEvents {
    if ('RemoteAgents.TransportEvents' -as [type]) { return }
    $source = @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text.RegularExpressions;
using System.Threading;
namespace RemoteAgents {
 public sealed class TransportEvent {
  public long at {get;set;}
  public string kind {get;set;}
  public string tag {get;set;}
  public string code {get;set;}
  public bool local {get;set;}
  public string detail {get;set;}
  public static TransportEvent Make(string kind,string tag,string code,bool local,string detail) {
   return new TransportEvent {at=(DateTime.UtcNow.Ticks-621355968000000000L)/10000,
    kind=kind,tag=tag ?? "",code=code,local=local,detail=detail};
  }
 }
 [DataContract] public sealed class ClashLog {
  [DataMember(Name="type")] public string Type;
  [DataMember(Name="payload")] public string Payload;
 }
 [DataContract] public sealed class ClashConnections {
  [DataMember(Name="connections")] public ClashConnection[] Connections;
 }
 [DataContract] public sealed class ClashConnection {
  [DataMember(Name="id",IsRequired=true)] public string Id;
  [DataMember(Name="start")] public string Start;
  [DataMember(Name="upload",IsRequired=true)] public long Upload;
  [DataMember(Name="download",IsRequired=true)] public long Download;
  [DataMember(Name="chains",IsRequired=true)] public string[] Chains;
  [DataMember(Name="metadata")] public ClashMetadata Metadata;
 }
 [DataContract] public sealed class ClashMetadata {
  [DataMember(Name="type")] public string Type;
 }
 public sealed class TransportEvents : IDisposable {
  sealed class Sample { public string Tag,Start; public long Up,Down; public double Since,Seen; }
  sealed class Context { public string Tag; public double Seen; }
  readonly object gate=new object();
  readonly Queue<TransportEvent> queue=new Queue<TransportEvent>();
  readonly HashSet<string> tags;
  readonly Dictionary<string,Sample> samples=new Dictionary<string,Sample>();
  readonly Dictionary<string,double> suspected=new Dictionary<string,double>();
  readonly Dictionary<string,Context> contexts=new Dictionary<string,Context>();
  readonly CancellationTokenSource stop=new CancellationTokenSource();
  readonly Thread[] workers=new Thread[2];
  readonly ClientWebSocket[] sockets=new ClientWebSocket[2];
  readonly int port,stallConns;
  readonly double stallSeconds;
  readonly string secret;
  public int Dropped {get;private set;}
  public string LogsStatus {get;private set;}
  public string ConnectionsStatus {get;private set;}
  public TransportEvents(int port,string secret,string[] tags,double stallSeconds,int stallConns) {
   if(port<1 || port>65535 || stallSeconds<=0 || stallConns<1) throw new ArgumentException("Invalid event options");
   this.port=port; this.secret=secret; this.tags=new HashSet<string>(tags ?? new string[0]);
   this.stallSeconds=stallSeconds; this.stallConns=stallConns;
   for(int i=0;i<2;i++) {int n=i; workers[i]=new Thread(delegate(){Read(n);}); workers[i].IsBackground=true; workers[i].Start();}
  }
  static double Clock() {return (double)Stopwatch.GetTimestamp()/Stopwatch.Frequency;}
  void Status(int n,string value) {if(n==0) LogsStatus=value; else ConnectionsStatus=value;}
  void Read(int n) {
   int delay=1000;
   while(!stop.IsCancellationRequested) {
    using(ClientWebSocket ws=new ClientWebSocket()) {
     lock(gate) {if(stop.IsCancellationRequested) return; sockets[n]=ws;}
     try {
      ws.Options.Proxy=null;
      if(!String.IsNullOrEmpty(secret)) ws.Options.SetRequestHeader("Authorization","Bearer "+secret);
      using(CancellationTokenSource connect=CancellationTokenSource.CreateLinkedTokenSource(stop.Token)) {
       connect.CancelAfter(3000);
       ws.ConnectAsync(new Uri("ws://127.0.0.1:"+port+(n==0?"/logs?level=warn":"/connections?interval=1000")),connect.Token).GetAwaiter().GetResult();
      }
      if(n==1) {samples.Clear(); suspected.Clear();} else contexts.Clear();
      Status(n,"connected"); delay=1000;
      byte[] buffer=new byte[8192];
      DataContractJsonSerializer serializer=new DataContractJsonSerializer(n==0?typeof(ClashLog):typeof(ClashConnections));
      while(!stop.IsCancellationRequested) {
       using(MemoryStream message=new MemoryStream()) {
        WebSocketReceiveResult part;
        do {
         part=ws.ReceiveAsync(new ArraySegment<byte>(buffer),stop.Token).GetAwaiter().GetResult();
         if(part.MessageType==WebSocketMessageType.Close) throw new IOException();
         if(part.MessageType!=WebSocketMessageType.Text || message.Length+part.Count>4*1024*1024) throw new IOException();
         message.Write(buffer,0,part.Count);
        } while(!part.EndOfMessage);
        message.Position=0;
        try {
         if(n==0) ParseLog((ClashLog)serializer.ReadObject(message));
         else ParseConnections((ClashConnections)serializer.ReadObject(message));
         Status(n,"connected");
        } catch(SerializationException) {if(n==1) {samples.Clear(); suspected.Clear();} Status(n,"invalid-message");}
       }
      }
     } catch(Exception) {Status(n,"disconnected");}
     finally {lock(gate) sockets[n]=null;}
    }
    if(stop.Token.WaitHandle.WaitOne(delay)) break;
    delay=Math.Min(delay*2,10000);
   }
   Status(n,"stopped");
  }
  void Enqueue(TransportEvent e) {lock(gate) {if(queue.Count>=512) {queue.Dequeue(); Dropped++;} queue.Enqueue(e);}}
  public TransportEvent[] Drain() {lock(gate) {TransportEvent[] all=queue.ToArray(); queue.Clear(); return all;}}
  static readonly Regex Outbound=new Regex(@"outbound/[^\s\[]+\[([^\]]+)\]",RegexOptions.IgnoreCase);
  static readonly Regex LogContext=new Regex(@"\[(\d+)\s+[^\]]+\]");
  static readonly Regex Cancelled=new Regex(@"\b(canceled|cancelled|context canceled|operation was canceled)\b",RegexOptions.IgnoreCase);
  static string Failure(string text) {
   if(Regex.IsMatch(text,@"\b(10050|10051|10052|10065)\b|no route to host|network is unreachable|network is down|host is unreachable",RegexOptions.IgnoreCase)) return "local-network";
   // Only the system resolver: explicit remote/proxy DNS errors belong to the path.
   if(Regex.IsMatch(text,@"(?:remote|proxy) (?:DNS|resolver)",RegexOptions.IgnoreCase)) return "dns-error";
   if(Regex.IsMatch(text,@"getaddrinfow?|gethostbyname|lookup\s+\S+(?:\s+on\s+\S+)?:\s*(?:no such host|temporary failure in name resolution)|WSAHOST_NOT_FOUND|WSATRY_AGAIN|\b(11001|11002)\b",RegexOptions.IgnoreCase)) return "system-dns";
   if(Regex.IsMatch(text,@"timeout|timed out|10060",RegexOptions.IgnoreCase)) return "timeout";
   if(Regex.IsMatch(text,@"reset|10054",RegexOptions.IgnoreCase)) return "reset";
   if(Regex.IsMatch(text,@"refused|10061",RegexOptions.IgnoreCase)) return "refused";
   return "dial-error";
  }
  void ParseLog(ClashLog log) {
   if(log==null || String.IsNullOrEmpty(log.Payload)) return;
   string text=Regex.Replace(log.Payload,@"\x1b\[[0-9;]*m","");
   Match outbound=Outbound.Match(text), context=LogContext.Match(text);
   string tag=outbound.Success && tags.Contains(outbound.Groups[1].Value)?outbound.Groups[1].Value:"";
   double now=Clock();
   if(context.Success) {
    if(contexts.Count>2048) contexts.Clear();
    Context known;
    if(tag!="") contexts[context.Groups[1].Value]=new Context {Tag=tag,Seen=now};
    else if(contexts.TryGetValue(context.Groups[1].Value,out known) && now-known.Seen<120) tag=known.Tag;
   }
   if(!String.Equals(log.Type,"error",StringComparison.OrdinalIgnoreCase) || Cancelled.IsMatch(text)) return;
   string kind="";
   if(Regex.IsMatch(text,@"(?:open (?:packet )?connection to|listen packet connection using).*using outbound/|listen packet connection using outbound/",RegexOptions.IgnoreCase)) kind="dial-fail";
   else if(Regex.IsMatch(text,@"connection (upload|download) closed:",RegexOptions.IgnoreCase)) kind="conn-closed-error";
   if(kind=="") return;
   string code=Failure(text);
   if(kind=="conn-closed-error" && code=="dial-error") return;
   // Never retain arbitrary log text, URLs, credentials, addresses or exception messages.
   Enqueue(TransportEvent.Make(kind,tag,code,code=="local-network" || code=="system-dns",code));
  }
  void ParseConnections(ClashConnections snapshot) {
   if(snapshot==null || snapshot.Connections==null) {samples.Clear(); return;}
   double now=Clock();
   HashSet<string> seen=new HashSet<string>();
   Dictionary<string,int> counts=new Dictionary<string,int>();
   foreach(ClashConnection c in snapshot.Connections) {
    if(c==null || String.IsNullOrEmpty(c.Id) || String.IsNullOrEmpty(c.Start) || c.Upload<0 || c.Download<0 || c.Chains==null || !seen.Add(c.Id)) continue;
    // Candidate allowlist chooses the path even with selector/detour chains in either order.
    string tag=""; foreach(string chain in c.Chains) if(tags.Contains(chain)) {tag=chain; break;}
    if(tag=="" || (c.Metadata!=null && (c.Metadata.Type ?? "").Contains("/probe-"))) continue;
    Sample old; double since=now;
    if(samples.TryGetValue(c.Id,out old) && old.Tag==tag && old.Start==c.Start && now-old.Seen<=2.5 &&
       c.Upload>old.Up && c.Download==old.Down) since=old.Since;
    samples[c.Id]=new Sample {Tag=tag,Start=c.Start,Up=c.Upload,Down=c.Download,Since=since,Seen=now};
    if(now-since>=stallSeconds) {int count; counts.TryGetValue(tag,out count); counts[tag]=count+1;}
   }
   List<string> remove=new List<string>();
   foreach(string id in samples.Keys) if(!seen.Contains(id)) remove.Add(id);
   foreach(string id in remove) samples.Remove(id);
   foreach(string tag in tags) {
    int count; counts.TryGetValue(tag,out count); double last;
    if(count>=stallConns) {
     if(!suspected.TryGetValue(tag,out last) || now-last>=60) {
      Enqueue(TransportEvent.Make("stall-suspect",tag,"upload-without-download",false,"connections="+count)); suspected[tag]=now;
     }
    } else suspected.Remove(tag);
   }
  }
  public void Dispose() {
   Stopwatch wait=Stopwatch.StartNew();
   lock(gate) {if(stop.IsCancellationRequested) return; stop.Cancel(); foreach(ClientWebSocket ws in sockets) if(ws!=null) ws.Abort();}
   // Both workers unwind concurrently; share one deadline rather than waiting a second each.
   foreach(Thread worker in workers) worker.Join((int)Math.Max(0,1000-wait.ElapsedMilliseconds));
   // Keep the cancelled source alive until background workers unwind on older .NET.
  }
 }
 // One-shot asynchronous checks; no timers or periodic network traffic.
 public sealed class TransportCheck : IDisposable {
  readonly CancellationTokenSource stop=new CancellationTokenSource();
  readonly object gate=new object();
  readonly List<Socket> sockets=new List<Socket>();
  readonly Stopwatch clock=Stopwatch.StartNew();
  TransportEvent result;
  int remaining;
  public TransportEvent Result {get {lock(gate) return result;}}
  void Finish(TransportEvent value) {lock(gate) {if(result!=null || stop.IsCancellationRequested) return; result=value; foreach(Socket s in sockets) s.Close();}}
  Socket Connect(IPEndPoint target,string bindIP,int interfaceIndex,int timeoutMs) {
   Socket s=new Socket(AddressFamily.InterNetwork,SocketType.Stream,ProtocolType.Tcp);
   lock(gate) {if(stop.IsCancellationRequested || result!=null) {s.Close(); throw new OperationCanceledException();} sockets.Add(s);}
   if(interfaceIndex>0) {
    if(Environment.OSVersion.Platform!=PlatformID.Win32NT) throw new PlatformNotSupportedException();
    s.SetSocketOption(SocketOptionLevel.IP,(SocketOptionName)31,IPAddress.HostToNetworkOrder(interfaceIndex));
   }
   if(!String.IsNullOrEmpty(bindIP)) s.Bind(new IPEndPoint(IPAddress.Parse(bindIP),0));
   IAsyncResult pending=s.BeginConnect(target,null,null);
   // Core may wrap a shared completed Task: never create/dispose its shared wait handle.
   // A pending operation has its own completion handle, retained through EndConnect below.
   if(pending.IsCompleted) {s.EndConnect(pending); return s;}
   using(WaitHandle wait=pending.AsyncWaitHandle) {
    if(!wait.WaitOne(timeoutMs)) throw new TimeoutException();
    s.EndConnect(pending);
   }
   return s;
  }
  string Detail(long bytes) {return "ms="+clock.ElapsedMilliseconds+"; bytes="+bytes;}
  static string BannerFailure(Exception error,int bytes) {
   // NetworkStream wraps socket failures in IOException; inspect the complete inner chain.
   for(Exception current=error;current!=null;current=current.InnerException) {
    SocketException socket=current as SocketException;
    if(socket==null) continue;
    if(socket.SocketErrorCode==SocketError.ConnectionReset || socket.SocketErrorCode==SocketError.ConnectionAborted) return "process-exited";
    if(socket.SocketErrorCode==SocketError.ConnectionRefused) return "refused";
   }
   return bytes>0?"stalled":"timeout";
  }
  public TransportCheck(string bindIP,int interfaceIndex,IPEndPoint[] targets,int timeoutMs) {
   if(targets==null || targets.Length==0 || timeoutMs<1) throw new ArgumentException("Invalid direct check options");
   remaining=targets.Length;
   foreach(IPEndPoint endpoint in targets) {
    IPEndPoint target=endpoint;
    Thread worker=new Thread(delegate() {
     Socket s=null; bool ok=false;
     try {s=Connect(target,bindIP,interfaceIndex,timeoutMs); ok=true;} catch(Exception) {} finally {if(s!=null) s.Close();}
     lock(gate) {remaining--; if(ok) Finish(TransportEvent.Make("net-up","","ok",false,Detail(0)));
      else if(remaining==0) Finish(TransportEvent.Make("net-down","","unreachable",true,Detail(0)));}
    }); worker.IsBackground=true; worker.Start();
   }
  }
  public TransportCheck(string tag,int port,int timeoutMs) {
   if(port<1 || port>65535 || timeoutMs<1) throw new ArgumentException("Invalid path check options");
   Thread worker=new Thread(delegate() {
    string code="timeout"; int bytes=0; Socket s=null;
    try {
     s=Connect(new IPEndPoint(IPAddress.Loopback,port),"",0,timeoutMs);
     s.ReceiveTimeout=Math.Max(1,timeoutMs-(int)clock.ElapsedMilliseconds);
     using(NetworkStream stream=new NetworkStream(s,false)) {
      StringBuilder line=new StringBuilder(); int lines=0;
      while(clock.ElapsedMilliseconds<timeoutMs && bytes<8192 && lines<50) {
       s.ReceiveTimeout=Math.Max(1,timeoutMs-(int)clock.ElapsedMilliseconds);
       int b=stream.ReadByte(); if(b<0) {code="process-exited"; break;} bytes++;
       if(b==10) {if(line.ToString().StartsWith("SSH-2.0-",StringComparison.Ordinal) || line.ToString().StartsWith("SSH-1.99-",StringComparison.Ordinal)) {code="ok"; break;} line.Length=0; lines++;}
       else if(b!=13) line.Append((char)b);
      }
      if(code!="ok" && code!="process-exited" && bytes>0) code="stalled";
     }
    } catch(SocketException e) {code=BannerFailure(e,bytes);}
      catch(IOException e) {code=BannerFailure(e,bytes);}
      catch(Exception) {code=bytes>0?"stalled":"timeout";}
    finally {if(s!=null) s.Close();}
    Finish(TransportEvent.Make("path-check",tag,code,false,Detail(bytes)));
   }); worker.IsBackground=true; worker.Start();
  }
  public void Dispose() {lock(gate) {stop.Cancel(); foreach(Socket s in sockets) s.Close();}}
 }
}
'@
    if ($PSVersionTable.PSEdition -eq 'Core') { Add-Type -TypeDefinition $source }
    else { Add-Type -TypeDefinition $source -ReferencedAssemblies System.dll,System.Core.dll,System.Runtime.Serialization.dll }
}

function Start-TransportEvents {
    param([int]$ApiPort,[string]$Secret,[string[]]$Tags=@(),[double]$StallSeconds=8,[int]$StallConns=2)
    Initialize-TransportEvents
    # Typed construction preserves an empty string[] (New-Object can bind it as null).
    [RemoteAgents.TransportEvents]::new($ApiPort,$Secret,$Tags,$StallSeconds,$StallConns)
}
function Receive-TransportEvents($Reader) { $Reader.Drain() }
function Stop-TransportEvents($Reader) { if ($Reader) { $Reader.Dispose() } }
function Start-TransportDirectCheck {
    param($Network=$null)
    Initialize-TransportEvents
    $ip='';$index=0
    if ($Network) {
        $ip=[string]$Network.ip
        # Integration C adds ifIndex to Get-TransportNetwork. Do not silently drop a requested binding.
        if (($Network -is [Collections.IDictionary] -and $Network.Contains('ifIndex')) -or $Network.PSObject.Properties['ifIndex']) { $index=[int]$Network.ifIndex }
    }
    $targets=[Net.IPEndPoint[]]@((New-Object Net.IPEndPoint ([Net.IPAddress]::Parse('1.1.1.1')),443),(New-Object Net.IPEndPoint ([Net.IPAddress]::Parse('8.8.8.8')),443))
    New-Object RemoteAgents.TransportCheck -ArgumentList $ip,$index,$targets,3000
}
function Receive-TransportDirectCheck($Check) { $Check.Result }
function Stop-TransportDirectCheck($Check) { if ($Check) { $Check.Dispose() } }
function Start-TransportPathCheck {
    param($Candidate,$Profile,[switch]$ConfirmStall,[double]$TimeoutSeconds=12,[double]$StallSeconds=8)
    Initialize-TransportEvents
    if ($ConfirmStall) {
        # Existing SSH probe verifies host keys, authenticates, and reads EXACTLY 64 KiB through probe-<tag>.
        $options=[pscustomobject]@{stallSeconds=$StallSeconds;probeTimeoutSec=$TimeoutSeconds}
        try { $probe=Start-TransportProbe $Profile $Candidate 65536 $options 'switch-confirm' }
        catch { return [pscustomobject]@{mode='none';tag=[string]$Candidate.tag;probe=$null;result=[RemoteAgents.TransportEvent]::Make('path-check',[string]$Candidate.tag,'process-exited',$false,'probe-start-failed');stopped=$false} }
        return [pscustomobject]@{mode='bytes';tag=[string]$Candidate.tag;probe=$probe;result=$null;stopped=$false}
    }
    $check=New-Object RemoteAgents.TransportCheck -ArgumentList ([string]$Candidate.tag),([int]$Candidate.port),([int]($TimeoutSeconds*1000))
    [pscustomobject]@{mode='banner';tag=[string]$Candidate.tag;probe=$check;result=$null;stopped=$false}
}
function Receive-TransportPathCheck($Check) {
    if ($Check.result) { return $Check.result }
    if ($Check.stopped) { return }
    if ($Check.mode -eq 'banner') { $Check.result=$Check.probe.Result }
    elseif (Receive-TransportProbe $Check.probe) {
        $state=$Check.probe.state
        $code=switch ($state.state) { 'ok' {'ok'} 'frozen' {'stalled'} 'slow' {'timeout'} default {'process-exited'} }
        if ($state.diagnostic.reason -eq 'timeout') { $code='timeout' }
        $elapsed=([Diagnostics.Stopwatch]::GetTimestamp()-$Check.probe.sink.Started)*1000/[Diagnostics.Stopwatch]::Frequency
        $Check.result=[RemoteAgents.TransportEvent]::Make('path-check',$Check.tag,$code,$false,('ms='+[math]::Round($elapsed)+'; bytes='+$state.bytes))
    }
    $Check.result
}
function Stop-TransportPathCheck($Check) {
    if (-not $Check -or $Check.stopped) { return }
    $Check.stopped=$true
    if ($Check.mode -eq 'bytes') { Stop-TransportProbe $Check.probe } elseif ($Check.probe) { $Check.probe.Dispose() }
}
