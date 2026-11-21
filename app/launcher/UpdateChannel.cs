namespace RemoteAgents.Launcher
{
    // The test build replaces the main one (same names, service, adapter, ports); only the update source differs.
    internal static class UpdateChannel
    {
        internal const string MainDir = "~/.local/share/remote-agents/dist";
        internal const string TestDir = "~/.local/share/remote-agents/dist-test";
#if UPDATE_CHANNEL_TEST
        internal const bool IsTest = true;
#else
        internal const bool IsTest = false;
#endif
        internal static string RemoteDir { get { return IsTest ? TestDir : MainDir; } }
        // Test build: the configured remoteDir is ignored (a configured main dist must not pull the build back).
        internal static string ResolveRemoteDir(bool isTest, string configured)
        {
            if (isTest) return TestDir;
            return string.IsNullOrWhiteSpace(configured) ? MainDir : configured;
        }
    }
}
