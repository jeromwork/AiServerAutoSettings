using RemoteAgents.Core;
using Xunit;

public sealed class SyncEngineTests
{
    [Theory]
    [InlineData("idle", 0, 0, 0, true, SyncState.Synced)]
    [InlineData("paused", 0, 0, 0, true, SyncState.Paused)]
    [InlineData("syncing", 100, 2, 0, true, SyncState.Transferring)]
    [InlineData("idle", 0, 0, 0, false, SyncState.Disconnected)]
    [InlineData("idle", 0, 0, 1, true, SyncState.Conflict)]
    [InlineData("weird", 0, 0, 0, true, SyncState.Error)]
    public void MapsTransitions(string state, long bytes, long items, long errors, bool connected, SyncState expected) =>
        Assert.Equal(expected, SyncStatusMapper.Map(new(state, bytes, items, errors, 0, connected, 50, 200)).State);

    [Fact] public void TransferHasProgressAndVolume() { var x=SyncStatusMapper.Map(new("syncing",25,1,0,0,true,75,100)); Assert.Equal(75,x.Percent); Assert.Equal(75,x.BytesDone); Assert.Equal(100,x.BytesTotal); }
    [Fact] public void IgnoreRulesCoverSecretAndGit() { var x=IgnorePolicy.Generate(); Assert.Contains(".git",x); Assert.Contains("(?i).env*",x); Assert.Contains("*.pem",x); }
    [Fact] public void ContextCommandsAreRestricted() { Assert.Equal("exclude",ContextMenuLogic.Parse(["--exclude","a.txt"])!.Name); Assert.Null(ContextMenuLogic.Parse(["--delete"])); }
    [Fact] public void ContextMenuMatchesSpec() { Assert.Equal(new[]{"connect"},ContextMenuLogic.Items(false,false,true,false)); Assert.Equal(new[]{"status"},ContextMenuLogic.Items(true,true,true,false)); Assert.Equal(new[]{"include","versions"},ContextMenuLogic.Items(true,false,false,true)); }
}
