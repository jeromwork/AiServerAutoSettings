using System;
using System.Collections.Generic;

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
            ClockJumpDoesNotKill();
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

        static void ClockJumpDoesNotKill()
        {
            var started = new DateTime(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc);
            var file = started.AddSeconds(10);
            var last = started.AddSeconds(15);
            var afterSleep = started.AddHours(3);
            Check(SupervisorStale.ClockJumped(last, afterSleep, 5), "gap > fuse/2 is a clock jump");
            Check(SupervisorStale.Decide(file, afterSleep, 5, started, last) == SupervisorDecision.None, "after sleep -> only resync");
            Check(SupervisorStale.Decide(file, afterSleep, 5, started, afterSleep.AddSeconds(-5)) == SupervisorDecision.KillAndRestart, "regular cadence, stale -> kill");
            Check(!SupervisorStale.ClockJumped(DateTime.MinValue, afterSleep, 5), "first check is not a jump");
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
}
