using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;

namespace RemoteAgents.Launcher
{
    public static class SupervisorStaleTests
    {
        static int assertions;
        static void Check(bool ok, string what) { if (!ok) throw new Exception("Assertion failed: " + what); assertions++; }

        public static int Main(string[] args)
        {
            Console.WriteLine("Starting SupervisorStaleTests...");
            StaleDecisionTriggersKillAndRestart();
            FreshStatusGivesNothing();
            ProcessJustStartedGivesNothing();
            FuseMinimumThirtySeconds();
            HangBeforeFirstWriteIsKilled();
            MissingStatusRestartsRuntimeOnce();
            UnmonitoredRuntimesAreSkipped();
            ClockJumpDoesNotKill();
            BusyUiGapSkipsOnceThenWorks();
            SkippedStatusStillTracksResume();
            WireSupervisorTickAndEvent();
            Console.WriteLine("PASS: SupervisorStaleTests (" + assertions + " assertions passed)");
            return 0;
        }

        static void StaleDecisionTriggersKillAndRestart()
        {
            var started = new DateTime(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc);
            var fileWritten = started.AddSeconds(10); // file written after start
            int maxAge = 15; // fuse = max(30s, 3*15s) = 45s

            // Boundary: exactly 45s after write (age == 45s, not > 45s) -> not stale
            var nowAtBoundary = fileWritten.AddSeconds(45);
            Check(SupervisorStale.Decide(fileWritten, nowAtBoundary, maxAge, started) == SupervisorDecision.None, "boundary at 45s gives None");
            Check(!SupervisorStale.IsStale(fileWritten, nowAtBoundary, maxAge, started), "boundary at 45s IsStale is false");

            // Stale: 46s after write (age == 46s > 45s) -> stale -> one decision kill+restart
            var nowStale = fileWritten.AddSeconds(46);
            Check(SupervisorStale.Decide(fileWritten, nowStale, maxAge, started) == SupervisorDecision.KillAndRestart, "age > fuse returns KillAndRestart");
            Check(SupervisorStale.IsStale(fileWritten, nowStale, maxAge, started), "age > fuse IsStale is true");
        }

        static void FreshStatusGivesNothing()
        {
            var started = new DateTime(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc);
            var fileWritten = started.AddSeconds(5);
            var now = started.AddSeconds(10); // age = 5s, maxAge = 15s, fuse = 45s
            Check(SupervisorStale.Decide(fileWritten, now, 15, started) == SupervisorDecision.None, "fresh status -> None");
            Check(!SupervisorStale.IsStale(fileWritten, now, 15, started), "fresh status -> not stale");
        }

        static void ProcessJustStartedGivesNothing()
        {
            // Process started at 12:00:00
            var started = new DateTime(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc);
            // File on disk is from a previous process run (11:55:00)
            var oldFile = started.AddMinutes(-5);
            // Even though now is 12:00:10 (age > 5 min):
            var now = started.AddSeconds(10);
            Check(SupervisorStale.Decide(oldFile, now, 15, started) == SupervisorDecision.None, "file older than start -> None");
            Check(!SupervisorStale.IsStale(oldFile, now, 15, started), "file older than start -> not stale");
        }

        static void FuseMinimumThirtySeconds()
        {
            var started = new DateTime(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc);
            var fileWritten = started;

            // When MaxAge is small (5s): 3 * 5 = 15s < 30s. Fuse must be clamped to 30000 ms.
            Check(SupervisorStale.FuseMs(5) == 30000, "fuse for maxAge 5 is 30000 ms");
            Check(SupervisorStale.Decide(fileWritten, started.AddSeconds(29), 5, started) == SupervisorDecision.None, "29s < 30s fuse -> None");
            Check(SupervisorStale.Decide(fileWritten, started.AddSeconds(31), 5, started) == SupervisorDecision.KillAndRestart, "31s > 30s fuse -> KillAndRestart");

            // When MaxAge is large (90s): 3 * 90 = 270s > 30s. Fuse is 270000 ms.
            Check(SupervisorStale.FuseMs(90) == 270000, "fuse for maxAge 90 is 270000 ms");
            Check(SupervisorStale.Decide(fileWritten, started.AddSeconds(269), 90, started) == SupervisorDecision.None, "269s < 270s fuse -> None");
            Check(SupervisorStale.Decide(fileWritten, started.AddSeconds(271), 90, started) == SupervisorDecision.KillAndRestart, "271s > 270s fuse -> KillAndRestart");
        }

