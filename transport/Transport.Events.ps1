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
using System.Xml;
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
 // B4B: pipe I/O is confined to background workers; the daemon only drains/queues.
 public sealed class TransportBusEvent {
  public string topic;
  public Dictionary<string,string> fields;
 }
 public sealed class TransportBus : IDisposable {
  public const int MaxLineBytes=8192, MaxQueuedEvents=512;
  readonly object gate=new object();
  readonly Queue<TransportBusEvent> incoming=new Queue<TransportBusEvent>();
  readonly Queue<string> outgoing=new Queue<string>();
  // Fixed outgoing allowlist also bounds the last-value deduplication table.
  readonly Dictionary<string,string> last=new Dictionary<string,string>();
  readonly AutoResetEvent wake=new AutoResetEvent(false);
  readonly Stream input;
  readonly TextWriter output;
  volatile bool stopped, connected, inputClosed, completing;
  Thread writer;
  bool drained;
  bool networkPending;
  int started;
  long rejected, rejectedCommands, inputDropped, outputDropped, outputRejected, writeErrors;
  readonly bool testBuild;
  public long RejectedCommands {get {return Interlocked.Read(ref rejectedCommands);}}
  public bool Connected {get {return connected;}}
  public bool InputClosed {get {return inputClosed;}}
  public long Rejected {get {return Interlocked.Read(ref rejected);}}
  public long InputDropped {get {return Interlocked.Read(ref inputDropped);}}
  public long OutputDropped {get {return Interlocked.Read(ref outputDropped);}}
  public long OutputRejected {get {return Interlocked.Read(ref outputRejected);}}
  public long WriteErrors {get {return Interlocked.Read(ref writeErrors);}}
  public TransportBus(Stream input,TextWriter output) : this(input,output,false) {}
  public TransportBus(Stream input,TextWriter output,bool testBuild) {this.input=input; this.output=output;this.testBuild=testBuild;}
  public void Start() {
   if(Interlocked.Exchange(ref started,1)!=0) return;
   if(input!=null) {Thread t=new Thread(ReadInput);t.IsBackground=true;t.Name="transport-stdin";t.Start();} else inputClosed=true;
   if(output!=null) {writer=new Thread(WriteLoop);writer.IsBackground=true;writer.Name="transport-stdout";writer.Start();}
  }
  bool AllowedInput(string topic) {
   return topic!=null && (topic.StartsWith("win.",StringComparison.Ordinal) || topic=="net.change" ||
    topic.StartsWith("tick.transport-",StringComparison.Ordinal) || (testBuild && topic=="transport.command"));
  }
  static bool AllowedOutput(string topic) {
   return topic=="transport.stdin.ready" || topic=="transport.status" || topic=="transport.ready" || topic=="transport.mem" ||
    topic=="transport.switch" || topic=="transport.episode" || topic=="net.quality";
  }
  static string Name(XmlElement e) {return e.HasAttribute("item")?e.GetAttribute("item"):e.LocalName;}
  TransportBusEvent Parse(string line) {
   if(!line.StartsWith("@bus ",StringComparison.Ordinal)) return null;
   byte[] bytes=Encoding.UTF8.GetBytes(line.Substring(5));
   using(XmlDictionaryReader reader=JsonReaderWriterFactory.CreateJsonReader(bytes,new XmlDictionaryReaderQuotas {MaxDepth=16,MaxStringContentLength=8192,MaxArrayLength=8192,MaxBytesPerRead=8192,MaxNameTableCharCount=16384})) {
    XmlDocument doc=new XmlDocument();doc.XmlResolver=null;doc.Load(reader);
    XmlElement root=doc.DocumentElement;
    if(root.GetAttribute("type")!="object") return null;
    string topic=null; Dictionary<string,string> fields=null;
    foreach(XmlNode node in root.ChildNodes) {
     XmlElement e=node as XmlElement;if(e==null) return null;
     if(Name(e)=="topic" && topic==null && e.GetAttribute("type")=="string") topic=e.InnerText;
     else if(Name(e)=="fields" && fields==null && e.GetAttribute("type")=="object") {
      fields=new Dictionary<string,string>(StringComparer.Ordinal);
      foreach(XmlNode field in e.ChildNodes) {
       XmlElement f=field as XmlElement;if(f==null) return null;
       string type=f.GetAttribute("type"),key=Name(f);
       if(key.Length==0 || fields.ContainsKey(key) || (type!="string" && type!="number" && type!="boolean" && type!="null")) return null;
       fields.Add(key,type=="null"?"":f.InnerText);
      }
     } else return null;
    }
    if(topic=="transport.command" && !testBuild) Interlocked.Increment(ref rejectedCommands);
    return AllowedInput(topic) && fields!=null?new TransportBusEvent {topic=topic,fields=fields}:null;
   }
  }
  void Consume(byte[] bytes,int count) {
   if(count>0 && bytes[count-1]==13) count--;
   try {
    TransportBusEvent e=Parse(new UTF8Encoding(false,true).GetString(bytes,0,count));
    if(e==null) {Interlocked.Increment(ref rejected);return;}
    lock(gate) {
     connected=true; // Lifetime latch: EOF must never silently re-enable polling.
     if(e.topic=="win.route.changed" || e.topic=="win.iface.changed" || e.topic=="win.addr.changed" || e.topic=="net.change") networkPending=true;
     if(incoming.Count>=MaxQueuedEvents) {incoming.Dequeue();Interlocked.Increment(ref inputDropped);}
     incoming.Enqueue(e);
    }
   } catch(Exception) {Interlocked.Increment(ref rejected);}
  }
  void ReadInput() {
   // Announce from the reader itself, before waiting for the first input or a working path.
   Queue("transport.stdin.ready", "@bus {\"topic\":\"transport.stdin.ready\",\"fields\":{}}");
   byte[] chunk=new byte[4096],line=new byte[MaxLineBytes+1];int used=0;bool skipping=false;
   try {
    while(!stopped) {
     int n=input.Read(chunk,0,chunk.Length);if(n<=0) break;
     for(int i=0;i<n;i++) {
      byte b=chunk[i];
      if(b==10) {if(!skipping) Consume(line,used);used=0;skipping=false;}
      else if(!skipping) {
       if(used==MaxLineBytes+1 || (used==MaxLineBytes && b!=13)) {
        Interlocked.Increment(ref rejected);used=0;skipping=true;
       } else line[used++]=b;
      }
     }
    }
    if(!stopped && !skipping && used>0) Consume(line,used);
   } catch(Exception) {} finally {inputClosed=true;}
  }
  public TransportBusEvent[] Drain(out bool refresh) {
   lock(gate) {TransportBusEvent[] result=incoming.ToArray();incoming.Clear();refresh=networkPending;networkPending=false;return result;}
  }
  public bool Queue(string topic,string line) {return Enqueue(topic,line,false);}
  public bool QueueFinalStatus(string line) {return Enqueue("transport.status",line,true);}
  bool Enqueue(string topic,string line,bool final) {
   if(!AllowedOutput(topic) || line==null || Encoding.UTF8.GetByteCount(line)>MaxLineBytes || line.IndexOfAny(new[]{'\r','\n'})>=0) {Interlocked.Increment(ref outputRejected);return false;}
   lock(gate) {
    if(stopped || completing) return false;
    string previous;if(!final && last.TryGetValue(topic,out previous) && previous==line) return true;
    if(outgoing.Count>=MaxQueuedEvents) {Interlocked.Increment(ref outputDropped);if(final) outgoing.Dequeue();else return false;}
    outgoing.Enqueue(line);last[topic]=line;if(final) completing=true;wake.Set();return true;
   }
  }
  void WritePending() {
   while(!stopped) {
    string line;lock(gate) {if(outgoing.Count==0) return;line=outgoing.Dequeue();}
    output.WriteLine(line);output.Flush();
   }
  }
  void WriteLoop() {
   try {while(!stopped) {
    wake.WaitOne();WritePending();
    lock(gate) {if(completing && outgoing.Count==0 && !stopped) {drained=true;return;}}
   }}
   catch(Exception) {Interlocked.Increment(ref writeErrors);}
  }
  public bool Complete(int timeoutMs) {
   // Shutdown only: reject further publications, drain through Flush, then join with a hard fuse.
   // Dispose remains non-blocking for aborts; blocked pipe workers are background threads.
   lock(gate) {completing=true;wake.Set();}
   Start();
   Thread t=writer;
   bool done=t!=null && t.Join(Math.Max(0,Math.Min(timeoutMs,1000)));
   bool delivered;lock(gate) {delivered=done && drained;}
   Dispose();
   return delivered;
  }
  public void Dispose() {
   // No Join/Flush/pipe close on the daemon thread: a full stdout or open stdin may block forever.
   stopped=true;wake.Set();lock(gate) {incoming.Clear();outgoing.Clear();last.Clear();}
   // Background workers and their wait handle live until process exit if pipe I/O is blocked.
  }
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
  // §4б: snapshots larger than this are rejected, clearing the previous baseline.
  public const int MaxConnectionSamples=4096;
  public const int MaxLogContexts=2048;
  public const int MaxQueuedEvents=512;
  long messages,oversizedSnapshots;
  public long Messages {get {return Interlocked.Read(ref messages);}}
  public long OversizedSnapshots {get {return Interlocked.Read(ref oversizedSnapshots);}}
  public int RetainedSamples {get {return samples.Count;}}
  public int RetainedContexts {get {return contexts.Count;}}
  public int QueuedEvents {get {lock(gate) return queue.Count;}}
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
      // One buffer per connection: a /connections snapshot (up to 4 MB) arrives every second; a new MemoryStream each time would churn the LOH.
      MemoryStream message=new MemoryStream();
      DataContractJsonSerializer serializer=new DataContractJsonSerializer(n==0?typeof(ClashLog):typeof(ClashConnections));
      while(!stop.IsCancellationRequested) {
       message.SetLength(0);
       {
        WebSocketReceiveResult part;
        do {
         part=ws.ReceiveAsync(new ArraySegment<byte>(buffer),stop.Token).GetAwaiter().GetResult();
         if(part.MessageType==WebSocketMessageType.Close) throw new IOException();
         if(part.MessageType!=WebSocketMessageType.Text || message.Length+part.Count>4*1024*1024) throw new IOException();
         message.Write(buffer,0,part.Count);
        } while(!part.EndOfMessage);
        Interlocked.Increment(ref messages);
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
  void Enqueue(TransportEvent e) {lock(gate) {if(queue.Count>=MaxQueuedEvents) {queue.Dequeue(); if(Dropped<Int32.MaxValue) Dropped++;} queue.Enqueue(e);}}
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
  void ParseLog(ClashLog log) {ParseLogAt(log,Clock());}
  void ParseLogAt(ClashLog log,double now) {
   if(log==null || String.IsNullOrEmpty(log.Payload)) return;
   string text=Regex.Replace(log.Payload,@"\x1b\[[0-9;]*m","");
   Match outbound=Outbound.Match(text), context=LogContext.Match(text);
   string tag=outbound.Success && tags.Contains(outbound.Groups[1].Value)?outbound.Groups[1].Value:"";
   if(context.Success) {
    if(contexts.Count>=MaxLogContexts) contexts.Clear();
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
  static bool ValidConnection(ClashConnection c) {
   return c!=null && !String.IsNullOrEmpty(c.Id) && !String.IsNullOrEmpty(c.Start) && c.Upload>=0 && c.Download>=0 && c.Chains!=null;
  }
  void ParseConnections(ClashConnections snapshot) {ParseConnectionsAt(snapshot,Clock());}
  void ParseConnectionsAt(ClashConnections snapshot,double now) {
   if(snapshot==null || snapshot.Connections==null) {samples.Clear(); return;}
   if(snapshot.Connections.Length>MaxConnectionSamples) {
    samples.Clear(); suspected.Clear(); Interlocked.Increment(ref oversizedSnapshots);
    throw new SerializationException("Connection snapshot exceeds retention limit");
   }
   HashSet<string> seen=new HashSet<string>();
   // Remove departed IDs BEFORE adding the new generation: even during churn the map stays <= the snapshot limit.
   foreach(ClashConnection c in snapshot.Connections) if(ValidConnection(c)) seen.Add(c.Id);
   List<string> remove=new List<string>();
   foreach(string id in samples.Keys) if(!seen.Contains(id)) remove.Add(id);
   foreach(string id in remove) samples.Remove(id);
   seen.Clear();
   Dictionary<string,int> counts=new Dictionary<string,int>();
   foreach(ClashConnection c in snapshot.Connections) {
    if(!ValidConnection(c) || !seen.Add(c.Id)) continue;
    // Candidate allowlist chooses the path even with selector/detour chains in either order.
    string tag=""; foreach(string chain in c.Chains) if(tags.Contains(chain)) {tag=chain; break;}
    if(tag=="" || (c.Metadata!=null && (c.Metadata.Type ?? "").Contains("/probe-"))) continue;
    Sample old; double since=now;
    if(samples.TryGetValue(c.Id,out old) && old.Tag==tag && old.Start==c.Start && now-old.Seen<=2.5 &&
       c.Upload>old.Up && c.Download==old.Down) since=old.Since;
    samples[c.Id]=new Sample {Tag=tag,Start=c.Start,Up=c.Upload,Down=c.Download,Since=since,Seen=now};
    if(now-since>=stallSeconds) {int count; counts.TryGetValue(tag,out count); counts[tag]=count+1;}
   }
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
    if(socket.SocketErrorCode==SocketError.ConnectionReset) return "process-exited";
    // ConnectionAborted can originate in the local stack; use timeout/stalled below.
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
    # .NET Framework resolves ReadObject overloads against XmlReader even for a Stream argument.
    if ($PSVersionTable.PSEdition -eq 'Core') { Add-Type -TypeDefinition $source }
    else { Add-Type -TypeDefinition $source -ReferencedAssemblies System.dll,System.Core.dll,System.Runtime.Serialization.dll,System.Xml.dll }
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

function Start-TransportBus {
    param([bool]$TestBuild=$false)
    Initialize-TransportEvents
    try{[Console]::InputEncoding=New-Object Text.UTF8Encoding($false)}catch{}
    [Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
    $inputStream=$null;try{$inputStream=[Console]::OpenStandardInput()}catch{}
    $bus=[RemoteAgents.TransportBus]::new($inputStream,[Console]::Out,$TestBuild)
    $bus.Start()
    $bus
}
function Send-TransportBusEvent($Bus,[string]$Topic,[Collections.IDictionary]$Fields,[switch]$PassThru,[switch]$Final) {
    if(-not $Bus){return}
    # Receiver accepts scalar fields only. Structured status values are JSON strings.
    $safe=[ordered]@{}
    foreach($key in $Fields.Keys){
        $value=$Fields[$key]
        if($null -ne $value -and $value -isnot [string] -and $value -isnot [ValueType]){$value=ConvertTo-Json -InputObject $value -Depth 40 -Compress}
        $safe[[string]$key]=$value
    }
    $line='@bus '+(ConvertTo-Json -InputObject ([ordered]@{topic=$Topic;fields=$safe}) -Depth 4 -Compress)
    if($Topic -eq 'transport.status' -and [Text.Encoding]::UTF8.GetByteCount($line) -gt 8192){
        # Full file state may contain hundreds of candidates. Keep a bounded status summary on the bus;
        # the unchanged transport.json remains the detailed snapshot. Nested fields are JSON strings.
        foreach($key in @('candidates','switches','endpoints','ports','localWeb','lan','helper','portConflict')){$safe.Remove($key)}
        $safe['detailsOmitted']=$true
        $line='@bus '+(ConvertTo-Json -InputObject ([ordered]@{topic=$Topic;fields=$safe}) -Depth 4 -Compress)
        while([Text.Encoding]::UTF8.GetByteCount($line) -gt 8192){
            $longest=@($safe.Keys|Where-Object {$safe[$_] -is [string] -and $safe[$_].Length -gt 32}|Sort-Object {$safe[$_].Length} -Descending|Select-Object -First 1)
            if(-not $longest.Count){break}
            $key=$longest[0];$safe[$key]=$safe[$key].Substring(0,[int]($safe[$key].Length/2))
            $safe['fieldsTruncated']=$true
            $line='@bus '+(ConvertTo-Json -InputObject ([ordered]@{topic=$Topic;fields=$safe}) -Depth 4 -Compress)
        }
    }
    $sent=if($Final -and $Topic -eq 'transport.status'){$Bus.QueueFinalStatus($line)}else{$Bus.Queue($Topic,$line)}
    if($PassThru){$sent}
}
