using System.Text.Json;
using RemoteAgents.Core;
using Xunit;

public sealed class DiscoveryTests
{
    [Fact] public void FindsOnlyExistingProjectBindings()
    {
        var root = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        try {
            var state = Path.Combine(root,"sync","projects","sample","host"); Directory.CreateDirectory(state);
            File.WriteAllText(Path.Combine(state,"project.json"), JsonSerializer.Serialize(new { projectId="sample", hostId="host", replicaPath="/tmp/replica", folderId="folder" }));
            Assert.Single(SyncDiscovery.Find(root));
        } finally { if (Directory.Exists(root)) Directory.Delete(root,true); }
    }
    [Fact] public void PauseCanBeResumed() { var p = new PauseController(); p.PauseUntilResume(); Assert.True(p.IsPaused); p.Resume(); Assert.False(p.IsPaused); }
}
