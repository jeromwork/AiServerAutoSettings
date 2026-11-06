using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Xml.Linq;
using RemoteAgents.Core;
using RemoteAgents.Core.ThirdParty;
using Xunit;

public sealed class SyncthingFactAttribute : FactAttribute
{
    public SyncthingFactAttribute() {if(string.IsNullOrEmpty(Environment.GetEnvironmentVariable("RA_TEST_SYNCTHING")))Skip="Run app/test-core-integration.sh with pinned Linux archive";}
}
public sealed class SyncthingIntegrationTests
{
    [SyncthingFact] public async Task RealPeersApiPauseTransferExclusionsAndVersions()
    {
        var root=Directory.CreateTempSubdirectory("ra-core-integration-").FullName;
        var binary=Environment.GetEnvironmentVariable("RA_TEST_SYNCTHING")!;
        var ports=new List<TcpListener>();
        for(int i=0;i<4;i++){var l=new TcpListener(IPAddress.Loopback,0);l.Start();ports.Add(l);}
        var numbers=ports.Select(l=>((IPEndPoint)l.LocalEndpoint).Port).ToArray();ports.ForEach(l=>l.Stop());
        var processes=new List<OwnedProcess>();
        var clients=new List<SyncthingClient>();
        try {
            string[] homes=[Path.Combine(root,"a-home"),Path.Combine(root,"b-home")];
            string[] work=[Path.Combine(root,"a-files"),Path.Combine(root,"b-files")];
            foreach(var home in homes) {
                Directory.CreateDirectory(home);var info=new ProcessStartInfo(binary){RedirectStandardOutput=true,RedirectStandardError=true};
                foreach(var a in new[]{"generate","--home",home,"--no-port-probing"})info.ArgumentList.Add(a);
                using var p=Process.Start(info)!;var stdout=p.StandardOutput.ReadToEndAsync();var stderr=p.StandardError.ReadToEndAsync();
                await p.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(30));await Task.WhenAll(stdout,stderr);Assert.Equal(0,p.ExitCode);
            }
            var ids=homes.Select(h=>XDocument.Load(Path.Combine(h,"config.xml")).Root!.Element("device")!.Attribute("id")!.Value).ToArray();
            for(int i=0;i<2;i++) {
                Directory.CreateDirectory(work[i]);File.WriteAllText(Path.Combine(work[i],$"initial-{i}.txt"),"preserved");
                var settings=LocalEngineSetup.Configure(homes[i],work[i],"test-folder",ids[1-i],numbers[i*2],numbers[(1-i)*2],numbers[i*2+1]);
                var client=new SyncthingClient(numbers[i*2+1],settings.ApiKey);clients.Add(client);
                var process=new OwnedProcess(new Journal(Path.Combine(root,"logs-"+i),"test-host"),"syncthing");processes.Add(process);
                process.Start(binary,["serve","--home",homes[i],"--no-browser","--no-restart","--no-upgrade"]);
            }
            for(int i=0;i<2;i++) {
                int side=i;await Until(async()=>{try{return (await clients[side].GetAsync("system/ping")).GetProperty("ping").GetString()=="pong";}catch(HttpRequestException){return false;}});
                Assert.Equal(SyncState.Paused,(await clients[i].StatusAsync("test-folder",ids[1-i])).State);
                await clients[i].SetRatesAsync(0,0);await clients[i].PauseAsync("test-folder",false);
            }
            await Until(()=>Task.FromResult(File.Exists(Path.Combine(work[0],"initial-1.txt"))&&File.Exists(Path.Combine(work[1],"initial-0.txt"))));
            File.WriteAllText(Path.Combine(work[0],"from-a.txt"),"version-one");
            await Until(()=>Task.FromResult(File.Exists(Path.Combine(work[1],"from-a.txt"))));
            File.WriteAllText(Path.Combine(work[1],"from-b.txt"),"other-direction");
            await Until(()=>Task.FromResult(File.Exists(Path.Combine(work[0],"from-b.txt"))));
            await clients[0].PauseAsync("test-folder",true);
            Assert.Equal(SyncState.Paused,(await clients[0].StatusAsync("test-folder",ids[1])).State);
            File.WriteAllText(Path.Combine(work[1],"after-pause.txt"),"paused");await Task.Delay(1500);
            Assert.False(File.Exists(Path.Combine(work[0],"after-pause.txt")));
            await clients[0].PauseAsync("test-folder",false);await Until(()=>Task.FromResult(File.Exists(Path.Combine(work[0],"after-pause.txt"))));
            await clients[0].SetIgnoresAsync("test-folder",["/excluded.txt"]);
            File.WriteAllText(Path.Combine(work[0],"excluded.txt"),"excluded");File.WriteAllText(Path.Combine(work[0],".env"),"synthetic-secret");
            File.WriteAllText(Path.Combine(work[0],"barrier.txt"),"delivered");await Until(()=>Task.FromResult(File.Exists(Path.Combine(work[1],"barrier.txt"))));
            Assert.False(File.Exists(Path.Combine(work[1],"excluded.txt")));Assert.False(File.Exists(Path.Combine(work[1],".env")));
            await Task.Delay(1100);File.WriteAllText(Path.Combine(work[0],"from-a.txt"),"version-two");
            await Until(async()=>{var versions=await clients[1].VersionsAsync("test-folder");return versions.TryGetProperty("from-a.txt",out _);});
            var events=await clients[0].EventsAsync(0);Assert.NotEmpty(events.EnumerateArray());
            await Until(async()=> (await clients[0].StatusAsync("test-folder",ids[1])).State==SyncState.Synced);
        } finally {foreach(var c in clients)c.Dispose();foreach(var p in processes)p.Dispose();Directory.Delete(root,true);}
    }
    static async Task Until(Func<Task<bool>> condition)
    {var clock=Stopwatch.StartNew();while(clock.Elapsed<TimeSpan.FromSeconds(60)){if(await condition())return;await Task.Delay(200);}Assert.Fail("Timed out waiting for real Syncthing");}
    [Theory][InlineData("file.sync-conflict-20260101-120001-ABCDEFG.txt",true)][InlineData("file.sync-conflict-20260231-120001-ABCDEFG.txt",false)][InlineData("ordinary.txt",false)]
    public void ImportedConflictRecognition(string path,bool expected)=>Assert.Equal(expected,ConflictFiles.IsConflict(path));
}
