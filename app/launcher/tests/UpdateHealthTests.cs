using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;

namespace RemoteAgents.Launcher
{
    // H2: только ручные события и фальшивые часы. Хэндлы Windows проверяет компиляция.
    public static class UpdateHealthTests
    {
        static int checks;
        static readonly DateTime Now = new DateTime(2026, 11, 21, 12, 0, 0, DateTimeKind.Utc);
        static void Check(bool value, string message) { if (!value) throw new Exception(message); checks++; }
        public static int Main(string[] args)
        {
            if (args.Contains("--review-fixes")) {
                ReviewFixes();
                Console.WriteLine("PASS: UpdateHealthTests review fixes (" + checks + " checks; manual events, fake clock)");
                return 0;
            }
            ReviewFixes();
            NoNetworkSourceAccepts();
            CrashLoopCountsByComponent();
            ReadinessResetsExitCount();
            OnlyNewReadinessIsProgress();
            AcceptanceIsTerminal();
            ObserverEventsRollbackTransaction();
            Console.WriteLine("PASS: UpdateHealthTests (" + checks + " checks; manual events, fake clock)");
            return 0;
        }
        static void ReviewFixes()
        {
            OfflineDependentsAccept();
            FuseUsesFakeClock();
            ReceiptReadRetriesOnNextEvent();
            ProcessIdentityChanges();
            WithHome(ProgressAndCleanExitReceipt);
            WithHome(AcceptedReceiptFinalizes);
            WithHome(RejectedLauncherIsNotInstalledAgain);
        }
        static void WithHome(Action<string> test)
        {
            string home = Path.Combine(Path.GetTempPath(), "ra-h2-fix-" + Guid.NewGuid().ToString("N"));
            try { Directory.CreateDirectory(home); test(home); }
            finally { if (Directory.Exists(home)) Directory.Delete(home, true); }
        }
        static void OfflineDependentsAccept()
        {
            var state = Json.Map(Json.Parse("{\"runningComponents\":[\"disk\",\"bridge\"],\"vpnOn\":true}\r\n"));
            var board = new HealthBoard(HealthBoard.ExpectedBlocks(state), Now, new[] { "transport", "disk", "control" });
            board.Ready("tray", Now);
            using (var bus = new EventBus(manualDispatch: true)) {
                bus.Subscribe(BusTopics.BlockDegraded, e => board.Degraded(e.Get("block"), e.Get("reason"), Now));
                var tracker = new BlockStatusTracker(bus, Now, () => Now);
                tracker.Observe("transport", new Dictionary<string, object> { { "localNet", "down" }, { "ok", false } });
                bus.DrainOnce();
            }
            Check(board.Accepted && board.Missing.Length == 0 && board.Failure == "", "offline transport reports disk, vpn and control without rollback");
            var other = new HealthBoard(new[] { "tray", "transport", "disk", "vpn", "control", "local-tool" }, Now);
            other.Ready("tray", Now); other.Degraded("transport", "no-network", Now);
            Check(other.Missing.SequenceEqual(new[] { "local-tool" }), "offline exemption is limited to known network dependencies");
            var pendingTray = new HealthBoard(new[] { "tray", "transport", "disk", "vpn", "control" }, Now, new[] { "control" });
            pendingTray.Degraded("transport", "no-network", Now);
            pendingTray.Degraded("disk", "disconnected", Now); pendingTray.Degraded("vpn", "starting", Now); pendingTray.ComponentExit("control");
            Check(pendingTray.Ready("tray", Now).Completed, "later dependent status/exit cannot undo active no-network report before tray is ready");
            var crashing = new HealthBoard(new[] { "tray", "transport", "control" }, Now, new[] { "control" });
            crashing.Degraded("transport", "no-network", Now); crashing.ComponentExit("control"); crashing.ComponentExit("control");
            Check(crashing.ComponentExit("control") && !crashing.Accepted, "offline mode still detects actual critical crash-loop");
            var failed = new HealthBoard(new[] { "transport", "disk", "vpn" }, Now);
            failed.Degraded("transport", "engine-failed", Now);
            Check(failed.Missing.Length == 3 && !failed.Accepted, "other transport failures do not exempt dependencies");
        }
        static void FuseUsesFakeClock()
        {
            var board = new HealthBoard(new[] { "tray", "transport" }, Now);
            DateTime progress = Now.AddTicks(10); board.Ready("tray", progress);
            DateTime boundary = progress.AddMilliseconds(HealthBoard.UpdateNoProgressFuseMs);
            Check(!board.FuseExpired(boundary.AddTicks(-1)), "fake clock: one instant before last progress + fuse is not expired");
            Check(board.FuseExpired(boundary), "fake clock: last progress + fuse is expired");
            board.Ready("transport", boundary);
            Check(!board.FuseExpired(boundary.AddDays(1)), "acceptance disables fuse");
            var failed = new HealthBoard(new[] { "transport" }, Now); failed.Fail("manual");
            Check(!failed.FuseExpired(Now.AddDays(1)), "failure disables fuse");
        }
        static void ReceiptReadRetriesOnNextEvent()
        {
            int events = 0;
            Func<Dictionary<string, object>> read = () => {
                events++;
                if (events == 1) throw new IOException("replace");
                if (events == 2) throw new UnauthorizedAccessException("replace");
                return new Dictionary<string, object> { { "pid", 42 } };
            };
            Check(UpdateObservation.TryRead(read) == null && events == 1, "IOException waits for another event without retry loop or failure");
            Check(UpdateObservation.TryRead(read) == null && events == 2, "UnauthorizedAccessException waits for another event");
            Check(Json.Int(UpdateObservation.TryRead(read), "pid", 0) == 42 && events == 3, "next manual changed event reads receipt successfully");
            Check(UpdateObservation.Decide(true, false, true, false, cleanExit: true) == "", "clean process exit suspends observation without rollback");
            Check(UpdateObservation.Decide(true, true, true, false, cleanExit: true) == "UpdateFailed", "explicit failure is not hidden by clean shutdown during rollback");
            Check(UpdateObservation.Decide(true, false, true, false) == "process-exited", "abnormal process exit still rolls back");
        }
        static void ProcessIdentityChanges()
        {
            var record = new Dictionary<string, object> { { "pid", 42 }, { "processStarted", "123" } };
            Check(UpdateObservation.SameProcess(record, 42, "123"), "unchanged PID and start keep pinned handle");
            Check(!UpdateObservation.SameProcess(record, 43, "123"), "new PID requires another handle");
            Check(!UpdateObservation.SameProcess(record, 42, "124"), "PID reuse requires another handle");
        }
        static void ProgressAndCleanExitReceipt(string home)
        {
            string receipt = Path.Combine(home, Product.BundleDirectory, "exe-upgrade.json");
            Json.Write(receipt, new { version = "2.0.0", previous = "1.0.0", startedUtc = Now.ToString("o"), pid = 42, processStarted = "123" });
            DateTime progress = Now.AddTicks(123);
            UpgradeInstaller.NoteHealthProgress(home, progress);
            var record = Json.Read(receipt);
            Check(Json.Str(record, "lastHealthUtc") == progress.ToString("o") && Json.Int(record, "pid", 0) == 42 && Json.Str(record, "version") == "2.0.0", "lastHealthUtc is durably saved without losing transaction/process fields");
            UpgradeInstaller.NoteCleanExit(home);
            // Поздний отчёт готовности сохраняет отметку штатного выхода.
            UpgradeInstaller.NoteHealthProgress(home, progress);
            Check(File.Exists(receipt) && Json.Bool(Json.Read(receipt), "cleanExit"), "clean exit keeps receipt and survives subsequent progress");
            DateTime resumed = Now.AddDays(1); UpgradeInstaller.PrepareImageLaunch(home, resumed);
            record = Json.Read(receipt);
            Check(!Json.Bool(record, "cleanExit") && !record.ContainsKey("pid") && !record.ContainsKey("processStarted") && !record.ContainsKey("lastHealthUtc") && Json.Str(record, "startedUtc") == resumed.ToString("o"), "resumed launch clears old identity and restarts progress with fake clock");
            UpgradeInstaller.NoteHealthAccepted(home);
            Check(Json.Bool(Json.Read(receipt), "healthAccepted"), "accepted decision survives finalization errors/restart");
        }
        static void AcceptedReceiptFinalizes(string home)
        {
            var engine = new UpdateEngine(home, "1.0.0", () => Now);
            foreach (string v in new[] { "1.0.0", "2.0.0" }) {
                Directory.CreateDirectory(engine.Folder(v));
                Json.Write(Path.Combine(engine.Folder(v), "components.json"), new[] { new { name = "transport", exe = "unused", critical = true } });
                engine.Activate(v);
            }
            string receipt = Path.Combine(engine.Root, "exe-upgrade.json");
            Json.Write(receipt, new { version = "2.0.0", previous = "1.0.0" });
            var offline = new HealthBoard(new[] { "tray", "transport", "disk", "vpn", "control" }, Now);
            offline.Ready("tray", Now); offline.Degraded("transport", "no-network", Now);
            Check(offline.Accepted, "offline transaction accepts before finalization");
            UpgradeInstaller.NoteHealthAccepted(home);
            // Имитируем обрыв между сохранённым решением и финализацией: создаём доску нового сеанса.
            var resumed = new HealthBoard(new[] { "tray", "transport" }, Now, new[] { "transport" }, accepted: UpgradeInstaller.ImageHealthAccepted(home));
            Check(resumed.Accepted && !resumed.Fail("late-error") && !resumed.ComponentExit("transport"), "saved acceptance is terminal after restart/finalization error");
            string result = engine.Observe(resumed.Accepted);
            Check(result == "accepted" && UpgradeInstaller.ObserveImage(home, engine, true, result) == "accepted" && !engine.Pending && !engine.IsBad("2.0.0") && !File.Exists(receipt), "offline accepted transaction finalizes without rollback or bad.txt");
        }
        static void RejectedLauncherIsNotInstalledAgain(string home)
        {
            var engine = new UpdateEngine(home, "1.0.0", () => Now);
            Directory.CreateDirectory(engine.Folder("1.0.0"));
            Json.Write(Path.Combine(engine.Folder("1.0.0"), "components.json"), new[] { new { name = "transport", exe = "unused", critical = true } });
            engine.Activate("1.0.0");
            string target = Path.Combine(home, Product.ExeName), backup = Path.Combine(home, Product.Name + ".previous.exe"), rejected = Path.Combine(home, "candidate.exe");
            File.WriteAllText(target, "new launcher"); File.WriteAllText(rejected, "new launcher"); File.WriteAllText(backup, "old launcher");
            Json.Write(Path.Combine(engine.Root, "exe-upgrade.json"), new { version = "1.0.0", previous = "1.0.0", previousHash = Files.Hash(backup), currentHash = Files.Hash(target), launcherVersion = "2.0.0" });
            Check(UpgradeInstaller.ObserveImage(home, engine, false, "rollback") == "rollback" && File.ReadAllText(target) == "old launcher", "launcher-only rollback restores previous bytes");
            Check(!engine.IsBad("1.0.0") && UpgradeInstaller.IsRejectedImage(home, Files.Hash(rejected)), "working bundle stays allowed; rejected launcher hash is persisted");
            string zip = Path.Combine(home, "bundle.zip");
            using (var archive = ZipFile.Open(zip, ZipArchiveMode.Create))
            using (var writer = new StreamWriter(archive.CreateEntry("bundle-version.txt").Open())) writer.Write("1.0.0\r\n");
            bool refused = false, selftestCalled = false;
            try { UpgradeInstaller.Apply(home, rejected, zip, "2.0.0", false, d => { selftestCalled = true; return true; }); }
            catch (InvalidDataException) { refused = true; }
            Check(refused && !selftestCalled && !engine.Pending && File.ReadAllText(target) == "old launcher" && !File.Exists(Path.Combine(engine.Root, "exe-upgrade.json")), "same downloaded EXE cannot repeat rejected launcher-only installation");
            File.WriteAllText(rejected, "different launcher");
            Check(!UpgradeInstaller.IsRejectedImage(home, Files.Hash(rejected)), "different image is not banned");
        }
        static void NoNetworkSourceAccepts()
        {
            using (var bus = new EventBus(manualDispatch: true)) {
                var board = new HealthBoard(new[] { "tray", "transport" }, Now);
                var seen = new List<BusEvent>();
                bus.Subscribe(BusTopics.BlockDegraded, e => { seen.Add(e); board.Degraded(e.Get("block"), e.Get("reason"), Now); });
                var tracker = new BlockStatusTracker(bus, Now, () => Now, p => Now);
                board.Ready("tray", Now);
                var offline = new Dictionary<string, object> { { "ok", false }, { "phase", "searching" }, { "localNet", "down" }, { "summary", "localized text" } };
                tracker.Observe("transport", offline); tracker.Observe("transport", offline); bus.DrainOnce();
                Check(seen.Count == 1 && seen[0].Get("reason") == "no-network" && board.Accepted, "first offline status counts once without block.ready or a tick");
                tracker.Reset("transport");
                tracker.Observe("transport", new Dictionary<string, object> { { "ok", false }, { "summary", "starting" } }); bus.DrainOnce();
                tracker.Observe("transport", offline); bus.DrainOnce();
                Check(seen.Count == 2 && seen[1].Get("reason") == "no-network", "not-ready to no-network publishes the changed reason");
                tracker.Observe("transport", new Dictionary<string, object> { { "ok", false }, { "localNet", "unknown" }, { "summary", "engine failed" } }); bus.DrainOnce();
                Check(seen.Count == 3 && seen[2].Get("reason") == "engine failed", "engine failure is not disguised as no-network");
            }
        }
        static void CrashLoopCountsByComponent()
        {
            var b = new HealthBoard(new[] { "tray", "transport", "control" }, Now, new[] { "transport", "bridge" });
            Check(!b.ComponentExit("transport") && !b.ComponentExit("control"), "separate critical counters");
            Check(!b.ComponentExit("transport"), "second transport exit is not crash-loop");
            for (int i = 0; i < 4; i++) Check(!b.ComponentExit("optional"), "noncritical exits ignored");
            Check(b.ComponentExit("transport") && b.Failure == "crash-loop:transport", "third exit before block.ready fails");
            Check(!b.ComponentExit("transport") && !b.Ready("transport", Now).Counted && !b.Accepted, "failure is terminal and emitted once");
        }
        static void ReadinessResetsExitCount()
        {
            var b = new HealthBoard(new[] { "tray", "transport" }, Now, new[] { "transport", "control" });
            b.ComponentExit("transport"); b.ComponentExit("transport"); b.Ready("transport", Now);
            Check(!b.ComponentExit("transport") && !b.ComponentExit("transport"), "block.ready resets previous two exits");
            b.Degraded("transport", "no-network", Now);
            Check(b.ComponentExit("transport"), "no-network is a report but does not reset crash count");
            var other = new HealthBoard(new[] { "tray", "transport" }, Now, new[] { "control" });
            other.ComponentExit("bridge"); other.ComponentExit("bridge"); other.Ready("control", Now);
            Check(!other.ComponentExit("bridge"), "ready resets critical counter even outside expected set, with bridge alias");
        }
        static void OnlyNewReadinessIsProgress()
        {
            var b = new HealthBoard(new[] { "tray", "transport" }, Now);
            b.Ready("tray", Now);
            DateTime nextEvent = Now.AddTicks(1);
            Check(!b.Ready("tray", nextEvent).Counted && b.LastEventUtc == Now, "duplicate readiness is not progress");
            b.Degraded("transport", "engine-failed", nextEvent);
            b.Ready("unknown", nextEvent);
            Check(b.LastEventUtc == Now, "degradation and outsiders do not refresh progress");
            Check(b.Ready("transport", nextEvent).Completed && b.LastEventUtc == nextEvent, "new readiness records progress and accepts immediately");
        }
        static void AcceptanceIsTerminal()
        {
            var b = new HealthBoard(new[] { "tray" }, Now, new[] { "tray" });
            Check(b.Ready("tray", Now).Completed, "last readiness accepts");
            Check(!b.Fail("no-progress-fuse") && !b.ComponentExit("tray") && b.Accepted, "late failure event cannot reverse completed board");
            Check(UpdateObservation.Decide(false, true, true, true) == "", "removed receipt ends observer even with queued failure signals");
            Check(UpdateObservation.Decide(true, false, false, false) == null, "observer waits when no terminal event occurred");
        }
        static void ObserverEventsRollbackTransaction()
        {
            string root = Path.Combine(Path.GetTempPath(), "ra-h2-" + Guid.NewGuid().ToString("N"));
            try {
                foreach (string signal in new[] { "UpdateFailed", "process-exited", "no-progress-fuse", "accepted" }) {
                    string home = Path.Combine(root, signal); var engine = new UpdateEngine(home, "1.0.0", () => Now);
                    foreach (string v in new[] { "1.0.0", "2.0.0" }) {
                        Directory.CreateDirectory(engine.Folder(v));
                        Json.Write(Path.Combine(engine.Folder(v), "components.json"), new[] { new { name = "transport", exe = "unused", critical = true } });
                    }
                    engine.Activate("1.0.0"); engine.Activate("2.0.0");
                    string target = Path.Combine(home, Product.ExeName), backup = Path.Combine(home, Product.Name + ".previous.exe");
                    File.WriteAllText(target, "new image"); File.WriteAllText(backup, "old image");
                    Json.Write(Path.Combine(engine.Root, "exe-upgrade.json"), new { version = "2.0.0", previous = "1.0.0", previousHash = Files.Hash(backup), startedUtc = Now.ToString("o") });
                    string keep = Path.Combine(home, "state", "keep"); Files.Atomic(keep, "user state");
                    string reason = UpdateObservation.Decide(true, signal == "UpdateFailed", signal == "process-exited", signal == "no-progress-fuse");
                    var board = new HealthBoard(new[] { "tray", "transport" }, Now);
                    if (reason == null) {
                        board.Ready("tray", Now); var last = board.Ready("transport", Now);
                        Check(last.Completed, "acceptance transaction triggered by last report");
                        string result = engine.Observe(board.Accepted);
                        Check(result == "accepted" && UpgradeInstaller.ObserveImage(home, engine, true, result) == "accepted" && engine.Current == "2.0.0", "health.accepted commits bundle and image");
                    } else {
                        Check(reason == signal && board.Fail(reason), "manual observer event rejects incomplete board: " + signal);
                        string result = engine.Observe(board.Accepted, failed: true);
                        Check(result == "rollback" && UpgradeInstaller.ObserveImage(home, engine, false, result) == "rollback", "failure rolls back bundle and image: " + signal);
                        Check(engine.Current == "1.0.0" && engine.IsBad("2.0.0") && File.ReadAllText(target) == "old image", "previous bytes restored and bad version recorded: " + signal);
                    }
                    Check(!engine.Pending && !File.Exists(Path.Combine(engine.Root, "exe-upgrade.json")) && File.ReadAllText(keep) == "user state", "receipt settled and user state preserved: " + signal);
                }
            } finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
        }
    }
}
