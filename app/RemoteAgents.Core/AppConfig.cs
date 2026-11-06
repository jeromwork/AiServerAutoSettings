using System.Text.Json;
using System.Text.RegularExpressions;
namespace RemoteAgents.Core;

public sealed class AppConfig
{
    public int SchemaVersion {get;set;}=1;
    public string HostId {get;set;}="host-"+Guid.NewGuid().ToString("N");
    public bool AutoStart {get;set;}
    public bool ContextMenu {get;set;}
    public SshProfile? Profile {get;set;}
    public string? ServerLogDirectory {get;set;}
    public List<ManagedFolder> Folders {get;set;}=[];
    public static AppConfig Load(string path)
    {
        if(!File.Exists(path)) return new();
        var config=JsonSerializer.Deserialize<AppConfig>(File.ReadAllText(path))??throw new InvalidDataException("Empty config");
        if(config.SchemaVersion!=1||!Regex.IsMatch(config.HostId,"^[a-z0-9][a-z0-9_-]{0,63}$")) throw new InvalidDataException("Unsupported config");
        return config;
    }
    public void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path+".tmp",JsonSerializer.Serialize(this,new JsonSerializerOptions{WriteIndented=true})); File.Move(path+".tmp",path,true);
    }
}
public sealed class ManagedFolder
{
    public string Id {get;set;}="p-"+Guid.NewGuid().ToString("N");
    public string LocalPath {get;set;}="";
    public string Home {get;set;}="";
    public string ServerPath {get;set;}="";
    public string ServerState {get;set;}="";
    public string PeerId {get;set;}="";
    public int ListenPort {get;set;}
    public int TunnelPort {get;set;}
    public int ApiPort {get;set;}
    public int ServerListenPort {get;set;}
    public int RemoteForwardPort {get;set;}
    public int ServerApiPort {get;set;}
    public bool Enabled {get;set;}=true;
    public DateTimeOffset? PauseUntil {get;set;}
    public bool PauseUntilResume {get;set;}
    public string[] Exclusions {get;set;}=[];
    public string FolderId => "ra-"+Id;
}
