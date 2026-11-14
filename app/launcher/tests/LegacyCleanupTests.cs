using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace RemoteAgents.Launcher
{
    // Explorer cleanup on upgrade/re-upgrade: Install-RemoteDisk.ps1 -CleanupLegacy, owned HKCU verbs, flag, retries.
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
                var owners = new Dictionary<string, string>(); var probes = new List<string>(); Action onRun = null;
                Func<string, string> readOwner = key => { probes.Add(key); string owner; return owners.TryGetValue(key, out owner) ? owner : null; };
                Func<string, string[], int> run = (exe, a) => { calls.Add(exe + " " + string.Join(" ", a)); if (onRun != null) onRun(); if (failure != null) throw failure; return exit; };
                Check(LegacyDiskCleanup.Required(home, readOwner) && probes.Count == 0, "no flag always schedules cleanup without registry probes");
                // The new bundle has no script yet (an old bundle): nothing runs, nothing is recorded, the next start tries again.
                Check(!LegacyDiskCleanup.Run(home, bundle, run, journal.Add, readOwner) && calls.Count == 0 && !LegacyDiskCleanup.Done(home) && journal.Single() == "disk.cleanup.legacy.skipped", "no script: skipped and not recorded");
                File.WriteAllText(script, "");
                // A failure is a journal line only: no exception, no flag, retried at the next start.
                journal.Clear(); exit = 1;
                Check(!LegacyDiskCleanup.Run(home, bundle, run, journal.Add, readOwner) && !LegacyDiskCleanup.Done(home) && journal.Single() == "disk.cleanup.legacy.failed code=1" && calls.Count == 1, "non-zero exit: journal only");
                journal.Clear(); failure = new IOException("secret-looking text");
                Check(!LegacyDiskCleanup.Run(home, bundle, run, journal.Add, readOwner) && !LegacyDiskCleanup.Done(home) && journal.Single() == "disk.cleanup.legacy.failed" && !journal[0].Contains("secret"), "exception: journal code only, never its text");
                failure = new TimeoutException("120 s");
                journal.Clear(); Check(!LegacyDiskCleanup.Run(home, bundle, run, journal.Add, readOwner) && !LegacyDiskCleanup.Done(home), "timeout does not stop the program");
                failure = new OperationCanceledException(); journal.Clear();
                Check(!LegacyDiskCleanup.Run(home, bundle, run, journal.Add, readOwner) && !LegacyDiskCleanup.Done(home) && journal.Count == 0, "tray exit cancels quietly without recording");
                // Success: the flag prevents repeats while no owned verbs reappear.
                failure = null; exit = 0; calls.Clear(); journal.Clear();
                Check(LegacyDiskCleanup.Run(home, bundle, run, journal.Add, readOwner) && LegacyDiskCleanup.Done(home) && calls.Count == 1 && journal.Single() == "disk.cleanup.legacy.ok", "success writes the flag");
                Check(calls[0] == "powershell.exe " + string.Join(" ", args), "the script runs in Windows PowerShell with the cleanup flag only");
                Check(!LegacyDiskCleanup.Run(home, bundle, run, journal.Add, readOwner) && calls.Count == 1, "once per computer: the flag stops repeats");
                Check(File.ReadAllText(LegacyDiskCleanup.Flag(home)).StartsWith("done 20"), "flag records the time");
                const string prefix = @"Software\Classes\Directory\shell\RemoteAgents.Disk.";
                string[] actions = { "download", "sync", "keep-server", "add", "progress" };
                probes.Clear();
                Check(!LegacyDiskCleanup.Required(home, readOwner) && probes.SequenceEqual(actions.Select(a => prefix + a)), "a flagged ordinary start only probes the five old menu keys");
                owners[prefix + "add"] = "another-product";
                owners[prefix + "download"] = "RemoteAgents.Disk.v2";
                owners[prefix + "sync"] = "remoteagents.disk.v1";
                owners[prefix + "other"] = "RemoteAgents.Disk.v1";
                owners[@"Software\Classes\CLSID\DiskPin"] = "RemoteAgents.Disk.v1";
                Check(!LegacyDiskCleanup.Required(home, readOwner), "v2 integration, foreign owners, a different owner case, other verbs and the navigation pin do not invalidate success");
                owners.Clear();
                foreach (string action in actions) {
                    owners[prefix + action] = "RemoteAgents.Disk.v1";
                    Check(LegacyDiskCleanup.Required(home, readOwner), "downgrade marker overrides the done flag: " + action);
                    calls.Clear(); journal.Clear(); onRun = () => owners.Clear();
                    Check(LegacyDiskCleanup.Run(home, bundle, run, journal.Add, readOwner) && calls.Count == 1
                        && LegacyDiskCleanup.Done(home) && !LegacyDiskCleanup.Required(home, readOwner), "re-upgrade cleans again and records success: " + action);
                }
                owners[prefix + "add"] = "RemoteAgents.Disk.v1"; exit = 1; calls.Clear(); journal.Clear();
                Check(!LegacyDiskCleanup.Run(home, bundle, run, journal.Add, readOwner) && owners.Count == 0
                    && !LegacyDiskCleanup.Done(home) && LegacyDiskCleanup.Required(home, readOwner), "partial cleanup removes stale success even if the verbs disappeared before failure");
                exit = 0;
                Check(LegacyDiskCleanup.Run(home, bundle, run, journal.Add, readOwner) && calls.Count == 2
                    && !LegacyDiskCleanup.Required(home, readOwner), "next start retries failed metadata cleanup without requiring remaining verbs");
                Check(LegacyDiskCleanup.Required(home, key => { throw new UnauthorizedAccessException(); }), "unreadable HKCU cannot make a stale success permanent");
            } finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
            Console.WriteLine("PASS: " + count + " Explorer cleanup checks (-CleanupLegacy, owned HKCU verbs, upgrade/downgrade, retries)");
        }
    }
}
