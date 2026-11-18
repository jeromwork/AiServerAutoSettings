using System;
using System.Linq;

namespace RemoteAgents.Launcher
{
    // Structural changes must recreate items and click handlers together.
    internal sealed class TrayMenuState
    {
        string[] ids;
        internal void Refresh(TrayMenuEntry[] entries, Action<TrayMenuEntry[]> rebuild, Action<int, TrayMenuEntry> update)
        {
            var next = entries.Select(e => e.Id).ToArray();
            if (ids == null || !ids.SequenceEqual(next)) {
                rebuild(entries);
                ids = next;
            }
            for (int i = 0; i < entries.Length; i++)
                if (entries[i].Id != "separator") update(i, entries[i]);
        }
    }
}
