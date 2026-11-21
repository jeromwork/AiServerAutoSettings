using System;
using System.IO;

namespace RemoteAgents.Launcher
{
    internal static partial class Program
    {
        // Shared startup branch: called after instance/installer gates, before install or tray.
        // The launch action releases those gates and starts the installed image.
        internal static bool ResumePreviousRollbackAtStartup(string home, bool owned, Action<string, bool> launch)
        {
            if (!owned || !UpgradeInstaller.RecoverPreviousRollback(home)) return false;
            launch(Path.Combine(home, Product.ExeName), false);
            return true;
        }
    }
}
