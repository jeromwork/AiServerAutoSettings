using System.Collections.Generic;

namespace RemoteAgents.Launcher
{
    // Desired selection can be ahead of a failed apply. Explorer must keep showing the actual
    // locally configured share until REST confirms detachment; a REST outage retains the last
    // verified binding instead of relabelling a still-synchronizing directory as an ordinary copy.
    internal static class DiskExplorerObservation
    {
        internal static bool EffectiveSelection(bool desired, string name, string path, DiskSyncSnapshot snapshot, IDictionary<string, string> lastKnown)
        {
            if (desired) return true;
            if (snapshot != null && snapshot.Failure.Length == 0) {
                DiskSyncFolder actual;
                return snapshot.Folders.TryGetValue(name, out actual) && actual.Id.Length > 0 && actual.Shared && DiskSyncSnapshot.SamePath(actual.Path, path);
            }
            string previous;
            return lastKnown != null && lastKnown.TryGetValue(name, out previous) && DiskSyncSnapshot.SamePath(previous, path);
        }
    }
}
