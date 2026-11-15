#if !PORTABLE_TEST
using System;
using System.IO;
using System.Runtime.InteropServices;

namespace RemoteAgents.Launcher
{
    internal static class DiskExplorerNative
    {
        internal static DiskExplorerService CreateService(string iconDirectory, Action<string> log)
        { return new DiskExplorerService(new DiskExplorerFileSystem(), new DiskExplorerIcons(iconDirectory), new DiskExplorerNotifier(), log); }
        internal static DiskExplorerRegistry CreateRegistry(Action<string> log)
        { return new DiskExplorerRegistry(new DiskExplorerCurrentUserRegistry(), log, DiskExplorerNotifier.AssociationsChanged); }
        internal static void CleanupIcons(string iconDirectory) { DiskIconFile.Cleanup(iconDirectory); }
    }
    internal sealed class DiskExplorerNotifier : IDiskExplorerNotifier
    {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern void SHChangeNotify(uint change, uint flags, string item1, string item2);
        public void Changed(string path)
        {
            SHChangeNotify(0x2000, 0x2005, path, null); // SHCNE_UPDATEITEM, SHCNF_PATHW | FLUSHNOWAIT
            SHChangeNotify(0x1000, 0x2005, Path.GetDirectoryName(path), null);
        }
        internal static void AssociationsChanged() { SHChangeNotify(0x08000000, 0, null, null); }
    }
}
#endif
