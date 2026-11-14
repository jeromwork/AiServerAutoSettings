using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace RemoteAgents.Launcher
{
    // The one-time Explorer clean-up of the first start after the update: Install-RemoteDisk.ps1 -CleanupLegacy, flag file, no stop on failure.
    internal static class LegacyCleanupTests
    {
        static int count;
        static void Check(bool ok, string name) { if (!ok) throw new Exception("Legacy cleanup: " + name); count++; }
        internal static void Run()
        {
            string root = Path.Combine(Path.GetTempPath(), "legacy-cleanup-" + Guid.NewGuid().ToString("N"));
            string home = Path.Combine(root, "home"), bundle = Path.Combine(root, "bundle");
            try {
                Directory.CreateDirectory(Path.Combine(bundle, "disk")); Directory.CreateDirectory(home);
                string script = LegacyDiskCleanup.Script(bundle);
                Check(script == Path.Combine(bundle, "disk", "Install-RemoteDisk.ps1"), "the one Windows entry point of the Disk");
                var args = LegacyDiskCleanup.Arguments(script);
                Check(args.SequenceEqual(new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-CleanupLegacy" }), "arguments: only -CleanupLegacy");
                Check(!args.Contains("-Uninstall") && !args.Contains("-AcceptFile") && !args.Contains("-Profile"), "no uninstall, no folders, no pairing");
                Check(LegacyDiskCleanup.Flag(home) == Path.Combine(home, "state", "legacy-disk-cleanup.done"), "flag file lives in state/");
                var journal = new List<string>(); var calls = new List<string>(); int exit = 0; Exception failure = null;
                Func<string, string[], int> run = (exe, a) => { calls.Add(exe + " " + string.Join(" ", a)); if (failure != null) throw failure; return exit; };
                // The new bundle has no script yet (an old bundle): nothing runs, nothing is recorded, the next start tries again.
                Check(!LegacyDiskCleanup.Run(home, bundle, run, journal.Add) && calls.Count == 0 && !LegacyDiskCleanup.Done(home) && journal.Single() == "disk.cleanup.legacy.skipped", "no script: skipped and not recorded");
                File.WriteAllText(script, "");
                // A failure is a journal line only: no exception, no flag, retried at the next start.
                journal.Clear(); exit = 1;
                Check(!LegacyDiskCleanup.Run(home, bundle, run, journal.Add) && !LegacyDiskCleanup.Done(home) && journal.Single() == "disk.cleanup.legacy.failed code=1" && calls.Count == 1, "non-zero exit: journal only");
                journal.Clear(); failure = new IOException("secret-looking text");
                Check(!LegacyDiskCleanup.Run(home, bundle, run, journal.Add) && !LegacyDiskCleanup.Done(home) && journal.Single() == "disk.cleanup.legacy.failed" && !journal[0].Contains("secret"), "exception: journal code only, never its text");
                failure = new TimeoutException("120 s");
                journal.Clear(); Check(!LegacyDiskCleanup.Run(home, bundle, run, journal.Add) && !LegacyDiskCleanup.Done(home), "timeout does not stop the program");
                failure = new OperationCanceledException(); journal.Clear();
                Check(!LegacyDiskCleanup.Run(home, bundle, run, journal.Add) && !LegacyDiskCleanup.Done(home) && journal.Count == 0, "tray exit cancels quietly without recording");
                // Success: the flag is written once, and a done clean-up never runs again.
                failure = null; exit = 0; calls.Clear(); journal.Clear();
                Check(LegacyDiskCleanup.Run(home, bundle, run, journal.Add) && LegacyDiskCleanup.Done(home) && calls.Count == 1 && journal.Single() == "disk.cleanup.legacy.ok", "success writes the flag");
                Check(calls[0] == "powershell.exe " + string.Join(" ", args), "the script runs in Windows PowerShell with the cleanup flag only");
                Check(!LegacyDiskCleanup.Run(home, bundle, run, journal.Add) && calls.Count == 1, "once per computer: the flag stops repeats");
                Check(File.ReadAllText(LegacyDiskCleanup.Flag(home)).StartsWith("done 20"), "flag records the time");
            } finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
            Console.WriteLine("PASS: " + count + " one-time Explorer clean-up checks (-CleanupLegacy, flag file, failures never stop the program)");
        }
    }
}
