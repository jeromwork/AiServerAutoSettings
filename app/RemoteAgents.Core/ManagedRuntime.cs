using System.Xml.Linq;
using RemoteAgents.Core.ThirdParty;
namespace RemoteAgents.Core;

public sealed class ManagedRuntime : IDisposable
{
    readonly ManagedFolder folder; readonly SshProfile profile; readonly Journal journal; readonly string binary;
    readonly OwnedProcess engine,tunnel;
    readonly SshTransport ssh;
    readonly RestartThrottle throttle=new(TimeSpan.FromSeconds(10));
    public SyncthingClient Api {get;}
    public SyncStatus Status {get;private set;}=new(SyncState.Disconnected);
    public string[] Conflicts {get;private set;}=[];
    public Queue<string> RecentFiles {get;}=new();
    long lastEvent;
    long lastBytes; DateTimeOffset lastSample=DateTimeOffset.UtcNow;
    public ManagedRuntime(ManagedFolder folder,SshProfile profile,Journal journal,string binary,string workersRoot)
    {
        var expected=Path.GetFullPath(Path.Combine(workersRoot,folder.Id));
        if(Path.GetFullPath(folder.Home)!=expected) throw new InvalidDataException("Worker must belong to this application");
        this.folder=folder;this.profile=profile;this.journal=journal;this.binary=binary;
        engine=new(journal,"syncthing");tunnel=new(journal,"tunnel");ssh=new(profile,journal);
        var config=XDocument.Load(Path.Combine(folder.Home,"config.xml"));
        Api=new(folder.ApiPort,config.Root!.Element("gui")!.Element("apikey")!.Value);
    }
    public async Task TickAsync(CancellationToken token)
    {
        try {
            if(!engine.Running) engine.Start(binary,["serve","--home",folder.Home,"--no-browser","--no-restart","--no-upgrade"]);
            if(!tunnel.Running&&throttle.TryStart(DateTimeOffset.UtcNow)) {
                using var probe=CancellationTokenSource.CreateLinkedTokenSource(token);probe.CancelAfter(TimeSpan.FromSeconds(5));
                await ssh.ProbeAsync(probe.Token);
                tunnel.Start(profile.SshExecutable,ssh.TunnelArguments(folder.TunnelPort,folder.ServerListenPort,folder.RemoteForwardPort,folder.ListenPort));
            }
            bool paused=folder.PauseUntilResume||folder.PauseUntil>DateTimeOffset.UtcNow;
            await Api.PauseAsync(folder.FolderId,paused);
            Status=await Api.StatusAsync(folder.FolderId,folder.PeerId);
            Conflicts=await Task.Run(()=>ConflictFiles.Find(folder.LocalPath),token);
            if(Conflicts.Length>0)Status=new(SyncState.Conflict,Detail:"Конфликтные копии сохранены");
            if(!tunnel.Running&&!paused)Status=new(SyncState.Disconnected);
            var connections=await Api.GetAsync("system/connections",token);
            if(connections.GetProperty("connections").TryGetProperty(folder.PeerId,out var peer)) {
                long bytes=peer.GetProperty("inBytesTotal").GetInt64()+peer.GetProperty("outBytesTotal").GetInt64();var now=DateTimeOffset.UtcNow;
                Status=Status with {BytesPerSecond=Math.Max(0,(bytes-lastBytes)/(now-lastSample).TotalSeconds)};lastBytes=bytes;lastSample=now;
            }
            var events=await Api.EventsAsync(lastEvent);
            foreach(var e in events.EnumerateArray()) {
                lastEvent=Math.Max(lastEvent,e.GetProperty("id").GetInt64());
                if(Enum.TryParse<EventType>(e.GetProperty("type").GetString(),out var type)) {
                    journal.Write("syncthing","event",type.ToString().ToLowerInvariant());
                    if(type==EventType.ItemFinished&&e.GetProperty("data").TryGetProperty("item",out var name)) {RecentFiles.Enqueue(name.GetString()!);while(RecentFiles.Count>10)RecentFiles.Dequeue();}
                }
            }
        } catch(Exception ex) when(ex is IOException or HttpRequestException or TaskCanceledException or InvalidOperationException or System.Text.Json.JsonException or UnauthorizedAccessException) {
            Status=new(SyncState.Error,Detail:"Не удалось проверить движок или канал; см. журнал");journal.Write("runtime","poll","unavailable");
        }
    }
    public async Task PauseAsync(TimeSpan? duration,bool untilResume=false)
    {
        folder.PauseUntilResume=untilResume;folder.PauseUntil=duration is null?null:DateTimeOffset.UtcNow+duration;
        await Api.PauseAsync(folder.FolderId,untilResume||duration!=null);journal.Write("user","pause",untilResume||duration!=null?"paused":"resumed");
    }
    public void ResetTunnel() {tunnel.Dispose();journal.Write("network","route","reconnect-requested");}
    public void Dispose() {tunnel.Dispose();engine.Dispose();Api.Dispose();}
}
