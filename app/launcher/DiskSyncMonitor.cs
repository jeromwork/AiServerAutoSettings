using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;

namespace RemoteAgents.Launcher
{
    // One short REST cache for the tray, folder tab and progress window; the existing REST reader
    // remains the authority. No independent synchronization protocol is implemented here.
    internal static class DiskSyncMonitor
    {
        static readonly object gate = new object();
        static readonly DiskSyncReader reader = new DiskSyncReader();
        static string binding = "";
        static Dictionary<string, string> observedPaths = new Dictionary<string, string>();
        static DateTime readAt;
        static DiskSyncSnapshot snapshot;
        internal static DiskSyncSnapshot Read(string home, Dictionary<string, string> paths, CancellationToken token)
        {
            string key = home;
            lock (gate) {
                token.ThrowIfCancellationRequested();
                if (key == binding && snapshot != null && paths.All(p => observedPaths.ContainsKey(p.Key) && DiskSyncSnapshot.SamePath(observedPaths[p.Key], p.Value)) && (DateTime.UtcNow - readAt).TotalMilliseconds < 2400) return snapshot;
                var next = reader.Read(home, paths, token);
                binding = key; observedPaths = new Dictionary<string, string>(paths, StringComparer.OrdinalIgnoreCase); readAt = DateTime.UtcNow; snapshot = next;
                return next;
            }
        }
    }
}
