using System;
using System.Collections.Generic;
using System.IO;
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
            NoNetworkSourceAccepts();
            CrashLoopCountsByComponent();
            ReadinessResetsExitCount();
            OnlyNewReadinessIsProgress();
            AcceptanceIsTerminal();
            ObserverEventsRollbackTransaction();
            Console.WriteLine("PASS: UpdateHealthTests (" + checks + " checks; manual events, fake clock)");
            return 0;
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
