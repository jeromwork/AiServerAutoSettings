using System.Diagnostics;
using System.Reflection;
using System.Security.Cryptography;
using System.Xml.Linq;

namespace RemoteAgents.Core;

public static class EngineResource
{
    public const string Version = "2.1.7";
    public const string WindowsSha256 = "cd9aea20afda2b9bdba5aff2e6ac964ed5c2e741ed4ceb48ad9e1be096ca7891";
    public static string Extract(Assembly assembly, string name, string destination, string sha)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        if(File.Exists(destination)) { Verify(destination,sha); return destination; }
        var tmp = destination+"."+Guid.NewGuid().ToString("N")+".tmp";
        try {
            using(var input=assembly.GetManifestResourceStream(name)??throw new InvalidDataException("Missing embedded resource"))
            using(var output=File.Create(tmp)) input.CopyTo(output);
            Verify(tmp,sha); File.Move(tmp,destination); return destination;
        } finally { if(File.Exists(tmp)) File.Delete(tmp); }
    }
    public static void Verify(string path,string sha)
    { using var stream=File.OpenRead(path); if(!Convert.ToHexString(SHA256.HashData(stream)).Equals(sha,StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Resource SHA256 mismatch"); }
}

// Own process only: never find/kill by process name or attach to an existing worker.
public sealed class OwnedProcess : IDisposable
{
    readonly Journal journal;
    readonly string component;
    Process? process;
    public bool Running => process is { HasExited: false };
    public OwnedProcess(Journal journal,string component) {this.journal=journal;this.component=component;}
    public void Start(string executable,IEnumerable<string> arguments)
    {
        if(Running) return;
        var info=new ProcessStartInfo(executable) { UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true };
        foreach(var arg in arguments) info.ArgumentList.Add(arg);
        process=new Process { StartInfo=info, EnableRaisingEvents=true };
        process.OutputDataReceived+=(_,e)=> { if(e.Data!=null) journal.Write(component,"stdout","received",bytes:e.Data.Length); };
        process.ErrorDataReceived+=(_,e)=> { if(e.Data!=null) journal.Write(component,"stderr","received",bytes:e.Data.Length); };
        var owned=process;
        process.Exited+=(_,_)=>journal.Write(component,"exit","observed",exitCode:owned.ExitCode);
        process.Start(); process.BeginOutputReadLine(); process.BeginErrorReadLine(); journal.Write(component,"start","ok");
    }
    public void Dispose() { if(Running) { process!.Kill(true); process.WaitForExit(5000); } process?.Dispose(); process=null; }
}

public static class LocalEngineSetup
{
    public static (string DeviceId,string ApiKey) Configure(string home,string workspace,string folder,string peer,int listen,int tunnel,int api)
    {
        // Only a new application-owned home may be configured; existing bindings are never imported here.
        var path=Path.Combine(home,"config.xml"); var xml=XDocument.Load(path); var root=xml.Root!;
        string local=root.Elements("device").First().Attribute("id")!.Value;
        root.Elements("folder").Remove();
        var options=root.Element("options")!;
        void Put(XElement parent,string key,object value) { parent.Elements(key).Remove(); parent.Add(new XElement(key,value)); }
        foreach(var key in new[]{"globalAnnounceEnabled","localAnnounceEnabled","relaysEnabled","natEnabled","startBrowser","crashReportingEnabled"}) Put(options,key,"false");
        Put(options,"autoUpgradeIntervalH",0); Put(options,"urAccepted",-1); Put(options,"listenAddress",$"tcp://127.0.0.1:{listen}");
        Put(root.Element("gui")!,"address",$"127.0.0.1:{api}");
        root.Add(new XElement("device",new XAttribute("id",peer),new XElement("address",$"tcp://127.0.0.1:{tunnel}"),new XElement("autoAcceptFolders",false)));
        root.Add(new XElement("folder",new XAttribute("id",folder),new XAttribute("path",workspace),new XAttribute("type","sendreceive"),new XAttribute("paused",true),new XAttribute("rescanIntervalS",3600),new XAttribute("fsWatcherEnabled",true),
            new XElement("device",new XAttribute("id",local)),new XElement("device",new XAttribute("id",peer)),
            new XElement("versioning",new XAttribute("type","simple"),new XElement("param",new XAttribute("key","keep"),new XAttribute("val",int.MaxValue)),new XElement("param",new XAttribute("key","cleanoutDays"),new XAttribute("val",30)),new XElement("cleanupIntervalS",3600))));
        if(File.Exists(Path.Combine(workspace,".stignore"))) throw new IOException("Existing ignore policy must be reviewed manually");
        File.WriteAllText(Path.Combine(workspace,".stignore"),IgnorePolicy.Generate()); xml.Save(path);
        return(local,root.Element("gui")!.Element("apikey")!.Value);
    }
}