        static void HangBeforeFirstWriteIsKilled()
        {
            var started = new DateTime(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc);
            var oldFile = started.AddMinutes(-10); // файл от прошлого запуска, новый процесс ничего не записал
            Check(SupervisorStale.Decide(oldFile, started.AddSeconds(29), 5, started) == SupervisorDecision.None, "old file, 29s after start -> None");
            Check(SupervisorStale.Decide(oldFile, started.AddSeconds(31), 5, started) == SupervisorDecision.KillAndRestart, "old file, 31s after start -> kill");
            Check(Math.Abs(SupervisorStale.AgeMs(oldFile, started.AddSeconds(31), started) - 31000) < 1, "age counted from start");
        }

        static Component Definition(bool periodic = true)
        {
            var raw = new Dictionary<string, object> {
                { "name", "transport" }, { "exe", "unused.exe" }, { "restart", "always" }, { "healthMaxAgeSec", 15 }
            };
            if (periodic) raw["healthFile"] = "status/transport.json";
            return Component.Read(raw);
        }

        // Настоящий ComponentRuntime; только Windows-задача заменена объектом в памяти (ни одного процесса/ожидания).
        static FieldInfo RuntimeField(string name) { return typeof(ComponentRuntime).GetField(name, BindingFlags.Instance | BindingFlags.NonPublic); }

        static void MissingStatusRestartsRuntimeOnce()
        {
            ExerciseRuntime(Definition(), enabled: true, running: true, shouldRestart: true);
        }

        static void UnmonitoredRuntimesAreSkipped()
        {
            ExerciseRuntime(Definition(), enabled: false, running: true, shouldRestart: false);
            ExerciseRuntime(Definition(), enabled: true, running: false, shouldRestart: false);
            var noPeriodicStatus = Definition(periodic: false);
            Check(!noPeriodicStatus.HasPeriodicStatus && noPeriodicStatus.HealthFile.Length > 0,
                "default status path does not promise periodic writes (Syncthing)");
            ExerciseRuntime(noPeriodicStatus, enabled: true, running: true, shouldRestart: false);
            var noRestart = Definition(); noRestart.Restart = "never";
            ExerciseRuntime(noRestart, enabled: true, running: true, shouldRestart: false);
            var commandManaged = Definition(); commandManaged.CommandManaged = true;
            ExerciseRuntime(commandManaged, enabled: true, running: true, shouldRestart: false);
        }

