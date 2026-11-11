using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Threading;

namespace RemoteAgents.Launcher
{
    internal static class UpdateSelfTests
    {
        static string currentCase = "initialization";
        static readonly List<string> passed = new List<string>();
        static void Check(string name, bool value) { currentCase = name; if (!value) throw new InvalidOperationException("assert"); passed.Add(name); }
        static void Reject(string name, Action action) { currentCase = name; bool rejected = false; try { action(); } catch { rejected = true; } Check(name, rejected); }
        static Manifest Archive(string root, string version, Dictionary<string, string> extra = null)
        {
            var path = Path.Combine(root, version + ".zip");
            using (var zip = ZipFile.Open(path, ZipArchiveMode.Create)) {
                var entries = new Dictionary<string, string> {
                    { "components.json", "[{\"name\":\"test\",\"exe\":\"unused.exe\",\"restart\":\"always\",\"critical\":true,\"enabledByDefault\":true}]\r\n" },
                    { "selftest.ps1", "exit 0\r\n" }, { "bundle-version.txt", version + "\r\n" }
                };
                if (extra != null) foreach (var pair in extra) entries[pair.Key] = pair.Value;
                foreach (var entry in entries) using (var writer = new StreamWriter(zip.CreateEntry(entry.Key).Open(), Files.Utf8)) writer.Write(entry.Value);
            }
            return Manifest.Parse(Json.Encode(new { version, file = version + ".zip", sha256 = Files.Hash(path), size = new FileInfo(path).Length, minLauncher = "1.0.0" }) + "\r\n");
        }
        static string Stage(UpdateEngine engine, Manifest manifest, string input, bool test = true)
        { return engine.Prepare(manifest, dest => File.Copy(Path.Combine(input, manifest.FileName), dest, true), f => test, (d, f) => { }, CancellationToken.None); }
        public static int Run(string target, Journal journal = null)
        {
            Directory.CreateDirectory(target); string work = Path.Combine(target, "run-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(work);
            var resultPath = Path.Combine(target, "selftest-result.json"); passed.Clear();
            try {
                var now = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc); string home = Path.Combine(work, "home");
                var e = new UpdateEngine(home, "1.0.0.0", () => now);
                var one = Archive(work, "1.0.0"); Check("initial-stage", Stage(e, one, work) == "1.0.0"); e.Activate(one.Version);
                Check("initial-activate", e.Current == "1.0.0" && !e.Pending);
                Files.Atomic(Path.Combine(e.Root, "current.txt"), "1.0.0\r\n"); Check("current-crlf", e.Current == "1.0.0");
                Check("framework-array-containers", Json.Array(new System.Collections.ArrayList { "one", "two" }).Length == 2);
                Check("numeric-version", Files.Compare("1.10.0", "1.9.9") > 0 && Files.Compare("1.0.0", "1.0.0.0") == 0);
                Check("date-version", Files.Compare("20261109.190001-ab12", "20261109.190000-ff00") > 0);
                var two = Archive(work, "2.0.0"); long original = two.Size; two.Size++;
                Reject("reject-size", () => Stage(e, two, work)); two.Size = original;
                string hash = two.Sha256; two.Sha256 = new string('0', 64); Reject("reject-hash", () => Stage(e, two, work)); two.Sha256 = hash;
                Check("failed-stage-keeps-current", e.Current == one.Version && !Directory.Exists(e.Folder(two.Version)));
                var minimum = Archive(work, "9.0.0"); minimum.Minimum = "2.0.0"; Check("minimum-launcher", !e.Eligible(minimum));
                var fail = Archive(work, "1.5.0"); Reject("failed-selftest", () => Stage(e, fail, work, false)); Check("failed-selftest-is-bad", e.IsBad(fail.Version) && !e.Eligible(fail));
                Check("prepare-next", Stage(e, two, work) == two.Version); e.Activate(two.Version);
                Check("pending-written", e.Pending && e.Current == two.Version && e.Previous == one.Version);
                now = now.AddSeconds(119); Check("grace-window", e.Observe(false) == "" && e.Current == two.Version);
                now = now.AddSeconds(1); e = new UpdateEngine(home, "1.0.0.0", () => now); e.Recover();
                Check("restart-retains-deadline", e.Observe(false) == "rollback" && e.Current == one.Version && !e.Pending);
                Check("bad-not-reinstalled", e.IsBad(two.Version) && Stage(e, two, work) == null);
                var three = Archive(work, "3.0.0"); Stage(e, three, work); e.Activate(three.Version);
                Check("health-accepts", e.Observe(true) == "accepted" && e.Current == three.Version && !e.Pending);
                Check("accepted-persists", new UpdateEngine(home, "1.0.0").Current == three.Version);
                e.Rollback(); Check("manual-rollback", e.Current == one.Version && e.IsBad(three.Version));
                Json.Write(Path.Combine(e.Root, "pending.json"), new { version = "3.0.0", previous = one.Version, startedUtc = now.ToString("o") });
                e.Recover(); Check("interrupted-before-switch", !e.Pending && e.Current == one.Version);
                for (int n = 4; n <= 8; n++) { var m = Archive(work, n + ".0.0"); Stage(e, m, work); e.Activate(m.Version); e.Observe(true); }
                Check("at-most-three-versions", Directory.GetDirectories(e.Root).Length <= 3 && Directory.Exists(e.Folder(e.Current)) && Directory.Exists(e.Folder(e.Previous)));
                var late = Archive(work, "8.5.0"); Stage(e, late, work); e.Activate(late.Version); now = now.AddSeconds(121);
                Check("late-health-does-not-accept", e.Observe(true) == "rollback" && e.Current == "8.0.0");
                var caseZip = Archive(work, "8.6.0", new Dictionary<string, string> { { "Components.json", "[]" } }); Reject("zip-case-duplicate", () => Stage(e, caseZip, work));
                var deviceZip = Archive(work, "8.7.0", new Dictionary<string, string> { { "bin/NUL.exe", "bad" } }); Reject("zip-windows-device", () => Stage(e, deviceZip, work));
                var launcherZip = Archive(work, "8.8.0"); launcherZip.LauncherVersion = "1.1.0.0"; launcherZip.LauncherHash = new string('0', 64); Reject("missing-launcher-payload", () => Stage(e, launcherZip, work));
                var slip = Archive(work, "10.0.0", new Dictionary<string, string> { { "../escaped.txt", "bad" } }); Reject("zip-slip", () => Stage(e, slip, work));
                Check("no-escaped-file", !File.Exists(Path.Combine(e.Root, "escaped.txt")));
                Reject("absolute-path", () => Files.Under(home, "C:\\outside")); Reject("version-path", () => Files.SafeVersion("../x"));
                var canceled = new CancellationTokenSource(); canceled.Cancel(); var cancel = Archive(work, "11.0.0");
                Reject("canceled-stage", () => e.Prepare(cancel, p => { throw new Exception(); }, f => true, (d, f) => { }, canceled.Token));
                Check("cancellation-keeps-current", e.Current == "8.0.0");
                string binary = Path.Combine(work, "binary"); File.WriteAllText(binary, "test binary\r\n", Files.Utf8); string bh = Files.Hash(binary);
                Directory.CreateDirectory(Path.Combine(home, "cache")); File.Copy(binary, Path.Combine(home, "cache", bh));
                var def = new BundleDefinition { Binaries = new[] { new Dictionary<string, object> { { "url", "https://example.invalid/unused" }, { "sha256", bh }, { "path", "nested/tool.exe" } } } };
                string binFolder = Path.Combine(work, "installed"); UpdateEngine.InstallBinaries(def, binFolder, home, CancellationToken.None);
                Check("verified-binary-cache", Files.Hash(Path.Combine(binFolder, "bin", "nested", "tool.exe")) == bh);
                def.Binaries[0]["path"] = "../escape.exe"; Reject("binary-path-escape", () => UpdateEngine.InstallBinaries(def, binFolder, home, CancellationToken.None));
                var cfg = Configuration.ForUpdate("{\r\n\"args\":[\"-F\",\"C:\\\\cfg\",\"-i\",\"C:\\\\key\",\"-p\",\"2200\",\"-o\",\"UserKnownHostsFile=C:\\\\hosts\",\"user@example.invalid\"],\"viaLocalPort\":2222}");
                var ssh = SshSource.Load(cfg, home);
                Check("local-ssh-target", ssh.Args.Last() == "user@127.0.0.1" && ssh.Args.Contains("HostKeyAlias=example.invalid") && ssh.Args.Contains("2222") && !ssh.Args.Contains("2200") && ssh.Args.Contains("UserKnownHostsFile=C:\\hosts"));
                string routedHome = Path.Combine(work, "routed-profile"), routedFolder = Path.Combine(routedHome, "ssh-profiles", "test", "project-connections", "test");
                Directory.CreateDirectory(routedFolder); string routedConfig = Path.Combine(routedHome, "ssh-config");
                File.WriteAllText(routedConfig, "Host example.invalid\r\n    Port 22\r\n", Files.Utf8);
                Json.Write(Path.Combine(routedFolder, "ssh-transport.json"), new { sshExecutable = "ssh.exe", configPath = routedConfig, serverAddress = "example.invalid", arguments = new[] { "-F", routedConfig, "-p", "22", "user@example.invalid" } });
                var routedSsh = SshSource.Load(new Configuration(routedHome), routedHome);
                Check("update-uses-home-profile-route", routedSsh.Args.Last() == "user@example.invalid" && routedSsh.Args.Contains("22"));
                Check("remote-home-quote", SshSource.RemotePath("~/.local/share/folder name", "manifest.json") == "\"$HOME\"/'.local/share/folder name/manifest.json'");
                Reject("reject-remote-command-in-args", () => SshSource.Load(Configuration.ForUpdate("{\"args\":[\"user@example.invalid\",\"echo secret\"]}"), home));
                Check("native-argument-quote", Files.Quote("a b") == "\"a b\"" && Files.Quote("x\"y") == "\"x\\\"y\"" && Files.Quote("C:\\dir\\") == "\"C:\\dir\\\\\"");
                var realConfig = new Configuration(Path.Combine(work, "configuration"));
                realConfig.Data["transport"] = new Dictionary<string, object> { { "kept", true } }; realConfig.Save();
                var component = Component.Read(new Dictionary<string, object> { { "name", "test" }, { "exe", "unused.exe" }, { "enabledByDefault", true } });
                realConfig.SetEnabled(component, false); var reloaded = new Configuration(Path.Combine(work, "configuration"));
                Check("component-config-preserves-transport", !reloaded.Enabled(component) && Json.Bool(Json.Map(Json.Get(reloaded.Data, "transport")), "kept"));
                // A second writer (transport/notepad) must survive a subsequent tray toggle.
                var concurrent = Json.Read(realConfig.PathName); concurrent["newNode"] = "kept"; Json.Write(realConfig.PathName, concurrent);
                realConfig.SetEnabled(component, true);
                Check("toggle-preserves-concurrent-config", Json.Str(Json.Read(realConfig.PathName), "newNode") == "kept");
                string unchangedHash = Files.Hash(realConfig.PathName); new Configuration(Path.Combine(work, "configuration"));
                Check("config-read-does-not-rewrite", Files.Hash(realConfig.PathName) == unchangedHash);
                Check("manual-ssh-default-off", !Json.Bool(reloaded.Update, "enabled"));
                var vpnComponent = Component.Read(Json.Parse("{\"name\":\"vpn\",\"exe\":\"powershell.exe\",\"commandManaged\":true,\"stopFile\":\"state/vpn.stop\"}"));
                Check("command-managed-defaults", vpnComponent.CommandManaged && !vpnComponent.Default && !vpnComponent.Critical && !vpnComponent.Elevated && vpnComponent.StopFile == "state/vpn.stop");
                var transportComponent=Component.Read(Json.Parse("{\"name\":\"transport\",\"exe\":\"unused\",\"enabledByDefault\":true,\"requiresConfig\":[\"transport.profilePath\",\"transport.channelPath\"]}"));
                var fresh=Configuration.ForUpdate("{}");
                Check("component-before-server-waits", !fresh.Wanted(transportComponent));
                fresh.Data["transport"]=Json.Parse("{\"profilePath\":\"profile\"}");
                Check("component-after-server-waits", !fresh.Wanted(transportComponent));
                var freshTransport=Json.Map(Json.Get(fresh.Data,"transport"));freshTransport["channelPath"]="  ";
                Check("component-blank-channel-waits", !fresh.Wanted(transportComponent));
                freshTransport["channelPath"]="channel";
                Check("component-after-connection-starts", fresh.Wanted(transportComponent));
                fresh.Data["components"]=Json.Parse("{\"transport\":{\"enabled\":false}}");
                Check("component-disabled-ready-stays-off", !fresh.Wanted(transportComponent));
                var explicitComponent=Component.Read(Json.Parse("{\"name\":\"disk\",\"exe\":\"unused\",\"enabledByDefault\":true,\"requiresConfig\":[\"components.disk.enabled\"]}"));
                Check("component-default-cannot-skip-setup", !fresh.Wanted(explicitComponent));
                fresh.Data["components"]=Json.Parse("{\"disk\":{\"enabled\":true}}");
                Check("component-explicit-step-starts", fresh.Wanted(explicitComponent));
                Check("legacy-component-without-contract", fresh.Wanted(Component.Read(Json.Parse("{\"name\":\"legacy\",\"exe\":\"unused\",\"enabledByDefault\":true}"))));
                var freshStatus=Json.Map(Json.Parse("{\"ok\":false,\"error\":\"transport failed\"}"));
                var empty=new Dictionary<string,object>();
                string neutral=WizardStep.ConnectionResult(empty,freshStatus,false,"");
                Check("connection-before-step-neutral", neutral.StartsWith("Ещё не настроено") && !neutral.Contains("Ошибка") && !neutral.Contains("transport failed"));
                var serverOnly=Json.Map(Json.Parse("{\"transport\":{\"profilePath\":\"profile\"}}"));
                Check("connection-profile-alone-neutral", WizardStep.ConnectionResult(serverOnly,freshStatus,false,"")==neutral);
                Check("connection-attempt-failure-retained", WizardStep.ConnectionResult(serverOnly,freshStatus,false,"Ошибка: проверка не прошла")=="Ошибка: проверка не прошла");
                Check("configured-connection-fresh-error", WizardStep.ConnectionResult(fresh.Data,freshStatus,false,"")=="Ошибка связи: transport failed");
                Check("configured-connection-no-status-neutral", !WizardStep.ConnectionResult(fresh.Data,empty,false,"").StartsWith("Ошибка"));
                Check("connection-stale-observation-cleared", !WizardStep.ConnectionResult(fresh.Data,empty,false,"Ошибка связи: old status").StartsWith("Ошибка"));
                Check("connection-real-failure-survives-stale-status", WizardStep.ConnectionResult(fresh.Data,empty,false,"Ошибка: step failed")=="Ошибка: step failed");
                Check("configured-connection-healthy", WizardStep.ConnectionResult(fresh.Data,empty,true,"").StartsWith("Работает через"));
                fresh.Data["wizard"]=Json.Parse("{\"pendingProfile\":\"new-server\"}");
                Check("connection-new-server-ignores-old-error", WizardStep.ConnectionResult(fresh.Data,freshStatus,false,"")==neutral);
                Check("same-release", UpgradeInstaller.Compare("1.1", "2.0", "1.1.0.0", "2.0") == 0);
                Check("newer-launcher", UpgradeInstaller.Compare("1.2", "2.0", "1.1", "2.0") > 0);
                Check("newer-bundle", UpgradeInstaller.Compare("1.1", "2.1", "1.1", "2.0") > 0);
                Check("mixed-release-needs-downgrade-consent", UpgradeInstaller.Compare("1.2", "1.9", "1.1", "2.0") < 0);
                string upgradeHome = Path.Combine(work, "upgrade-home"), image = Path.Combine(work, "downloaded.exe");
                string neighborImage = Path.Combine(upgradeHome, Product.IsVpn ? "RemoteAgents.exe" : "RemoteVPN.exe");
                string neighborPointer = Path.Combine(upgradeHome, Product.IsVpn ? "bundle" : "vpn-bundle", "current.txt");
                Files.Atomic(neighborImage, "neighbor"); Files.Atomic(neighborPointer, "neighbor-current");
                File.WriteAllText(image, "old-image");
                var u1 = Archive(work, "20.0.0"); var u2 = Archive(work, "21.0.0");
                UpgradeInstaller.Apply(upgradeHome, image, Path.Combine(work, u1.FileName), "1.1.0", false, f => true);
                string installedImage = Path.Combine(upgradeHome, Product.ExeName);
                Check("upgrade-first-install", File.ReadAllText(installedImage) == "old-image");
                string retryHome=Path.Combine(work,"first-install-retry");
                Reject("first-install-preparation-fails",()=>UpgradeInstaller.Apply(retryHome,image,Path.Combine(work,u1.FileName),"1.1.0",false,f=>false));
                Check("failed-first-install-has-no-image", !File.Exists(Path.Combine(retryHome,Product.ExeName)));
                UpgradeInstaller.Apply(retryHome,image,Path.Combine(work,u1.FileName),"1.1.0",false,f=>true);
                Check("first-install-retry-succeeds",new UpdateEngine(retryHome,"1.1.0").Current==u1.Version && File.Exists(Path.Combine(retryHome,Product.ExeName)));
                string cancelledHome=Path.Combine(work,"cancelled-first-install");
                using(var firstCancel=new CancellationTokenSource()) {
                    Reject("first-install-preparation-cancelled",()=>UpgradeInstaller.Apply(cancelledHome,image,Path.Combine(work,u1.FileName),"1.1.0",false,f=>{firstCancel.Cancel();return true;},firstCancel.Token));
                    Check("cancelled-first-install-has-no-image",new UpdateEngine(cancelledHome,"1.1.0").Current.Length==0 && !File.Exists(Path.Combine(cancelledHome,Product.ExeName)));
                }
                foreach (string dir in new[] { "state", "secrets", "logs" }) Files.Atomic(Path.Combine(upgradeHome, dir, "keep"), "keep\r\n");
                Files.Atomic(Path.Combine(upgradeHome, "config.json"), "{\r\n\"custom\":true}\r\n");
                string configHash = Files.Hash(Path.Combine(upgradeHome, "config.json"));
                File.WriteAllText(image, "new-image");
                UpgradeInstaller.Apply(upgradeHome, image, Path.Combine(work, u2.FileName), "1.1.0", false, f => true);
                var ue = new UpdateEngine(upgradeHome, "1.1.0");
                Check("upgrade-over-and-previous", ue.Current == u2.Version && ue.Previous == u1.Version && ue.Pending && File.ReadAllText(installedImage) == "new-image");
                Check("upgrade-preserves-user-data", Files.Hash(Path.Combine(upgradeHome, "config.json")) == configHash && new[] { "state", "secrets", "logs" }.All(dir => File.ReadAllText(Path.Combine(upgradeHome, dir, "keep")) == "keep\r\n"));
                Check("upgrade-119-second-grace", UpgradeInstaller.ObserveImage(upgradeHome, ue, false, "", DateTime.UtcNow.AddSeconds(118)) == "" && ue.Pending);
                Check("upgrade-restores-image-and-bundle", UpgradeInstaller.ObserveImage(upgradeHome, ue, false, "", DateTime.UtcNow.AddSeconds(121)) == "rollback" && ue.Current == u1.Version && File.ReadAllText(installedImage) == "old-image");
                Check("product-upgrade-and-rollback-preserve-neighbor", File.ReadAllText(neighborImage) == "neighbor" && Files.ReadLine(neighborPointer) == "neighbor-current");
                Check("product-bundle-storage", ue.Root == Path.Combine(upgradeHome, Product.IsVpn ? "vpn-bundle" : "bundle"));
                var u3 = Archive(work, "22.0.0");
                Reject("upgrade-failed-selftest", () => UpgradeInstaller.Apply(upgradeHome, image, Path.Combine(work, u3.FileName), "1.1.0", false, f => false));
                Check("upgrade-failed-selftest-keeps-image", ue.Current == u1.Version && File.ReadAllText(installedImage) == "old-image");
                // Unfinished first setup: a version marked bad earlier is reinstalled and accepted at once, without a rollback deadline.
                UpgradeInstaller.Apply(upgradeHome, image, Path.Combine(work, u3.FileName), "1.1.0", false, f => true, default(CancellationToken), accept: true);
                Check("first-setup-accepts-bad-version-without-deadline", ue.Current == u3.Version && ue.Previous == u1.Version && !ue.Pending && !File.Exists(Path.Combine(ue.Root, "exe-upgrade.json")) && File.ReadAllText(installedImage) == "new-image");
                Check("first-setup-accepted-no-rollback", ue.Observe(false) == "" && UpgradeInstaller.ObserveImage(upgradeHome, ue, false, "", DateTime.UtcNow.AddSeconds(121)) == "" && ue.Current == u3.Version);
                var u4 = Archive(work, "23.0.0");
                UpgradeInstaller.Apply(upgradeHome, image, Path.Combine(work, u4.FileName), "1.1.0", false, f => true);
                string accepted = ue.Observe(true);
                Check("upgrade-health-accepts-image", accepted == "accepted" && UpgradeInstaller.ObserveImage(upgradeHome, ue, true, accepted) == "accepted");
                UpgradeInstaller.Apply(upgradeHome, image, Path.Combine(work, u1.FileName), "1.1.0", true, f => true);
                Check("explicit-downgrade-activates", ue.Current == u1.Version && ue.Previous == u4.Version);
                accepted = ue.Observe(true); UpgradeInstaller.ObserveImage(upgradeHome, ue, true, accepted);
                File.WriteAllText(image, "launcher-only");
                UpgradeInstaller.Apply(upgradeHome, image, Path.Combine(work, u1.FileName), "1.2.0", false, f => true);
                Check("launcher-only-no-bundle-switch", !ue.Pending && ue.Current == u1.Version && File.ReadAllText(installedImage) == "launcher-only");
                Check("launcher-only-rollback", UpgradeInstaller.ObserveImage(upgradeHome, ue, false, "", DateTime.UtcNow.AddSeconds(121)) == "rollback" && File.ReadAllText(installedImage) == "new-image");
                string statusFile = Path.Combine(upgradeHome, "status", "transport.json");
                Check("absent-status-is-no-data", StatusView.Title(StatusView.Read(upgradeHome, "transport")) == "нет данных");
                Json.Write(statusFile, new { active = "direct", title = "Прямой", mode = "auto", kbps = (double?)null, metered = (bool?)null, updatedAt = DateTime.UtcNow.ToString("o"), candidates = new[] { new { tag = "direct", title = "Прямой", state = "ok", kbps = 25 } } });
                var view = StatusView.Read(upgradeHome, "transport");
                Check("fresh-transport-and-null-speed", StatusView.Title(view) == "Прямой" && StatusView.Speed(view) == "скорость: нет данных" && StatusView.Metered(view) == "нет данных" && StatusView.Candidates(view).Length == 1);
                view["title"] = new string('x', 100); view["kbps"] = 128;
                Check("tooltip-preserves-speed", StatusView.Tooltip(view).Length <= 63 && StatusView.Tooltip(view).EndsWith("128 КБ/с"));
                File.SetLastWriteTimeUtc(statusFile, DateTime.UtcNow.AddSeconds(-301));
                Check("stale-file-is-no-data", StatusView.Read(upgradeHome, "transport").Count == 0);
                Json.Write(statusFile, new { updatedAt = DateTime.UtcNow.AddMinutes(-6).ToString("o"), active = "old" });
                Check("stale-payload-is-no-data", StatusView.Read(upgradeHome, "transport").Count == 0);
                File.WriteAllText(statusFile, "{bad\r\n"); Check("malformed-status-is-no-data", StatusView.Read(upgradeHome, "transport").Count == 0);
                var corrupt = new UpdateEngine(Path.Combine(work, "corrupt-home"), "1.0.0.0", () => now);
                Stage(corrupt, one, work); corrupt.Activate(one.Version); Stage(corrupt, two, work); corrupt.Activate(two.Version);
                File.WriteAllText(Path.Combine(corrupt.Folder(two.Version), "components.json"), "{bad\r\n");
                corrupt.Recover();
                Check("malformed-components-recover-before-startup", corrupt.Current == one.Version && !corrupt.Pending && corrupt.IsBad(two.Version));
                if (Environment.OSVersion.Platform == PlatformID.Win32NT) {
                    string capture = Path.Combine(work, "external-output.txt"), childPid = Path.Combine(work, "external-child.pid");
                    string ps = "$p=Start-Process -FilePath '" + Files.Executable("powershell.exe").Replace("'", "''") + "' -ArgumentList '-NoProfile -NonInteractive -Command Start-Sleep -Seconds 120' -PassThru;[IO.File]::WriteAllText('" + childPid.Replace("'", "''") + "',[string]$p.Id);[Console]::Write('capture-ok');[Console]::Error.Write('discard-only')";
                    int code = External.Run("powershell.exe", new[] { "-NoProfile", "-NonInteractive", "-Command", ps }, work, capture, 15000, 1024, CancellationToken.None);
                    Check("native-job-captures-only-stdout", code == 0 && File.ReadAllText(capture) == "capture-ok");
                    int id = int.Parse(File.ReadAllText(childPid)); bool alive;
                    try { using (var child = System.Diagnostics.Process.GetProcessById(id)) alive = !child.WaitForExit(5000); } catch (ArgumentException) { alive = false; }
                    Check("native-job-kills-immediate-descendant", !alive);
                }
                Json.Write(resultPath, new { ok = true, product = Product.Name, tests = passed.ToArray(), count = passed.Count });
                if (journal != null) journal.Write("selftest.update.ok"); return 0;
            } catch {
                Json.Write(resultPath, new { ok = false, failed = currentCase, tests = passed.ToArray(), count = passed.Count });
                if (journal != null) journal.Write("selftest.update.failed"); return 1;
            } finally { try { Directory.Delete(work, true); } catch { } }
        }
    }
}
