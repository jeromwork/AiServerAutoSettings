using System;
using System.IO;

namespace RemoteAgents.Launcher
{
    // One-time clean-up after the update that removed the Explorer integration. The old version registered Explorer
    // verbs in HKCU and decorated Disk folders (desktop.ini, attributes, placeholders); disk/Install-RemoteDisk.ps1
    // -CleanupLegacy takes that away and exits. It keeps user files, Syncthing, its config.xml, the accepted folders and
    // the Disk pin in the Explorer pane. The flag file records success; a failure goes to the journal only, never stops
    // the program, and is retried at the next start.
    internal static class LegacyDiskCleanup
    {
        internal static string Flag(string home) { return Path.Combine(home, "state", "legacy-disk-cleanup.done"); }
        internal static bool Done(string home) { return File.Exists(Flag(home)); }
        internal static string Script(string bundle) { return Path.Combine(bundle, "disk", "Install-RemoteDisk.ps1"); }
        internal static string[] Arguments(string script)
        { return new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-CleanupLegacy" }; }

        // run: (exe, args) -> exit code. true = clean-up done now (flag written). Journal gets event codes only.
        internal static bool Run(string home, string bundle, Func<string, string[], int> run, Action<string> journal)
        {
            if (Done(home)) return false;
            string script = Script(bundle);
            if (!File.Exists(script)) { journal("disk.cleanup.legacy.skipped"); return false; }
            try {
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
