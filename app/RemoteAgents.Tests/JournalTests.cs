using System.IO.Compression;
using RemoteAgents.Core;
using Xunit;

public sealed class JournalTests : IDisposable
{
    readonly string root = Directory.CreateTempSubdirectory("ra-journal-").FullName;
    public void Dispose() => Directory.Delete(root, true);
    [Fact] public void LocalEventExistsBeforeAnyNetworkAndQueueSurvivesFailure()
    {
        var j = new Journal(root,"test-host"); j.Write("app","start","ok");
        Assert.Single(Directory.GetFiles(root,"*.jsonl"));
        Assert.Single(Directory.GetFiles(j.QueuePath,"*.jsonl"));
        Assert.Contains("hostId",File.ReadAllText(Directory.GetFiles(root,"*.jsonl")[0]));
    }
    [Fact] public async Task QueueAcknowledgesOnlySuccessfulSends()
    {
        var j = new Journal(root,"test-host"); j.Write("ssh","exit","failed",42,255);
        Assert.Equal(0,await j.FlushQueueAsync((_,_)=>Task.FromResult(false),default));
        Assert.Single(Directory.GetFiles(j.QueuePath,"*.jsonl"));
        Assert.Equal(1,await j.FlushQueueAsync((_,_)=>Task.FromResult(true),default));
        Assert.Empty(Directory.GetFiles(j.QueuePath,"*.jsonl"));
    }
    [Fact] public void SecretsAndContentsCannotEnterJournalOrDiagnostics()
    {
        var j = new Journal(root,"test-host",1);
        string[] forbidden = ["X-API-Key: SECRET123", "password=letmein", "Bearer eyJtoken", "-----BEGIN PRIVATE KEY-----", "file contents\nprivate", "api_key=abc"];
        foreach(var s in forbidden) j.Write(s,s,s);
        File.WriteAllText(Path.Combine(root,"config.xml"),string.Join('\n',forbidden));
        var zip = j.CollectDiagnostics(Path.Combine(root,"diagnostics.zip"));
        using var archive = ZipFile.OpenRead(zip);
        foreach(var entry in archive.Entries) { using var r = new StreamReader(entry.Open()); var text=r.ReadToEnd(); foreach(var s in forbidden) Assert.DoesNotContain(s,text); }
        Assert.DoesNotContain(archive.Entries,x=>x.Name=="config.xml");
        Assert.True(Directory.GetFiles(root,"*.jsonl").Length>1);
    }
}
