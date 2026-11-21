using System;
using System.Collections.Generic;
using System.IO;

namespace RemoteAgents.Launcher
{
    // Микро-тесты шага B2: ручная шина, без времени и без ожиданий.
    public static class TrayBusTests
    {
        static int assertions;
        static void Check(bool ok, string what) { if (!ok) throw new Exception("Assertion failed: " + what); assertions++; }

        public static int Main(string[] args)
        {
            Console.WriteLine("Starting TrayBusTests...");
            ComponentExitHasCode();
            StatusFileOkPublishesBlockReady();
            StaleStatusFileIgnored();
            TickGateOneDelivery();
            UpdateRequestedStartsCheck();
            ScheduleStartsOnTransportReady();
            Console.WriteLine("PASS: TrayBusTests (" + assertions + " assertions passed)");
            return 0;
        }

        static List<BusEvent> Collect(EventBus bus, string prefix)
        {
            var list = new List<BusEvent>(); bus.Subscribe(prefix, e => list.Add(e)); return list;
        }

        static void ComponentExitHasCode()
        {
            using (var bus = new EventBus(manualDispatch: true)) {
                var seen = Collect(bus, "component.");
                TrayBusWiring.ComponentStart(bus, "transport");
                TrayBusWiring.ComponentExit(bus, "transport", 75);
                TrayBusWiring.ComponentExit(null, "x", 1); // без шины — не падает
                bus.DrainOnce();
                Check(seen.Count == 2 && seen[0].Topic == BusTopics.ComponentStart && seen[0].Get("name") == "transport", "component.start carries name");
                Check(seen[1].Topic == BusTopics.ComponentExit && seen[1].Get("code") == "75" && seen[1].Get("name") == "transport", "component.exit carries code");
            }
        }

        static void StatusFileOkPublishesBlockReady()
        {
            string dir = Path.Combine(Path.GetTempPath(), "ra-traybus-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            try {
                using (var bus = new EventBus(manualDispatch: true)) {
                    var seen = Collect(bus, "block.");
                    var tracker = new BlockStatusTracker(bus, DateTime.MinValue);
                    string file = Path.Combine(dir, "transport.json");
                    File.WriteAllText(file, "{\"ok\":false}");
                    tracker.ScanFile(file); bus.DrainOnce();
                    Check(seen.Count == 0 && !tracker.IsBlockReady("transport"), "not ok at first sight publishes nothing");
                    File.WriteAllText(file, "{\"ok\":true,\"phase\":\"ok\"}");
                    tracker.ScanFile(file); tracker.ScanFile(file); bus.DrainOnce();
                    Check(seen.Count == 1 && seen[0].Topic == BusTopics.BlockReady && seen[0].Get("block") == "transport", "ok -> one block.ready");
                    File.WriteAllText(file, "{\"ok\":false,\"summary\":\"down\"}");
                    tracker.ScanFile(file); bus.DrainOnce();
                    Check(seen.Count == 2 && seen[1].Topic == BusTopics.BlockDegraded && seen[1].Get("reason") == "down", "ok -> not ok = block.degraded");
                    string vpn = Path.Combine(dir, "vpn.json");
                    File.WriteAllText(vpn, "{\"ok\":true,\"state\":\"starting\"}");
                    tracker.ScanFile(vpn); bus.DrainOnce();
                    Check(seen.Count == 2, "vpn is ready only in state on");
                    File.WriteAllText(Path.Combine(dir, "broken.json"), "{not json");
                    tracker.ScanFile(Path.Combine(dir, "broken.json")); tracker.ScanFile(Path.Combine(dir, "absent.json"));
                    Check(seen.Count == 2, "broken or absent file does not throw or publish");
                }
            } finally { try { Directory.Delete(dir, true); } catch { } }
        }

