using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Threading;

namespace RemoteAgents.Launcher
{
    // H4: local file transactions and manual events only; no Windows APIs, network or clock advancement.
    internal static class RollbackTests
    {
        static int checks;
        static void Check(bool ok, string message) { if (!ok) throw new Exception(message); checks++; }
        static void WithHome(Action<string> test)
        {
            string home = Path.Combine(Path.GetTempPath(), "ra-h4-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(home);
            try { test(home); } finally { Directory.Delete(home, true); }
        }
        static string Image { get { return Assembly.GetExecutingAssembly().Location; } }
        static string Target(string home) { return Path.Combine(home, Product.ExeName); }
        static string Backup(string home) { return Path.Combine(home, Product.Name + ".previous.exe"); }
        static UpdateEngine Engine(string home)
        { return new UpdateEngine(home, "1.0.0", cleanup: new UpdateEngine.CleanupOperations { Queue = _ => { } }); }
        static void Bundle(UpdateEngine engine, string version)
        {
            Directory.CreateDirectory(engine.Folder(version));
            Json.Write(Path.Combine(engine.Folder(version), "components.json"), new[] { new { name = "transport", exe = "unused", critical = true } });
        }
        static UpdateEngine Seed(string home)
        {
            var engine = Engine(home); Bundle(engine, "1.0.0"); engine.Activate("1.0.0");
            File.WriteAllText(Target(home), "image 1");
            Directory.CreateDirectory(Path.Combine(home, "logs")); File.WriteAllText(Path.Combine(home, "logs", "keep.log"), "history");
            Directory.CreateDirectory(Path.Combine(home, "secrets")); File.WriteAllText(Path.Combine(home, "secrets", "keep"), "test fixture");
            return engine;
        }
        static void Upgrade(string home, UpdateEngine engine, string version)
        {
            Bundle(engine, version); string source = Path.Combine(engine.Folder(version), Product.ExeName); File.Copy(Image, source);
            var manifest = new Manifest { Version = version, LauncherHash = Files.Hash(source), LauncherVersion = FileVersionInfo.GetVersionInfo(source).FileVersion };
            UpgradeInstaller.ActivatePrepared(home, engine, manifest);
            Check(engine.Pending && File.Exists(UpgradeInstaller.ReceiptPath(home)), "OTA keeps H2 receipt/pending");
        }
        static void Accept(string home, UpdateEngine engine)
        {
            UpgradeInstaller.NoteHealthAccepted(home);
            Check(engine.Observe(true) == "accepted", "manual health event accepts bundle");
            Check(UpgradeInstaller.ObserveImage(home, engine, true, "accepted") == "accepted", "manual health event accepts EXE");
        }
        static Dictionary<string, string> Snapshot(string home)
        { return Directory.GetFiles(home, "*", SearchOption.AllDirectories).ToDictionary(p => p.Substring(home.Length), Files.Hash); }
        static void RefuseUnchanged(string home, Action action, string reason)
        {
            var before = Snapshot(home); bool refused = false;
            try { action(); } catch (Exception ex) {
                if (!(ex is IOException) && !(ex is UnauthorizedAccessException) && !(ex is InvalidDataException) && !(ex is InvalidOperationException)) throw;
                Check(ex.Message.Length > 0, reason + ": readable reason"); refused = true;
            }
            Check(refused, reason + ": refused");
            var after = Snapshot(home);
            Check(before.Count == after.Count && before.All(p => after.ContainsKey(p.Key) && after[p.Key] == p.Value), reason + ": no file changed");
        }
        static void ActivationAndRetention(string home)
        {
            var engine = Seed(home);
            Check(!File.Exists(UpgradeInstaller.PreviousPath(home)), "first install has no previous descriptor");
            string oldHash = Files.Hash(Target(home)); Upgrade(home, engine, "2.0.0");
            var p = Json.Read(UpgradeInstaller.PreviousPath(home));
            Check(Json.Str(p, "ver") == "1.0.0" && Json.Str(p, "exeSha256") == oldHash, "activation records old version and EXE hash");
            Check(Json.Str(p, "bundleDir") == engine.Folder("1.0.0") && Json.Str(p, "helperBuild") == NetHelperInstall.HelperVersion, "activation records bundle and current HelperVersion");
            RefuseUnchanged(home, () => UpgradeInstaller.RollbackPrevious(home, engine, false), "H2 receipt still observed");
            Accept(home, engine);
            foreach (string version in new[] { "3.0.0", "4.0.0" }) { Upgrade(home, engine, version); Accept(home, engine); }
            p = Json.Read(UpgradeInstaller.PreviousPath(home));
            Check(Json.Str(p, "ver") == "3.0.0" && engine.Previous == "3.0.0", "descriptor rotates with existing Previous");
            Check(!Directory.Exists(engine.Folder("1.0.0")) && Directory.Exists(engine.Folder("2.0.0")) && Directory.Exists(engine.Folder("3.0.0")), "existing Cleanup keeps two historical bundles alongside current");
            Check(File.Exists(Target(home)) && File.Exists(Backup(home)) && Directory.GetFiles(home, "*.previous.exe").Length == 1, "two retained EXE images: current and previous");
        }
        static void SuccessfulRollback(string home, bool block)
        {
            var engine = Seed(home); Upgrade(home, engine, "2.0.0"); Accept(home, engine);
            Json.Write(Path.Combine(engine.Root, "update-state.json"), new { pending = true, queuedFailure = "old", failureReason = "old", target = "2.0.0", resumeVpn = true });
            Check(UpgradeInstaller.PreviousVersion(home, engine) == "1.0.0", "previous version is available");
            Check(UpgradeInstaller.RollbackPrevious(home, engine, block, "1.0.0") == "1.0.0", "rollback succeeds");
            Check(engine.Current == "1.0.0" && File.ReadAllText(Target(home)) == "image 1" && !engine.Pending, "EXE and bundle switch together without pending");
            Check(engine.IsBad("2.0.0") == block, "only checked option writes bad.txt");
            if (block) Check(!engine.Eligible(new Manifest { Version = "2.0.0", Minimum = "1.0.0" }), "auto update respects bad.txt");
            Check(!File.Exists(UpgradeInstaller.PreviousPath(home)) && !File.Exists(UpgradeInstaller.ManualRollbackPath(home)) && !File.Exists(UpgradeInstaller.ReceiptPath(home)), "manual transaction consumes descriptor and creates no H2 receipt");
            var state = Json.Read(Path.Combine(engine.Root, "update-state.json"));
            Check(!Json.Bool(state, "pending") && !state.ContainsKey("queuedFailure") && !state.ContainsKey("failureReason") && Json.Bool(state, "resumeVpn"), "old auto failure cleared, restart intent retained");
            var stable = Snapshot(home);
            UpgradeInstaller.RollbackObservedImage(home, engine, "UpdateFailed");
            Check(engine.Observe(false, true) == "" && UpdateObservation.Decide(false, true, true, true) == "", "late H2 events cannot roll manual rollback forward again");
            Check(Snapshot(home).All(p => stable[p.Key] == p.Value), "late H2 events do not change manual result");
            RefuseUnchanged(home, () => UpgradeInstaller.RollbackPrevious(home, engine, false), "no second rollback loop");
            Check(File.ReadAllText(Path.Combine(home, "logs", "keep.log")) == "history" && File.ReadAllText(Path.Combine(home, "secrets", "keep")) == "test fixture", "logs and user files survive");
        }
        static void Refusals(string home)
        {
            foreach (string mode in new[] { "no-record", "missing-exe", "hash", "missing-bundle", "pending", "receipt", "recovery", "changed-version", "outside-bundle" }) {
                string sub = Path.Combine(home, mode); var engine = Seed(sub); Upgrade(sub, engine, "2.0.0"); Accept(sub, engine);
                if (mode == "no-record") File.Delete(UpgradeInstaller.PreviousPath(sub));
                if (mode == "missing-exe") File.Delete(Backup(sub));
                if (mode == "hash") File.WriteAllText(Backup(sub), "tampered");
                if (mode == "missing-bundle") Directory.Delete(engine.Folder("1.0.0"), true);
                if (mode == "pending") Json.Write(Path.Combine(engine.Root, "pending.json"), new { version = "2.0.0", previous = "1.0.0" });
                if (mode == "receipt") File.WriteAllText(UpgradeInstaller.ReceiptPath(sub), "{broken");
                if (mode == "recovery") File.WriteAllText(UpgradeInstaller.RecoveryBlockPath(sub), "invalid-receipt\n");
                if (mode == "outside-bundle") { var p = Json.Read(UpgradeInstaller.PreviousPath(sub)); p["bundleDir"] = home; Json.Write(UpgradeInstaller.PreviousPath(sub), p); }
                RefuseUnchanged(sub, () => UpgradeInstaller.RollbackPrevious(sub, engine, true, mode == "changed-version" ? "0.9.0" : null), mode);
            }
        }
        static void BusyMutex(string home, bool installerGate)
        {
            var engine = Seed(home); Upgrade(home, engine, "2.0.0"); Accept(home, engine);
            using (var held = new ManualResetEvent(false)) using (var release = new ManualResetEvent(false)) {
                string installName = "ra-h4-install-" + Guid.NewGuid().ToString("N");
                var thread = new Thread(() => {
                    if (installerGate) using (var mutex = new Mutex(false, installName)) {
                        mutex.WaitOne(); held.Set(); release.WaitOne(); mutex.ReleaseMutex();
                    } else using (UpgradeInstaller.LockReceipt(home)) { held.Set(); release.WaitOne(); }
                });
                thread.Start(); held.WaitOne();
                try { RefuseUnchanged(home, () => UpgradeInstaller.RollbackPrevious(home, engine, true, installerMutexName: installerGate ? installName : null), installerGate ? "another installer" : "another receipt-mutex owner"); }
                finally { release.Set(); thread.Join(); }
            }
        }
        static void WriteZip(string path, string version)
        {
            using (var archive = ZipFile.Open(path, ZipArchiveMode.Create)) {
                using (var w = new StreamWriter(archive.CreateEntry("bundle-version.txt").Open())) w.Write(version + "\n");
                using (var w = new StreamWriter(archive.CreateEntry("components.json").Open()))
                    w.Write(Json.Encode(new[] { new { name = "transport", exe = "unused", critical = true } }));
            }
        }
        static int Child(string home, string mode, string extra, bool installed = false)
        {
            // Execute the actual installed managed image after a crash, using the fixture's runtime config.
            var start = new ProcessStartInfo("dotnet") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
            start.ArgumentList.Add("exec"); start.ArgumentList.Add("--runtimeconfig");
            start.ArgumentList.Add(Path.ChangeExtension(Image, ".runtimeconfig.json"));
            start.ArgumentList.Add(installed ? Target(home) : Image);
            start.ArgumentList.Add(mode); start.ArgumentList.Add(home); start.ArgumentList.Add(extra);
            using (var process = Process.Start(start)) {
                var output = process.StandardOutput.ReadToEndAsync(); var error = process.StandardError.ReadToEndAsync();
                if (!process.WaitForExit(15000)) { process.Kill(true); throw new Exception("child startup fuse: " + mode); }
                string details = output.GetAwaiter().GetResult() + error.GetAwaiter().GetResult();
                Check(process.ExitCode == (mode == "--interrupt" ? 73 : 0), mode + " child failed: " + details);
                return process.ExitCode;
            }
        }
        static void ConsistentTargetState(string home, string hash, bool legacy = false)
        {
            var engine = Engine(home);
            Check(File.Exists(Target(home)) && Files.Hash(Target(home)) == hash, "installed target remains launchable with verified bytes");
            Check(engine.Current == "1.0.0" && engine.Previous == "" && !engine.Pending && engine.IsBad("2.0.0"), "all version state agrees with restored EXE");
            var state = Json.Read(Path.Combine(engine.Root, "update-state.json"));
            Check(!Json.Bool(state, "pending") && !state.ContainsKey("queuedFailure") && !state.ContainsKey("failureReason") && !state.ContainsKey("target") && Json.Bool(state, "resumeVpn"), "target update-state is complete");
            Check(!File.Exists(UpgradeInstaller.PreviousPath(home)) && !File.Exists(UpgradeInstaller.ReceiptPath(home)), "descriptor consumed without H2 receipt");
            if (!legacy) Check(!File.Exists(UpgradeInstaller.ManualRollbackPath(home)), "startup consumed transaction journal");
            BundleDefinition.Load(engine.Folder(engine.Current));
        }
        static int ChildMain(string[] args)
        {
            string mode = args[0], home = args[1], extra = args[2];
            if (mode == "--interrupt") {
                var p = Json.Read(UpgradeInstaller.PreviousPath(home)); string oldHash = Json.Str(p, "exeSha256"), fromHash = Files.Hash(Target(home));
                UpgradeInstaller.PreviousRollbackCheckpoint = step => {
                    Check(File.Exists(Target(home)), "main EXE exists at EVERY transaction boundary: " + step);
                    string actual = Files.Hash(Target(home));
                    Check(actual == oldHash || actual == fromHash, "main EXE hash at boundary: " + step);
                    if (step == "exe" || step == "before-journal-delete") ConsistentTargetState(home, oldHash, legacy: true);
                    if (step == extra) Environment.Exit(73); // Actual process termination: no finally/shared memory recovery.
                };
                UpgradeInstaller.RollbackPrevious(home, Engine(home), true);
                throw new Exception("missing interruption boundary " + extra);
            }
            if (mode == "--commit-failure") {
                string original = Files.Hash(Target(home));
                UpgradeInstaller.PreviousRollbackCheckpoint = step => {
                    if (step == "before-exe") File.Delete(Target(home) + ".rollback.tmp"); // Real source loss after successful preflight.
                };
                bool refused = false;
                try { UpgradeInstaller.RollbackPrevious(home, Engine(home), true); }
                catch (IOException ex) { Check(ex.Message.Contains("Атомарная замена EXE недоступна"), "final swap diagnostic"); refused = true; }
                Check(refused && Files.Hash(Target(home)) == original && File.Exists(UpgradeInstaller.ManualRollbackPath(home)), "final atomic failure retains original EXE and recovery journal");
                var failedEngine = Engine(home);
                Check(failedEngine.Current == "1.0.0" && failedEngine.Previous == "" && failedEngine.IsBad("2.0.0") && !failedEngine.Pending, "final failure preserves completed target state");
                return 0;
            }
            if (mode == "--legacy-start") {
                // Emulate an EXE predating H4: ordinary bundle/state reads, NO manual journal recovery.
                ConsistentTargetState(home, extra, legacy: true); return 0;
            }
            if (mode == "--start") {
                // Exactly the recovery entry used by Program before normal startup/StartLauncher.
                UpgradeInstaller.RecoverPreviousRollback(home);
                Engine(home).Recover(); ConsistentTargetState(home, extra);
                UpgradeInstaller.RecoverPreviousRollback(home); ConsistentTargetState(home, extra); return 0;
            }
            if (mode.StartsWith("--blocked-", StringComparison.Ordinal)) {
                bool refused = false;
                try {
                    var blockedEngine = Engine(home);
                    if (mode == "--blocked-start") UpgradeInstaller.RecoverPreviousRollback(home);
                    else if (mode == "--blocked-apply") UpgradeInstaller.Apply(home, Image, Path.Combine(home, "next.zip"), "1.0.0", false, _ => true);
                    else if (mode == "--blocked-ota") UpgradeInstaller.ActivatePrepared(home, blockedEngine, new Manifest { Version = "3.0.0" });
                    else blockedEngine.Activate("3.0.0");
                } catch (Exception ex) {
                    if (!(ex is IOException) && !(ex is UnauthorizedAccessException)) throw;
                    Check(ex.Message.Length > 0, "atomic recovery refusal has diagnostic"); refused = true;
                }
                Check(refused && File.Exists(Target(home)) && File.Exists(UpgradeInstaller.ManualRollbackPath(home)) &&
                    !File.Exists(UpgradeInstaller.ReceiptPath(home)) && !Engine(home).Pending, "blocked recovery never starts next transaction");
                return 0;
            }
            var engine = Engine(home);
            if (mode == "--apply") {
                UpgradeInstaller.Apply(home, Image, Path.Combine(home, "next.zip"), "1.0.0", false,
                    _ => { ConsistentTargetState(home, extra); return true; });
            } else if (mode == "--ota") {
                string source = Path.Combine(engine.Folder("3.0.0"), Product.ExeName);
                UpgradeInstaller.ActivatePrepared(home, engine, new Manifest { Version = "3.0.0", LauncherHash = Files.Hash(source),
                    LauncherVersion = FileVersionInfo.GetVersionInfo(source).FileVersion });
            } else if (mode == "--bundle") engine.Activate("3.0.0");
            else throw new Exception("unknown child mode " + mode);
            Check(engine.Current == "3.0.0" && engine.Previous == "1.0.0" && engine.Pending, "next activation uses recovered version as previous");
            Check(!File.Exists(UpgradeInstaller.ManualRollbackPath(home)) && Files.Hash(Backup(home)) == extra, "manual recovery precedes backup/H2 receipt creation");
            Check(File.Exists(UpgradeInstaller.ReceiptPath(home)) == (mode != "--bundle"), "next activation preserves H2 receipt contract");
            return 0;
        }
        static void RecoverInterrupted(string home)
        {
            string[] boundaries = { "preflight", "journal", "current", "previous", "bad", "update-state", "descriptor", "bundle", "before-exe", "exe", "before-journal-delete" };
            foreach (string boundary in boundaries) foreach (string mode in new[] { "--start", "--apply", "--ota", "--bundle" }) {
                string sub = Path.Combine(home, boundary + mode); var engine = Seed(sub);
                // Both images really execute; an appended marker gives the legacy fixture a distinct SHA256.
                File.Copy(Image, Target(sub), true); using (var f = new FileStream(Target(sub), FileMode.Append)) f.WriteByte(0);
                string oldHash = Files.Hash(Target(sub)); Upgrade(sub, engine, "2.0.0"); Accept(sub, engine);
                Json.Write(Path.Combine(engine.Root, "update-state.json"), new { pending = true, queuedFailure = "old", failureReason = "old", target = "2.0.0", resumeVpn = true });
                // Do not create a new bundle until after the interruption (Cleanup is allowed to retire history).
                Child(sub, "--interrupt", boundary);
                Check(File.Exists(Target(sub)), "main EXE exists after process termination: " + boundary);
                bool committed = boundary == "exe" || boundary == "before-journal-delete";
                Check(Files.Hash(Target(sub)) == (committed ? oldHash : Files.Hash(Image)), "real EXE hash at interrupted boundary: " + boundary);
                if (committed) {
                    var before = Snapshot(sub);
                    Child(sub, "--legacy-start", oldHash, installed: true);
                    Check(Snapshot(sub).All(p => before[p.Key] == p.Value), "pre-H4 startup needs no journal writes");
                    // Committed recovery must not depend on retaining the old backup image.
                    if (mode == "--start") File.Delete(Backup(sub));
                }
                if (boundary == "preflight") {
                    Check(!File.Exists(UpgradeInstaller.ManualRollbackPath(sub)) && engine.Current == "2.0.0", "preflight crash leaves old state intact");
                    // No transaction was started: explicitly retry the requested rollback in a fresh process.
                    Child(sub, "--interrupt", "journal");
                }
                if (mode == "--apply") WriteZip(Path.Combine(sub, "next.zip"), "3.0.0");
                if (mode == "--ota" || mode == "--bundle") {
                    Bundle(engine, "3.0.0"); File.Copy(Image, Path.Combine(engine.Folder("3.0.0"), Product.ExeName));
                }
                Child(sub, mode, oldHash, installed: true);
                if (mode == "--start") Child(sub, "--legacy-start", oldHash, installed: true);
            }
        }
        static void AtomicReplaceRefusal(string home)
        {
            var engine = Seed(home); Upgrade(home, engine, "2.0.0"); Accept(home, engine);
            // File.Replace itself fails creating its backup over a directory. No mocked replacement result.
            string denied = Target(home) + ".rollback-probe.bak"; Directory.CreateDirectory(denied);
            RefuseUnchanged(home, () => UpgradeInstaller.RollbackPrevious(home, engine, true), "real atomic File.Replace refusal before journal/state");
            Check(File.Exists(Target(home)) && !File.Exists(UpgradeInstaller.ManualRollbackPath(home)), "replace refusal keeps main EXE and starts no transaction");
            Directory.Delete(denied);
            UpgradeInstaller.RollbackPrevious(home, engine, true);
            Check(engine.Current == "1.0.0", "atomic replacement can be retried after fixing access");
        }
        static void RecoveryReplaceRefusal(string home)
        {
            var engine = Seed(home); File.Copy(Image, Target(home), true);
            using (var f = new FileStream(Target(home), FileMode.Append)) f.WriteByte(0);
            string hash = Files.Hash(Target(home)); Upgrade(home, engine, "2.0.0"); Accept(home, engine);
            Json.Write(Path.Combine(engine.Root, "update-state.json"), new { pending = true, queuedFailure = "old", failureReason = "old", target = "2.0.0", resumeVpn = true });
            Child(home, "--interrupt", "before-exe");
            string denied = Target(home) + ".rollback-probe.bak"; Directory.CreateDirectory(denied);
            WriteZip(Path.Combine(home, "next.zip"), "3.0.0"); Bundle(engine, "3.0.0");
            // Crash scratch files are disposable, not durable recovery inputs. Start without one:
            // each failed retry must clean its own scratch and preserve EVERY existing file below.
            File.Delete(Target(home) + ".rollback.tmp");
            var before = Snapshot(home);
            foreach (string mode in new[] { "--blocked-start", "--blocked-apply", "--blocked-ota", "--blocked-bundle" }) {
                Child(home, mode, hash, installed: true);
                var after = Snapshot(home);
                Check(before.Count == after.Count && before.All(p => after.ContainsKey(p.Key) && after[p.Key] == p.Value), "failed recovery preserves files before " + mode);
            }
            Directory.Delete(denied);
            Child(home, "--start", hash, installed: true);
        }
        static void FinalReplaceFailure(string home)
        {
            var engine = Seed(home); File.Copy(Image, Target(home), true);
            using (var f = new FileStream(Target(home), FileMode.Append)) f.WriteByte(0);
            string hash = Files.Hash(Target(home)); Upgrade(home, engine, "2.0.0"); Accept(home, engine);
            Json.Write(Path.Combine(engine.Root, "update-state.json"), new { resumeVpn = true });
            Child(home, "--commit-failure", hash);
            Child(home, "--start", hash, installed: true);
        }
        static void RealWriteFailure(string home)
        {
            var engine = Seed(home); Upgrade(home, engine, "2.0.0"); Accept(home, engine);
            string hash = Files.Hash(Target(home));
            string state = Path.Combine(engine.Root, "update-state.json"); Directory.CreateDirectory(state);
            bool failed = false;
            try { UpgradeInstaller.RollbackPrevious(home, engine, true); } catch (IOException) { failed = true; }
            Check(failed && File.Exists(UpgradeInstaller.ManualRollbackPath(home)) && Files.Hash(Target(home)) == hash, "real state-write failure keeps old EXE and recovery journal");
            Directory.Delete(state); UpgradeInstaller.RecoverPreviousRollback(home);
            Check(engine.Current == "1.0.0" && File.ReadAllText(Target(home)) == "image 1" && !File.Exists(UpgradeInstaller.ManualRollbackPath(home)), "startup entry retries failed state write");
        }
        static void AutoRollbackConsumesDescriptor(string home)
        {
            var engine = Seed(home); Upgrade(home, engine, "2.0.0");
            UpgradeInstaller.RollbackObservedImage(home, engine, "process-exited");
            Check(engine.Current == "1.0.0" && !File.Exists(UpgradeInstaller.PreviousPath(home)), "H2 rejection removes obsolete manual descriptor");
            RefuseUnchanged(home, () => UpgradeInstaller.RollbackPrevious(home, engine, false), "manual rollback after H2 rollback");
        }
        static void ApplyAndBundleOnly(string home)
        {
            foreach (bool accept in new[] { false, true }) {
                string sub = Path.Combine(home, "apply-" + accept); var engine = Seed(sub);
                string zip = Path.Combine(sub, "fixture.zip");
                using (var archive = ZipFile.Open(zip, ZipArchiveMode.Create)) {
                    using (var w = new StreamWriter(archive.CreateEntry("bundle-version.txt").Open())) w.Write("2.0.0\n");
                    using (var w = new StreamWriter(archive.CreateEntry("components.json").Open())) w.Write(Json.Encode(new[] { new { name = "transport", exe = "unused", critical = true } }));
                }
                UpgradeInstaller.Apply(sub, Image, zip, "1.0.0", false, _ => true, accept: accept);
                var p = Json.Read(UpgradeInstaller.PreviousPath(sub));
                Check(Json.Str(p, "ver") == "1.0.0" && File.ReadAllText(Backup(sub)) == "image 1", "downloaded Apply preserves paired old image (accept=" + accept + ")");
                if (!accept) Accept(sub, engine);
                UpgradeInstaller.RollbackPrevious(sub, engine, false);
                Check(File.ReadAllText(Target(sub)) == "image 1", "downloaded Apply can be rolled back");
            }
            string bundleHome = Path.Combine(home, "bundle-only"); var bundleEngine = Seed(bundleHome);
            Bundle(bundleEngine, "2.0.0"); bundleEngine.Activate("2.0.0"); bundleEngine.Observe(true);
            Check(UpgradeInstaller.PreviousVersion(bundleHome, bundleEngine) == "1.0.0", "bundle-only activation also records previous");
            UpgradeInstaller.RollbackPrevious(bundleHome, bundleEngine, false);
            Check(bundleEngine.Current == "1.0.0" && File.ReadAllText(Target(bundleHome)) == "image 1", "bundle-only rollback keeps paired EXE");
        }
        static void Presentation()
        {
            Check(TrayMenuModel.Rollback("", false) == null && MainScreenModel.Rollback("", false) == null, "menu and main screen hide missing previous");
            var menu = TrayMenuModel.Rollback("1.0.0", false); var screen = MainScreenModel.Rollback("1.0.0", true);
            Check(menu.Id == "rollback-previous" && menu.Text == "Вернуть предыдущую версию (1.0.0)" && menu.Enabled, "menu appears with version");
            Check(screen.Text == menu.Text && !screen.Enabled, "same main-screen action disabled while busy");
            var args = new[] { "--rollback-previous", "--home", "unused" };
            Check(WindowModel.Route(args) == WindowCommand.RollbackPrevious && !WindowModel.ShouldShow(args) && !WindowModel.ForwardArguments(args).Contains("--show"), "CLI routes and forwards rollback without opening main window");
        }
        public static int Main(string[] args)
        {
            if (args.Length > 0) return ChildMain(args);
            WithHome(ActivationAndRetention); WithHome(h => SuccessfulRollback(h, false)); WithHome(h => SuccessfulRollback(h, true));
            WithHome(Refusals); WithHome(h => BusyMutex(h, false)); WithHome(h => BusyMutex(h, true)); WithHome(RecoverInterrupted); WithHome(AtomicReplaceRefusal); WithHome(RecoveryReplaceRefusal); WithHome(FinalReplaceFailure); WithHome(RealWriteFailure);
            WithHome(AutoRollbackConsumesDescriptor); WithHome(ApplyAndBundleOnly); Presentation();
            NetHelperVersionTests.Run();
            Console.WriteLine("PASS: RollbackTests (" + checks + " checks; manual events, local transactions, no Windows/network)"); return 0;
        }
    }
}