        static void ExerciseRuntime(Component definition, bool enabled, bool running, bool shouldRestart)
        {
            string home = Path.Combine(Path.GetTempPath(), "r1-stale-" + Guid.NewGuid().ToString("N"));
            var started = new DateTime(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc);
            var task = new ElevatedTask(home, definition.Name);
            if (running) task.Start();
            var runtime = new ComponentRuntime(definition, enabled, home, home, new Journal(home));
            runtime.Enabled = enabled; runtime.Alive = running;
            RuntimeField("started").SetValue(runtime, started);
            if (running) RuntimeField("elevated").SetValue(runtime, task);
            try {
                using (var bus = new EventBus(manualDispatch: true)) {
                    runtime.Bus = bus;
                    var events = new List<BusEvent>();
                    bus.Subscribe(BusTopics.ComponentStaleRestart, e => events.Add(e));
                    DateTime now = started;
                    using (TrayBusWiring.WireSupervisorTick(bus, () => runtime.CheckStale(now))) {
                        // Ожидаемого файла нет на ВСЕХ тиках, включая тики после остановки и назначения backoff.
                        for (int i = 0; i <= 13; i++) {
                            now = started.AddSeconds(i * 5);
                            bus.FireTick(BusTopics.Ticks.Supervisor); bus.DrainOnce();
                            Check(!File.Exists(Path.Combine(home, "status", "transport.json")), "status file remains absent");
                            Check(task.DisposeCalls == (shouldRestart && i >= 10 ? 1 : 0), "one termination after missing status ages");
                        }
                    }
                    Check(events.Count == (shouldRestart ? 1 : 0), "one stale-restart event or explicit skip");
                    if (shouldRestart) {
                        Check(!runtime.Alive && !runtime.Healthy && !task.Alive, "stale runtime stopped");
                        Check(RuntimeField("elevated").GetValue(runtime) == null, "stopped task released");
                        Check((DateTime)RuntimeField("next").GetValue(runtime) == started.AddSeconds(55), "restart scheduled with normal backoff");
                        Check((int)RuntimeField("delay").GetValue(runtime) == 10, "backoff advanced once");
                        Check(events[0].Get("name") == "transport", "restart names missing-status component");
                    } else {
                        Check((DateTime)RuntimeField("next").GetValue(runtime) == DateTime.MinValue, "skipped component has no scheduled restart");
                    }
                }
            } finally {
                runtime.Dispose();
                Directory.Delete(home, recursive: true);
            }
        }

        static void ClockJumpDoesNotKill()
        {
            var started = new DateTime(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc);
            var file = started.AddSeconds(10);
            var t = started.AddSeconds(15);
            int maxAge = 5; // fuse 30 s
            var c = new StaleChecker();
            // регулярные проверки раз в 5 с, статус свежий
            Check(c.Check(file, t, maxAge, started) == SupervisorDecision.None, "first check none");
            for (int i = 0; i < 3; i++) { t = t.AddSeconds(5); file = t; Check(c.Check(file, t, maxAge, started) == SupervisorDecision.None, "regular fresh " + i); }
            Check(!SupervisorStale.ClockJumped(DateTime.MinValue, t, 5), "first check is not a jump");
            // сон 3 ч: файл старый, но не убиваем
            var woke = t.AddHours(3);
            Check(SupervisorStale.ClockJumped(t, woke, maxAge), "gap > fuse/2 is a clock jump");
            Check(c.Check(file, woke, maxAge, started) == SupervisorDecision.None, "after sleep -> none");
            Check(c.AgeMs(file, woke, started) == 0, "age starts at resume");
            // +5 с и +10 с без записи — снова не убиваем (полный предохранитель от возобновления)
            Check(c.Check(file, woke.AddSeconds(5), maxAge, started) == SupervisorDecision.None, "+5s no write -> none");
            Check(c.Check(file, woke.AddSeconds(10), maxAge, started) == SupervisorDecision.None, "+10s no write -> none");
            for (int seconds = 15; seconds <= 30; seconds += 5)
                Check(c.Check(file, woke.AddSeconds(seconds), maxAge, started) == SupervisorDecision.None, "regular check after resume " + seconds);
            Check(c.AgeMs(file, woke.AddSeconds(30), started) == 30000, "regular ticks preserve resume origin");
            // превышение предохранителя без записи от возобновления — убийство
            Check(c.Check(file, woke.AddSeconds(35), maxAge, started) == SupervisorDecision.KillAndRestart, "fuse exceeded since resume -> kill");

            // запись файла после возобновления — не убиваем
            var c2 = new StaleChecker();
            c2.Check(file, t, maxAge, started);
            c2.Check(file, woke, maxAge, started);
            c2.Check(file, woke.AddSeconds(5), maxAge, started);
            var written = woke.AddSeconds(8);
            for (int seconds = 10; seconds <= 35; seconds += 5)
                Check(c2.Check(written, woke.AddSeconds(seconds), maxAge, started) == SupervisorDecision.None, "write after resume -> none " + seconds);
            Check(c2.Check(written, woke.AddSeconds(38), maxAge, started) == SupervisorDecision.None, "age from write 30 s -> none");
            Check(c2.Check(written, woke.AddSeconds(43), maxAge, started) == SupervisorDecision.KillAndRestart, "no further writes -> kill later");
        }

