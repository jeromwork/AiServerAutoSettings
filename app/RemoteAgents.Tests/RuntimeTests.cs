using RemoteAgents.Core;
using Xunit;

public sealed class RuntimeTests
{
    [Theory][InlineData("Permission denied (publickey)","authentication-denied")][InlineData("Connection reset by peer","connection-reset")][InlineData("arbitrary secret output","unclassified-exit")]
    public void SshReasonsAreClosedVocabulary(string input,string expected)=>Assert.Equal(expected,SshTransport.Classify(input));
    [Fact] public void ProfileUsesStrictTrustAndKeyPathsOnly()
    {
        var args=new SshProfile("example.invalid","ordinary-user","key-path","hosts-path","config-path","ssh").Arguments();
        Assert.Contains("StrictHostKeyChecking=yes",args); Assert.Contains("BatchMode=yes",args); Assert.Contains("key-path",args);
    }
    [Fact] public void TamperedEngineIsRejected()
    {
        var path=Path.GetTempFileName(); try { File.WriteAllText(path,"tampered"); Assert.Throws<InvalidDataException>(()=>EngineResource.Verify(path,EngineResource.WindowsSha256)); } finally {File.Delete(path);}
    }
}
