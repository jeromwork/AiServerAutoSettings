using System;
using System.IO;
using Microsoft.Win32;

namespace RemoteAgents.Launcher
{
    // One-time clean-up after the update that removed the Explorer integration. The old version registered Explorer
    // verbs in HKCU and decorated Disk folders (desktop.ini, attributes, placeholders); disk/Install-RemoteDisk.ps1
    // -CleanupLegacy takes that away and exits. It keeps user files, Syncthing, its config.xml, the accepted folders and
    // the Disk pin in the Explorer pane. The flag file records success; a failure goes to the journal only, never stops
    // the program, and is retried at the next start. Old owned verbs invalidate that flag after a downgrade/re-upgrade.
    internal static class LegacyDiskCleanup
    {
        internal static string Flag(string home) { return Path.Combine(home, "state", "legacy-disk-cleanup.done"); }
        internal static bool Done(string home) { return File.Exists(Flag(home)); }
        // These five HKCU verbs and their exact ownership mark are shared by the old C# and PowerShell integration.
        // Probe only them: no PowerShell, filesystem traversal, or Explorer navigation-pane keys on an ordinary start.
        const string Prefix = @"Software\Classes\Directory\shell\RemoteAgents.Disk.";
        static readonly string[] Actions = { "download", "sync", "keep-server", "add", "progress" };
        static string ReadOwner(string key)
        { using (var item = Registry.CurrentUser.OpenSubKey(key)) return item == null ? null : item.GetValue("RemoteAgentsOwner") as string; }
        internal static bool Required(string home, Func<string, string> readOwner = null)
        {
            if (!Done(home)) return true;
            try {
                foreach (string action in Actions)
                    if ((readOwner ?? ReadOwner)(Prefix + action) == "RemoteAgents.Disk.v1") return true;
                return false;
            }
            // If HKCU could not be inspected, let the cleanup attempt report success/failure rather than trust a stale flag.
            catch (Exception) { return true; }
        }
        internal static string Script(string bundle) { return Path.Combine(bundle, "disk", "Install-RemoteDisk.ps1"); }
        internal static string[] Arguments(string script)
        { return new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-CleanupLegacy" }; }

        // run: (exe, args) -> exit code. true = clean-up done now (flag written). Journal gets event codes only.
        internal static bool Run(string home, string bundle, Func<string, string[], int> run, Action<string> journal, Func<string, string> readOwner = null)
        {
            if (!Required(home, readOwner)) return false;
            string script = Script(bundle);
            if (!File.Exists(script)) { journal("disk.cleanup.legacy.skipped"); return false; }
            try {
                // A partial retry may remove the verbs and then fail on folder metadata. Its old success must not survive.
                if (Done(home)) File.Delete(Flag(home));
                int code = run("powershell.exe", Arguments(script));
                if (code != 0) { journal("disk.cleanup.legacy.failed code=" + code); return false; }
                Files.Atomic(Flag(home), "done " + DateTime.UtcNow.ToString("o") + "\n");
                journal("disk.cleanup.legacy.ok");
                return true;
            }
            catch (OperationCanceledException) { return false; }
            catch (Exception) { journal("disk.cleanup.legacy.failed"); return false; }
        }
    }
}