        static void StaleStatusFileIgnored()
        {
            string dir = Path.Combine(Path.GetTempPath(), "ra-traybus-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            try {
                var t0 = new DateTime(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc);
                var now = t0; var written = t0.AddMinutes(-10); // фальшивые часы и время файла
                using (var bus = new EventBus(manualDispatch: true)) {
                    var seen = Collect(bus, "block.");
                    var tracker = new BlockStatusTracker(bus, t0, () => now, p => written);
                    string file = Path.Combine(dir, "transport.json");
                    File.WriteAllText(file, "{\"ok\":true}");
                    tracker.ScanFile(file); bus.DrainOnce();
                    Check(seen.Count == 0 && !tracker.IsBlockReady("transport"), "stale file from a previous run gives no block.ready");
                    written = t0.AddSeconds(1);
                    tracker.ScanFile(file); bus.DrainOnce();
                    Check(seen.Count == 1 && seen[0].Topic == BusTopics.BlockReady, "fresh file gives block.ready");
                    now = t0.AddMinutes(5);
                    TrayBusWiring.ComponentExit(bus, "transport", 1); bus.DrainOnce();
                    Check(!tracker.IsBlockReady("transport"), "component.exit resets block state");
                    tracker.ScanFile(file); bus.DrainOnce();
                    Check(seen.Count == 1, "file older than the exit is stale again");
                    written = now.AddSeconds(1); tracker.ScanFile(file); bus.DrainOnce();
                    Check(seen.Count == 2 && seen[1].Topic == BusTopics.BlockReady, "file written after restart gives block.ready again");
                    now = t0.AddMinutes(9); TrayBusWiring.ComponentStart(bus, "transport"); bus.DrainOnce();
                    Check(!tracker.IsBlockReady("transport"), "component.start resets block state");
                }
            } finally { try { Directory.Delete(dir, true); } catch { } }
        }

        static void TickGateOneDelivery()
        {
            var gate = new TickGate(); var queue = new List<Action>(); int worked = 0;
            Func<Action, bool> post = a => { queue.Add(a); return true; };
            Check(gate.Deliver(post, () => worked++), "first tick is delivered");
            for (int i = 0; i < 5; i++) Check(!gate.Deliver(post, () => worked++), "busy UI: tick dropped");
            Check(queue.Count == 1 && gate.Pending, "N ticks while busy -> one delivery");
            queue[0](); Check(worked == 1 && !gate.Pending, "delivery ran and released");
            Check(gate.Deliver(post, () => worked++) && queue.Count == 2, "after completion one delivery again");
            queue[1]();
            Func<Action, bool> failing = a => false;
            Check(!gate.Deliver(failing, () => worked++) && !gate.Pending, "failed post resets the pending flag");
            Func<Action, bool> throwing = a => { throw new InvalidOperationException(); };
            try { gate.Deliver(throwing, () => worked++); } catch (InvalidOperationException) { }
            Check(!gate.Pending, "throwing post resets the pending flag");
            Check(gate.Deliver(post, () => worked++), "tick is not dead after a failed post");
        }

        static void UpdateRequestedStartsCheck()
        {
            using (var bus = new EventBus(manualDispatch: true)) {
                int calls = 0; bool manual = false;
                using (TrayBusWiring.WireUpdateRequests(bus, m => { calls++; manual = m; })) {
                    bus.Publish(BusTopics.UpdateRequested, BusTopics.Sources.Tray, "reason", "button");
                    bus.DrainOnce();
                }
                Check(calls == 1 && manual, "update.requested calls StartUpdateCheck(manual)");
                int scheduled = 0;
                using (TrayBusWiring.WireUpdateTick(bus, () => scheduled++)) { bus.FireTick(BusTopics.Ticks.Update); bus.DrainOnce(); }
                Check(scheduled == 1, "tick.update calls the scheduled check");
            }
        }

        static void ScheduleStartsOnTransportReady()
        {
            using (var bus = new EventBus(manualDispatch: true)) {
                var schedule = new NetSchedule(0); int ready = 0;
                using (TrayBusWiring.WireTransportReady(bus, () => { ready++; schedule.TransportReady(5); })) {
                    Check(schedule.Due(0, false) == 0, "no run before block.ready transport");
                    bus.Publish(BusTopics.BlockReady, BusTopics.Sources.Tray, "block", "vpn"); bus.DrainOnce();
                    Check(ready == 0, "other block does not start the schedule");
                    bus.Publish(BusTopics.BlockReady, BusTopics.Sources.Tray, "block", "transport"); bus.DrainOnce();
                    Check(ready == 1 && schedule.Due(5, false) == NetLadder.Quick, "block.ready transport starts the first run");
                }
            }
        }
    }
}
