using System.Diagnostics;
using System.Text.Json;
using System.Xml.Linq;

namespace RemoteAgents.Core;

public sealed class FirstConnection(SshTransport ssh,Journal journal)
{
    public async Task PrepareAsync(ManagedFolder folder,string hostId,string binary,Func<string,string> resource,CancellationToken token)
    {
        if(Directory.Exists(folder.Home)) throw new InvalidOperationException("Existing local state will not be changed");
        if(!Directory.Exists(folder.LocalPath)||File.Exists(Path.Combine(folder.LocalPath,".stignore"))) throw new InvalidOperationException("Select a new test folder without existing sync policy");
        if(!folder.ServerPath.StartsWith('/')||!folder.ServerState.StartsWith('/')||folder.ServerPath==folder.ServerState) throw new InvalidDataException("Explicit separate absolute server paths required");
        Directory.CreateDirectory(folder.Home);
        var info=new ProcessStartInfo(binary){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};
        foreach(var a in new[]{"generate","--home",folder.Home,"--no-port-probing"}) info.ArgumentList.Add(a);
        using(var p=Process.Start(info)!) {
            var output=p.StandardOutput.ReadToEndAsync(token);var error=p.StandardError.ReadToEndAsync(token);
            using var timeout=CancellationTokenSource.CreateLinkedTokenSource(token);timeout.CancelAfter(TimeSpan.FromSeconds(30));
            try { await p.WaitForExitAsync(timeout.Token); } catch { if(!p.HasExited)p.Kill(true);throw; }
            await Task.WhenAll(output,error); if(p.ExitCode!=0)throw new IOException("Engine identity generation failed");
        }
        var xml=XDocument.Load(Path.Combine(folder.Home,"config.xml")); string localId=xml.Root!.Element("device")!.Attribute("id")!.Value;
        string q(string s)=>SshTransport.Quote(s);
        var state=q(folder.ServerState);
        // Refuse every existing state directory, so neither legacy workers nor interrupted setup get overwritten.
        await Check("test \"$(id -u)\" -ne 0 && umask 077 && mkdir -- "+state);
        foreach(var name in new[]{"server-sync.py","server-sync-runtime.py","server-install-sync.sh"}) await Check("umask 077; cat > "+q(folder.ServerState+"/"+name),resource(name));
        await Check("bash "+q(folder.ServerState+"/server-install-sync.sh")+" "+q(folder.ServerState+"/bin"));
        // Existing user files are merged by Syncthing; no seed/delete/reset operation.
        await Check("test ! -e "+q(folder.ServerPath+"/.stignore")+" && test ! -e "+q(folder.ServerPath+"/.stfolder")+" && mkdir -p -- "+q(folder.ServerPath));
        var manifest=JsonSerializer.Serialize(new{schema=1,projectId=folder.Id,hostId,scopeMode="folder",allowedRoots=new[]{"."},files=Array.Empty<object>()});
        await Check("umask 077; cat > "+q(folder.ServerState+"/manifest.json"),manifest);
        string args=" --state "+state+" --binary "+q(folder.ServerState+"/bin/syncthing")+" --project "+q(folder.Id)+" --host "+q(hostId)+" --workspace "+q(folder.ServerPath)+$" --listen {folder.ServerListenPort} --tunnel {folder.RemoteForwardPort} --gui {folder.ServerApiPort} --mode bidirectional";
        string command="python3 "+q(folder.ServerState+"/server-sync-runtime.py");
        var identity=await Check(command+" identity"+args);
        folder.PeerId=JsonDocument.Parse(identity).RootElement.GetProperty("deviceId").GetString()!;
        await Check(command+" configure"+args+" --manifest "+q(folder.ServerState+"/manifest.json")+" --peer "+q(localId));
        LocalEngineSetup.Configure(folder.Home,folder.LocalPath,folder.FolderId,folder.PeerId,folder.ListenPort,folder.TunnelPort,folder.ApiPort);
        await Check("nohup "+command+" start"+args+" >"+q(folder.ServerState+"/worker.log")+" 2>&1 </dev/null &");
        for(int i=0;i<20;i++) { var r=await ssh.RunAsync(command+" resume"+args,token:token); if(r.ExitCode==0) {journal.Write("setup","configure","ok");return;} await Task.Delay(500,token); }
        throw new IOException("Server API did not become ready; both file trees preserved");
        async Task<string> Check(string cmd,string? input=null) {var r=await ssh.RunAsync(cmd,input,token); if(r.ExitCode!=0) throw new IOException("SSH setup failed; files preserved; inspect journal"); return r.Output;}
    }
}
