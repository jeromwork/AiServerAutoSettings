using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Reflection;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Threading;

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
            if (args.Length == 2 && args[0] == "--receipt-race-child") return ReceiptRaceChild(args[1]);
            if (args.Contains("--review-fixes3")) {
                ReviewFixes3();
                Console.WriteLine("PASS: UpdateHealthTests review fixes 3 (" + checks + " checks; manual events, fake clock, child process)");
                return 0;
            }
            if (args.Contains("--review-fixes2")) {
                ReviewFixes2();
                Console.WriteLine("PASS: UpdateHealthTests review fixes 2 (" + checks + " checks; manual events, fake clock)");
                return 0;
            }
            if (args.Contains("--review-fixes")) {
                ReviewFixes();
                Console.WriteLine("PASS: UpdateHealthTests review fixes (" + checks + " checks; manual events, fake clock)");
                return 0;
            }
            ReviewFixes3();
            ReviewFixes2();
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
        static void ReviewFixes3()
        {
            WithHome(UnreadableReceiptKeepsFuse);
            WithHome(ReceiptWritersSerializeAcrossProcesses);
            WithHome(OtaReceiptIgnoresPreviousImageExit);
            WithHome(CorruptReceiptHasTerminalRecovery);
        }
        sealed class ManualImageProcess : UpdateObservation.IImageProcess
        {
            internal readonly ManualResetEvent Exit = new ManualResetEvent(false);
            internal bool Clean;
            public WaitHandle Exited { get { return Exit; } }
            public bool HasExited { get { return Exit.WaitOne(0); } }
            public bool CleanExit { get { return Clean; } }
            public void Dispose() { Exit.Dispose(); }
        }
        static void UnreadableReceiptKeepsFuse(string home)
        {
            string receipt = UpgradeInstaller.ReceiptPath(home);
            foreach (string outcome in new[] { "clean", "crash", "unavailable" }) {
                Json.Write(receipt, new { version = "2.0.0", currentHash = "image", pid = 42, processStarted = "123", startedUtc = Now.ToString("o") });
                DateTime now = Now; bool blocked = false; int waits = 0, reads = 0;
                var process = new ManualImageProcess { Clean = outcome == "clean" };
                using (var changed = new AutoResetEvent(false))
                using (var failed = new ManualResetEvent(false)) {
                    string result = UpdateObservation.WaitForOutcome(() => File.Exists(receipt), () => {
                        reads++;
                        if (blocked) throw new IOException("incompatible FileShare");
                        return UpdateObservation.ReadReceipt(receipt);
                    }, changed, failed, (pid, started) => process,
                    (pid, started) => UpgradeInstaller.NoteCleanExit(home, pid, started), () => now, (handles, remaining) => {
                        Check(remaining > 0 && remaining <= HealthBoard.UpdateNoProgressFuseMs, "every wait, including read errors, retains a finite fuse");
                        switch (waits++) {
                            case 0:
                                blocked = true; changed.Set(); return WaitHandle.WaitAny(handles, 0);
                            case 1:
                                now = now.AddMilliseconds(100); process.Exit.Set();
                                Check(handles.Length == 3, "first failed read still observes the process");
                                return WaitHandle.WaitAny(handles, 0);
                            case 2:
                                Check(handles.Length == 2 && !changed.WaitOne(0), "delivered exit is remembered without a busy loop or new changed");
                                Check(remaining == HealthBoard.UpdateNoProgressFuseMs - 100, "second read error does not restart the deadline");
                                if (outcome != "unavailable") blocked = false; // release the reader WITHOUT changed
                                now = now.AddMilliseconds(remaining); return WaitHandle.WaitTimeout;
                            default: throw new Exception("observer waited beyond the fuse");
                        }
                    });
                    Check(waits == 3 && reads == 4, "actual loop consumes read-error -> exited -> read-error -> silent release/timeout");
                    Check(result == (outcome == "clean" ? "" : outcome == "crash" ? "process-exited" : "receipt-unavailable"), "bounded result processes the already delivered exit: " + outcome);
                }
            }
        }
        static int ReceiptRaceChild(string home)
        {
            using (var gate = new Mutex(false, UpgradeInstaller.ReceiptMutexName(home))) {
                bool owned; try { owned = gate.WaitOne(0); } catch (AbandonedMutexException) { owned = true; }
                if (owned) { gate.ReleaseMutex(); Console.WriteLine("unlocked"); return 2; }
                Console.WriteLine("blocked"); Console.Out.Flush();
            }
            // Реальные писатели в другом процессе: должны дождаться окончания R/M/W наблюдателя A.
            UpgradeInstaller.NoteImageProcess(home, 43, "B", Now.AddTicks(1), "image");
            UpgradeInstaller.NoteHealthProgress(home, Now.AddTicks(2));
            return 0;
        }
        static void ReceiptWritersSerializeAcrossProcesses(string home)
        {
            string receipt = UpgradeInstaller.ReceiptPath(home);
            Json.Write(receipt, new { version = "2.0.0", currentHash = "image", pid = 42, processStarted = "A", startedUtc = Now.ToString("o") });
            Process child = null;
            try {
                using (UpgradeInstaller.LockReceipt(home)) {
                    var snapshot = UpdateObservation.ReadReceipt(receipt); // наблюдатель прочёл A до конкурентного B
                    child = Process.Start(new ProcessStartInfo("dotnet", Files.Quote(Assembly.GetExecutingAssembly().Location) + " --receipt-race-child " + Files.Quote(home)) {
                        UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true
                    });
                    Check(child.StandardOutput.ReadLine() == "blocked", "same named mutex is held across processes");
                    Check(UpgradeInstaller.NoteCleanExit(home, Json.Int(snapshot, "pid", 0), Json.Str(snapshot, "processStarted")) == 1, "observer finishes A's read/check/write while B is blocked");
                    Check(UpdateObservation.SameProcess(UpdateObservation.ReadReceipt(receipt), 42, "A") && !child.HasExited, "B cannot overwrite the receipt inside A's transaction");
                }
                Check(child.WaitForExit(10000), "B finishes after shared transaction releases");
                Check(child.ExitCode == 0, "B registration succeeds: " + child.StandardError.ReadToEnd());
                var record = UpdateObservation.ReadReceipt(receipt);
                Check(UpdateObservation.SameProcess(record, 43, "B") && !Json.Bool(record, "cleanExit") && Json.Str(record, "lastHealthUtc") == Now.AddTicks(2).ToString("o"), "new B identity and progress survive the race");
                Check(UpgradeInstaller.NoteCleanExit(home, 42, "A") == -1 && UpdateObservation.SameProcess(UpdateObservation.ReadReceipt(receipt), 43, "B"), "late A write cannot replace registered B");
                bool released = false;
                Check(!UpgradeInstaller.TryFinishObservation(home, () => released = true) && !released, "observer cannot retire when B replaced A's clean marker");
                using (var changed = new ManualResetEvent(false))
                using (var failed = new ManualResetEvent(false)) {
                    var processB = new ManualImageProcess(); processB.Exit.Set();
                    Check(UpdateObservation.WaitForOutcome(() => File.Exists(receipt), () => UpdateObservation.ReadReceipt(receipt), changed, failed,
                        (pid, started) => { Check(pid == 43 && started == "B", "continuation binds the registered B"); return processB; },
                        (pid, started) => UpgradeInstaller.NoteCleanExit(home, pid, started), () => Now,
                        (handles, ms) => { throw new Exception("B crash must be delivered immediately"); }) == "process-exited", "B crash remains observable after A clean exit race");
                }
                UpgradeInstaller.NoteCleanExit(home, 43, "B");
                Check(UpgradeInstaller.TryFinishObservation(home, () => {
                    using (var gate = new Mutex(false, UpgradeInstaller.ReceiptMutexName(home))) {
                        Check(gate.WaitOne(0), "observer retirement runs inside shared recursive mutex"); gate.ReleaseMutex();
                    }
                    released = true;
                }) && released, "observer releases singleton atomically before later registration can start");
            } finally {
                if (child != null) { if (!child.HasExited) { child.Kill(); child.WaitForExit(10000); } child.Dispose(); }
            }
        }
        static void OtaReceiptIgnoresPreviousImageExit(string home)
        {
            string receipt = UpgradeInstaller.ReceiptPath(home);
            Json.Write(receipt, new { version = "2.0.0", currentHash = "new-image", startedUtc = Now.ToString("o") });
            UpgradeInstaller.NoteCurrentImageCleanExit(home); // тот же путь, что у трея/Application.Run/SessionEnding
            Check(UpgradeInstaller.NoteCleanExit(home, 41, "old") == -1 && UpgradeInstaller.NoteCleanExit(home, 0, null) == -1, "OTA receipt without PID rejects old image and missing identity");
            Check(Json.Int(Json.Read(receipt), "cleanExitCount", 0) == 0 && !Json.Bool(Json.Read(receipt), "cleanExit"), "old image exit leaves the new transaction count at zero");
            UpgradeInstaller.PrepareImageLaunch(home, Now);
            for (int n = 1; n <= 3; n++) {
                UpgradeInstaller.NoteImageProcess(home, 42, n.ToString(), Now, "new-image");
                int count = UpgradeInstaller.NoteCleanExit(home, 42, n.ToString());
                Check(count == n && UpgradeInstaller.NoteCleanExit(home, 42, n.ToString()) == n, "only a registered new image counts, once per identity");
                Check(UpdateObservation.Decide(true, false, true, false, true, count) == (n == 3 ? "clean-exit-loop" : ""), "OTA rollback starts on third new-image exit");
                UpgradeInstaller.PrepareImageLaunch(home, Now);
            }
        }
        static void CorruptReceiptHasTerminalRecovery(string home)
        {
            foreach (bool signaled in new[] { false, true }) {
                string folder = Path.Combine(home, signaled ? "failed" : "quiet");
                var engine = new UpdateEngine(folder, "1.0.0", () => Now);
                foreach (string version in new[] { "1.0.0", "2.0.0" }) {
                    Directory.CreateDirectory(engine.Folder(version));
                    Json.Write(Path.Combine(engine.Folder(version), "components.json"), new[] { new { name = "transport", exe = "unused", critical = true } });
                }
                engine.Activate("1.0.0"); engine.Activate("2.0.0");
                string receipt = UpgradeInstaller.ReceiptPath(folder), target = Path.Combine(folder, Product.ExeName);
                File.WriteAllText(target, "current image"); File.WriteAllText(Path.Combine(folder, Product.Name + ".previous.exe"), "unverified backup");
                File.WriteAllText(receipt, "{broken\r\n");
                UpgradeInstaller.PrepareImageLaunch(folder, Now);
                UpgradeInstaller.NoteImageProcess(folder, 42, "123", Now, "image");
                Check(!UpgradeInstaller.ImageHealthAccepted(folder), "damaged receipt does not block startup before observer can recover");
                using (var changed = new ManualResetEvent(false))
                using (var failed = new ManualResetEvent(signaled)) {
                    string reason = UpdateObservation.WaitForOutcome(() => File.Exists(receipt), () => UpdateObservation.ReadReceipt(receipt), changed, failed,
                        (pid, started) => { throw new Exception("unexpected process bind"); }, (pid, started) => 0, () => Now,
                        (handles, ms) => { throw new Exception("corrupt JSON must never wait for changed"); });
                    Check(reason == "invalid-receipt", "real malformed JSON has priority even with UpdateFailed already set");
                    failed.Set(); bool preserveFailure = false;
                    try {
                        preserveFailure = UpdateObservation.TryRollback(() => UpgradeInstaller.RollbackObservedImage(folder, engine, reason),
                            failure => UpdateObservation.RecordRollbackFailure(folder, failure));
                    } finally { if (!preserveFailure) failed.Reset(); }
                    Check(!preserveFailure && !failed.WaitOne(0), "invalid receipt enters rollback failure path and disarms restart");
                    Check(!File.Exists(receipt) && File.ReadAllText(receipt + ".invalid") == "{broken\r\n", "one diagnostic copy replaces the blocking receipt");
                    Check(!engine.Pending && engine.Current == "1.0.0" && engine.IsBad("2.0.0"), "bundle recovers using its independent transaction");
                    var state = Json.Read(Path.Combine(engine.Root, "update-state.json"));
                    Check(!Json.Bool(state, "pending") && Json.Str(state, "failureReason") == "rollback-failed:InvalidReceiptException", "invalid receipt diagnostic is durable before restart");
                    Check(File.ReadAllText(target) == "current image", "missing trustworthy previousHash never installs unverified EXE");
                    UpgradeInstaller.PrepareImageLaunch(folder, Now); UpgradeInstaller.NoteImageProcess(folder, 43, "124", Now, "image");
                    Check(UpdateObservation.WaitForOutcome(() => File.Exists(receipt), () => UpdateObservation.ReadReceipt(receipt), changed, failed,
                        (pid, started) => null, (pid, started) => 0, () => Now, (handles, ms) => { throw new Exception("unexpected repeat observation"); }) == "", "restart neither reparses corrupt receipt nor rearms failure");
                }
            }
        }
        static void ReviewFixes2()
        {
            WithHome(NewProcessRestartsProgress);
            WithHome(RollbackExceptionDisarmsRestart);
            WithHome(CleanExitsAreBounded);
            ReceiptReadWaitsForProcessExit();
        }
        static void NewProcessRestartsProgress(string home)
        {
            string receipt = Path.Combine(home, Product.BundleDirectory, "exe-upgrade.json");
            DateTime old = Now.AddDays(-1);
            Json.Write(receipt, new { version = "2.0.0", currentHash = "image", pid = 42, processStarted = "123",
                startedUtc = old.ToString("o"), lastHealthUtc = old.ToString("o"), cleanExitCount = 1 });
            UpgradeInstaller.NoteImageProcess(home, 43, "124", Now, "other-image");
            Check(Json.Str(Json.Read(receipt), "lastHealthUtc") == old.ToString("o"), "another image cannot change transaction progress");
            UpgradeInstaller.NoteImageProcess(home, 43, "124", Now, "image");
            var record = Json.Read(receipt);
            Check(!record.ContainsKey("lastHealthUtc") && Json.Str(record, "startedUtc") == Now.ToString("o"), "unclean restart discards yesterday's progress");
            Check(UpdateObservation.SameProcess(record, 43, "124") && Json.Int(record, "cleanExitCount", 0) == 1, "new identity is persisted without resetting clean-exit counter");
            var board = new HealthBoard(new[] { "transport" }, DateTime.Parse(Json.Str(record, "startedUtc"), null, System.Globalization.DateTimeStyles.RoundtripKind));
            Check(!board.FuseExpired(Now), "new process is not rejected using stale progress after power loss");
            DateTime progress = Now.AddTicks(1); UpgradeInstaller.NoteHealthProgress(home, progress);
            UpgradeInstaller.NoteImageProcess(home, 43, "124", Now.AddTicks(2), "image");
            Check(Json.Str(Json.Read(receipt), "lastHealthUtc") == progress.ToString("o"), "same process cannot restart progress by registering twice");
            UpgradeInstaller.NoteImageProcess(home, 43, "125", Now.AddTicks(3), "image");
            Check(!Json.Read(receipt).ContainsKey("lastHealthUtc"), "PID reuse also resets stale progress");
            UpgradeInstaller.NoteHealthProgress(home, old);
            UpgradeInstaller.PrepareImageLaunch(home, Now);
            record = Json.Read(receipt);
            Check(!record.ContainsKey("pid") && !record.ContainsKey("processStarted") && !record.ContainsKey("lastHealthUtc") && Json.Str(record, "startedUtc") == Now.ToString("o"), "observer armed before EXE sees fresh progress even without cleanExit");
        }
        static void RollbackExceptionDisarmsRestart(string home)
        {
            string statePath = Path.Combine(home, Product.BundleDirectory, "update-state.json");
            Json.Write(statePath, new { pending = true, version = "2.0.0", userField = "keep" });
            var log = new List<string>();
            foreach (Exception error in new Exception[] { new InvalidDataException("missing previous EXE"), new IOException("stop failed"), new ArgumentException("corrupt receipt") }) {
                bool preserveFailure = UpdateObservation.TryRollback(() => { throw error; }, reason => {
                    log.Add(reason); UpdateObservation.RecordRollbackFailure(home, reason);
                });
                var state = Json.Read(statePath);
                Check(!preserveFailure, "rollback exception does not rearm restart: " + error.GetType().Name);
                Check(Json.Str(state, "failureReason") == "rollback-failed:" + error.GetType().Name && !Json.Bool(state, "pending"), "rollback failure is persisted independently of receipt");
            }
            Check(log.Count == 3 && Json.Str(Json.Read(statePath), "userField") == "keep", "one diagnostic per attempt preserves existing state");
            Check(UpdateObservation.TryRollback(() => { }, reason => { throw new Exception("unexpected report"); }), "successful rollback remains distinct from failed rollback");
            File.WriteAllText(statePath, "{broken\r\n");
            Check(!UpdateObservation.TryRollback(() => { throw new InvalidDataException(); }, reason => UpdateObservation.RecordRollbackFailure(home, reason)) &&
                Json.Str(Json.Read(statePath), "failureReason") == "rollback-failed:InvalidDataException", "corrupt state cannot hide rollback failure or rearm restart");
        }
        static void CleanExitsAreBounded(string home)
        {
            string receipt = Path.Combine(home, Product.BundleDirectory, "exe-upgrade.json");
            Json.Write(receipt, new { version = "2.0.0", currentHash = "image" });
            for (int n = 1; n <= UpdateObservation.CleanExitLimit; n++) {
                string started = n.ToString();
                UpgradeInstaller.NoteImageProcess(home, 42, started, Now, "image");
                int count = UpgradeInstaller.NoteCleanExit(home, 42, started);
                Check(count == n && UpgradeInstaller.NoteCleanExit(home, 42, started) == n, "session-ending and Application.Run count one exit per process");
                Check(UpdateObservation.Decide(true, false, true, false, true, count) == (n == 3 ? "clean-exit-loop" : ""), "third clean/code-zero exit before acceptance fails without a timer");
                Check(UpdateObservation.Decide(true, false, false, false, true, count) == (n == 3 ? "clean-exit-loop" : ""), "persisted cleanExit marker obeys the same limit");
                UpgradeInstaller.PrepareImageLaunch(home, Now);
            }
            UpgradeInstaller.NoteImageProcess(home, 42, "4", Now, "image");
            Check(UpgradeInstaller.NoteCleanExit(home, 42, "old") == -1 && !Json.Bool(Json.Read(receipt), "cleanExit"), "old process handle cannot mark new process clean");
            Check(UpgradeInstaller.NoteCleanExit(home, 42, "4") == 3, "clean-exit count saturates at three under repeated launches");
            UpgradeInstaller.PrepareImageLaunch(home, Now);
            UpgradeInstaller.NoteHealthAccepted(home);
            Check(UpdateObservation.Decide(false, true, true, true, true, 3) == "", "completed transaction ignores old clean-exit count");
            Json.Write(receipt, new { healthAccepted = true, pid = 42, processStarted = "accepted" });
            Check(UpgradeInstaller.NoteCleanExit(home, 42, "accepted") == 0, "accepted receipt does not accumulate clean exits");
        }
        static void ReceiptReadWaitsForProcessExit()
        {
            using (var failed = new ManualResetEvent(false))
            using (var changed = new ManualResetEvent(false))
            using (var exited = new ManualResetEvent(false)) {
                Check(UpdateObservation.TryRead(() => { throw new IOException("replace"); }) == null, "manual read error selects receipt-wait branch");
                var handles = UpdateObservation.OutcomeHandles(failed, changed, exited);
                exited.Set();
                Check(handles.Length == 3 && WaitHandle.WaitAny(handles, 0) == 2, "receipt read failure can wake on process exit without file change");
                Check(UpdateObservation.OutcomeHandles(failed, changed, null).Length == 2, "unregistered process waits only on existing handles");
            }
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
            UpgradeInstaller.NoteCleanExit(home, 42, "123");
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
