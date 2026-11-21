namespace RemoteAgents.Launcher
{
    // No UI or clock: repeated final colours never produce another journal entry.
    internal static class TrayStatusLog
    {
        internal static void Write(Journal log, string previous, string current)
        {
            if (previous == current) return;
            log.Write(LogLevel.Info, "net", "status.changed", "from", previous, "to", current);
        }
    }
}
