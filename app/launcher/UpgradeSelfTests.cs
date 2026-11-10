using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Principal;
using System.Threading;

namespace RemoteAgents.Launcher
{
    internal static class UpgradeSelfTests
    {
        // Real net48/Win32/PS 5.1, with isolated synthetic modules. No network, Run registration or VPN.
        public static int Run(string root)
        {
            Directory.CreateDirectory(root);
            string work = Path.Combine(root, "upgrade-" + Guid.NewGuid().ToString("N")), home = Path.Combine(work, "home");
            Directory.CreateDirectory(home);
            string neighborExe = Path.Combine(home, Product.IsVpn ? "RemoteAgents.exe" : "RemoteVPN.exe");
            string neighborBundle = Path.Combine(home, Product.IsVpn ? "bundle" : "vpn-bundle", "current.txt");
            Files.Atomic(neighborExe, "neighbor-image"); Files.Atomic(neighborBundle, "neighbor-version");
            var checks = new List<string>(); Process tray = null; string phase = "initialize";
            Action<string, bool> check = (name, ok) => { phase = name; if (!ok) throw new InvalidOperationException(); checks.Add(name); };
            try {
                check("product-identity", Program.InstanceName(home, WindowsIdentity.GetCurrent().User).StartsWith(Product.Name + ".Launcher."));
                string source = Path.Combine(work, "downloaded", Product.ExeName); Directory.CreateDirectory(Path.GetDirectoryName(source)); File.Copy(Program.Exe, source);
                string oldZip = Fixture(work, "0.0.1", true), newZip = Fixture(work, "0.0.2", true), badZip = Fixture(work, "0.0.3", false);
                phase = "install-old"; UpgradeInstaller.Apply(home, source, oldZip, Program.Version, false, f => External.SelfTest(f, home, CancellationToken.None));
                string target = Path.Combine(home, Product.ExeName);
                string cfg = "{\r\n\"schema\":1,\"version\":1,\"components\":{},\"update\":{\"enabled\":false},\"transport\":{\"keep\":true}}\r\n";
                File.WriteAllText(Path.Combine(home, "config.json"), cfg, Files.Utf8);
                foreach (string directory in new[] { "state", "secrets", "logs" }) { Directory.CreateDirectory(Path.Combine(home, directory)); File.WriteAllText(Path.Combine(home, directory, "preserve.txt"), "preserve\r\n", Files.Utf8); }
                phase = "old-tray"; tray = Start(target, home); Wait(() => Healthy(home, "0.0.1"), 20000);
                check("old-tray-real-process", !tray.HasExited);
                if (!Product.IsVpn) {
                Json.Write(Path.Combine(home, "state", "migration.json"), new { phase = "accepted" });
                phase = "recovery-skips-running-tray";
                using (var host = Process.Start(new ProcessStartInfo(source, "--recovery-host --home " + Files.Quote(home)) { UseShellExecute = false }))
                    check("recovery-keeps-single-tray", host.WaitForExit(10000) && host.ExitCode == 0 && !tray.HasExited);
                phase = "recovery-after-tray-crash"; int crashedPid = tray.Id; tray.Kill(); tray.WaitForExit(); tray.Dispose(); tray = null;
                using (var host = Process.Start(new ProcessStartInfo(source, "--recovery-host --home " + Files.Quote(home)) { UseShellExecute = false })) {
                    Wait(() => { try { return Healthy(home, "0.0.1") && Json.Int(Json.Read(Path.Combine(home, "status", Product.StatusName)), "pid", 0) != crashedPid; } catch { return false; } }, 20000);
                    tray = Process.GetProcessById(Json.Int(Json.Read(Path.Combine(home, "status", Product.StatusName)), "pid", 0));
                    check("recovery-restarts-crashed-tray", !tray.HasExited && !host.HasExited);
                    Stop(home, target); if (!tray.WaitForExit(10000) || !host.WaitForExit(10000)) throw new IOException();
                    tray.Dispose(); tray = null;
                }
                }
                if (tray != null) { Stop(home, target); tray.WaitForExit(10000); tray.Dispose(); }
                tray = Start(target, home); Wait(() => Healthy(home, "0.0.1"), 20000);
                string configHash = Files.Hash(Path.Combine(home, "config.json"));
                phase = "graceful-stop"; Stop(home, target); check("old-process-exited", tray.WaitForExit(10000)); tray.Dispose(); tray = null;
                phase = "install-over"; UpgradeInstaller.Apply(home, source, newZip, Program.Version, false, f => External.SelfTest(f, home, CancellationToken.None));
                var e = new UpdateEngine(home, Program.Version);
                check("current-and-previous", e.Current == "0.0.2" && e.Previous == "0.0.1" && e.Pending);
                check("copy-to-install-path", Files.Hash(source) == Files.Hash(target));
                check("config-byte-preservation", Files.Hash(Path.Combine(home, "config.json")) == configHash);
                foreach (string directory in new[] { "state", "secrets", "logs" }) check("preserve-" + directory, File.ReadAllText(Path.Combine(home, directory, "preserve.txt")) == "preserve\r\n");
                phase = "updated-tray"; tray = Start(target, home); Wait(() => Healthy(home, "0.0.2") && !e.Pending, 20000);
                check("updated-tray-accepted", !File.Exists(Path.Combine(e.Root, "exe-upgrade.json")));
                Stop(home, target); check("updated-process-exited", tray.WaitForExit(10000)); tray.Dispose(); tray = null;
                phase = "failed-selftest"; bool rejected = false;
                try { UpgradeInstaller.Apply(home, source, Fixture(work, "0.0.4", true), Program.Version, false, f => false); } catch { rejected = true; }
                check("failed-selftest-keeps-installation", rejected && e.Current == "0.0.2" && Files.Hash(target) == Files.Hash(source));
                phase = "install-unhealthy"; UpgradeInstaller.Apply(home, source, badZip, Program.Version, false, f => External.SelfTest(f, home, CancellationToken.None));
                tray = Start(target, home); var watch = Stopwatch.StartNew();
                phase = "real-120-second-rollback"; Wait(() => e.Current == "0.0.2" && !e.Pending && !File.Exists(Path.Combine(e.Root, "exe-upgrade.json")), 150000);
                check("real-health-deadline", watch.Elapsed.TotalSeconds >= 118);
                check("unhealthy-version-rejected", e.IsBad("0.0.3"));
                check("neighbor-product-untouched", File.ReadAllText(neighborExe) == "neighbor-image" && Files.ReadLine(neighborBundle) == "neighbor-version");
                phase = "restored-tray"; Wait(() => Healthy(home, "0.0.2"), 20000);
                check("rollback-restarts-tray", Healthy(home, "0.0.2"));
                check("rollback-preserves-config-state", Files.Hash(Path.Combine(home, "config.json")) == configHash && File.ReadAllText(Path.Combine(home, "state", "preserve.txt")) == "preserve\r\n");
                Json.Write(Path.Combine(root, (Product.IsVpn ? "selftest-upgrade-vpn-result.json" : "selftest-upgrade-result.json")), new { ok = true, tests = checks.ToArray(), count = checks.Count, home }); return 0;
            } catch {
                Json.Write(Path.Combine(root, (Product.IsVpn ? "selftest-upgrade-vpn-result.json" : "selftest-upgrade-result.json")), new { ok = false, failed = phase, tests = checks.ToArray(), count = checks.Count, home }); return 1;
            } finally {
                try { Stop(home, Path.Combine(home, Product.ExeName)); } catch { }
                if (tray != null) { try { if (!tray.WaitForExit(10000)) { using (var kill = Process.Start(new ProcessStartInfo("taskkill.exe", "/PID " + tray.Id + " /T /F") { UseShellExecute = false, CreateNoWindow = true })) kill.WaitForExit(10000); } } catch { } tray.Dispose(); }
            }
        }
        static Process Start(string exe, string home)
        { return Process.Start(new ProcessStartInfo(exe, "--tray --home " + Files.Quote(home)) { UseShellExecute = false }); }
        static bool Healthy(string home, string version)
        {
            try { var s = Json.Read(Path.Combine(home, "status", Product.StatusName)); return Json.Str(s, "bundleVersion") == version && Json.Bool(s, "ok") && Json.Bool(s, "running"); } catch { return false; }
        }
        static void Stop(string home, string target)
        {
            string name = Program.InstanceName(home, WindowsIdentity.GetCurrent().User);
            using (var mutex = new Mutex(false, "Global\\" + name)) {
                bool owned; try { owned = mutex.WaitOne(0); } catch (AbandonedMutexException) { owned = true; }
                if (!owned) Program.StopInstalled(name, target, home, mutex, new Journal(home));
                mutex.ReleaseMutex();
            }
        }
        static void Wait(Func<bool> condition, int milliseconds)
        { var watch = Stopwatch.StartNew(); while (watch.ElapsedMilliseconds < milliseconds) { if (condition()) return; Thread.Sleep(200); } throw new TimeoutException(); }
        static string Fixture(string work, string version, bool healthy)
        {
            string path = Path.Combine(work, version + ".zip");
            using (var zip = ZipFile.Open(path, ZipArchiveMode.Create)) {
                var files = new Dictionary<string, string> {
                    { "bundle-version.txt", version + "\r\n" },
                    { "selftest.ps1", "param([Alias('Home')][string]$LauncherHome)\r\nif($PSVersionTable.PSVersion.Major -ne 5){exit 1}; exit 0\r\n" },
                    { "components.json", Json.Encode(new[] { new { name = "fixture", title = "Fixture", exe = "powershell.exe", args = new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "{bundle}\\fixture.ps1", "-Home", "{home}" }, restart = "always", enabledByDefault = true, critical = true, healthMaxAgeSec = 5 } }) },
                    { "fixture.ps1", "param([Alias('Home')][string]$LauncherHome)\r\nwhile($true){[IO.File]::WriteAllText((Join-Path $LauncherHome 'status/fixture.json'),'" + (healthy ? "{\"ok\":true,\"summary\":\"synthetic heartbeat\"}" : "{\"ok\":false,\"summary\":\"synthetic unhealthy\"}") + "'); Start-Sleep -Milliseconds 500}\r\n" }
                };
                foreach (var pair in files) using (var writer = new StreamWriter(zip.CreateEntry(pair.Key).Open(), new System.Text.UTF8Encoding(true))) writer.Write(pair.Value);
            }
            return path;
        }
    }
}