        static void BusyUiGapSkipsOnceThenWorks()
        {
            var started = new DateTime(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc);
            int maxAge = 5; // fuse 30 s, порог скачка > 15 s
            var file = started.AddSeconds(1);
            foreach (int gap in new[] { 16, 20 }) {
                var cc = new StaleChecker();
                var t0 = started.AddSeconds(5);
                cc.Check(file, t0, maxAge, started);
                var t1 = t0.AddSeconds(gap); // UI занят, тик пропущен
                Check(cc.Check(file, t1, maxAge, started) == SupervisorDecision.None, "gap " + gap + " skipped");
                Check(cc.Check(file, t1.AddSeconds(5), maxAge, started) == SupervisorDecision.None, "gap " + gap + " next regular none");
                for (int seconds = 10; seconds <= 30; seconds += 5)
                    Check(cc.Check(file, t1.AddSeconds(seconds), maxAge, started) == SupervisorDecision.None, "gap " + gap + " regular check " + seconds);
                Check(cc.Check(file, t1.AddSeconds(35), maxAge, started) == SupervisorDecision.KillAndRestart, "gap " + gap + " no permanent block, kill after fuse");
                var written = t1.AddSeconds(36);
                Check(cc.Check(written, t1.AddSeconds(40), maxAge, started) == SupervisorDecision.None, "gap " + gap + " fresh status restores normal work");
            }
        }

        static void SkippedStatusStillTracksResume()
        {
            var started = new DateTime(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc);
            var c = new StaleChecker();
            Check(c.Check(null, started, 5, started) == SupervisorDecision.None, "no status -> none");
            var woke = started.AddHours(3);
            Check(c.Check(null, woke, 5, started) == SupervisorDecision.None, "resume without status -> none");
            Check(c.AgeMs(null, woke, started) == 0, "resume remembered without status");
            for (int seconds = 5; seconds <= 30; seconds += 5)
                Check(c.Check(null, woke.AddSeconds(seconds), 5, started) == SupervisorDecision.None, "status still missing after resume " + seconds);
            Check(c.Check(null, woke.AddSeconds(35), 5, started) == SupervisorDecision.KillAndRestart, "missing status ages from resume and triggers recovery");
        }

        static void WireSupervisorTickAndEvent()
        {
            using (var bus = new EventBus(manualDispatch: true)) {
                var seen = new List<BusEvent>();
                bus.Subscribe("component.", e => seen.Add(e));
                int tickCount = 0;
                using (TrayBusWiring.WireSupervisorTick(bus, () => tickCount++)) {
                    bus.FireTick(BusTopics.Ticks.Supervisor);
                    bus.DrainOnce();
                    Check(tickCount == 1, "WireSupervisorTick receives tick.supervisor");
                }
                TrayBusWiring.ComponentStaleRestart(bus, "transport");
                TrayBusWiring.ComponentStaleRestart(null, "transport"); // null bus does not throw
                bus.DrainOnce();
                Check(seen.Count == 1, "stale-restart published");
                Check(seen[0].Topic == BusTopics.ComponentStaleRestart, "topic matches ComponentStaleRestart");
                Check(seen[0].Get("name") == "transport", "name parameter matches");
            }
        }
    }

    // Подмена только для portable harness: не обращается к COM/Task Scheduler и не запускает процессы.
    internal sealed class ElevatedTask : IDisposable
    {
        public bool Alive { get; private set; }
        public int DisposeCalls { get; private set; }
        public ElevatedTask(string home, string name) { }
        public void Start() { Alive = true; }
        public void Dispose() { DisposeCalls++; Alive = false; }
    }

}
