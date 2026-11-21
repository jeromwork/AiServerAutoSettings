using System;
using System.Collections.Generic;

namespace RemoteAgents.Launcher
{
    // Микро-тесты шага V4: ручная шина (DrainOnce), без времени и ожиданий.
    public static class VpnReasonsTests
    {
        static int assertions;
        static void Check(bool ok, string what) { if (!ok) throw new Exception("Assertion failed: " + what); assertions++; }

        public static int Main(string[] args)
        {
            Console.WriteLine("Starting VpnReasonsTests...");
            TransportFailDuringAttemptRollsBackOnce();
            E2eFailRollsBack();
            E2eStage9AndOkDoNothing();
            DiskFailureRollsBack();
            StaleAttemptAndNoAttemptIgnored();
            VpnStateOnStartsE2eOnce();
            ReasonTextsEverywhere();
            Console.WriteLine("PASS: VpnReasonsTests (" + assertions + " assertions passed)");
            return 0;
        }

        sealed class Rig : IDisposable
        {
            internal readonly EventBus Bus = new EventBus(manualDispatch: true);
            internal readonly List<string> E2E = new List<string>(), Rollbacks = new List<string>(), Notes = new List<string>(), Log = new List<string>();
            internal readonly VpnAttemptGuard Guard;
            internal Rig()
            {
                Guard = new VpnAttemptGuard(Bus, a => E2E.Add(a), (a, st, r, d) => Rollbacks.Add(a + "|" + st + "|" + r), (e, kv) => Log.Add(e), t => Notes.Add(t));
            }
            internal void Pub(string topic, params string[] kv) { Bus.Publish(topic, BusTopics.Sources.Tray, kv); Bus.DrainOnce(); }
            public void Dispose() { Guard.Dispose(); Bus.Dispose(); }
        }

        static void TransportFailDuringAttemptRollsBackOnce()
        {
            using (var r = new Rig()) {
                r.Pub(BusTopics.TransportStatus, "ok", "false"); // вне попытки — ничего
                Check(r.Rollbacks.Count == 0, "transport fail without attempt is ignored");
                r.Guard.Begin("a1");
                r.Pub(BusTopics.TransportStatus, "ok", "true");
                Check(r.Rollbacks.Count == 0, "transport ok is not a failure");
                r.Pub(BusTopics.TransportStatus, "ok", "false");
                r.Pub(BusTopics.TransportStatus, "ok", "false");
                r.Pub(BusTopics.BlockDegraded, "block", "transport");
                Check(r.Rollbacks.Count == 1 && r.Rollbacks[0] == "a1|0|broke-transport", "transport.status fail -> one rollback broke-transport");
                Check(r.Notes.Count == 1 && r.Notes[0].Contains("транспорт"), "owner note in plain words");
                Check(r.Log.Contains("vpn.rollback") && r.Log.Contains("vpn.rollback.ignored") == false, "rollback logged; no attempt left for repeats");
            }
        }

        static void E2eFailRollsBack()
        {
            using (var r = new Rig()) {
                r.Guard.Begin("a2");
                r.Pub(BusTopics.NetE2E, "att", "a2", "result", "fail", "stage", "7", "reason", "dns", "detail", "timeout");
                r.Pub(BusTopics.NetE2E, "att", "a2", "result", "fail", "stage", "8", "reason", "http");
                Check(r.Rollbacks.Count == 1 && r.Rollbacks[0] == "a2|7|e2e-fail", "e2e fail stage 7 -> one rollback e2e-fail");
                Check(r.Notes[0].Contains("интернет через него не шёл") && r.Notes[0].Contains("timeout"), "note names the detail");
                r.Guard.Begin("a3");
                r.Pub(BusTopics.NetE2E, "att", "a3", "result", "fail", "stage", "6", "reason", "routes-not-ours");
                Check(r.Rollbacks.Count == 2 && r.Rollbacks[1] == "a3|6|routes-not-ours", "stage 6 routes-not-ours keeps its code");
            }
        }

        static void E2eStage9AndOkDoNothing()
        {
            using (var r = new Rig()) {
                r.Guard.Begin("a4");
                r.Pub(BusTopics.NetE2E, "att", "a4", "result", "ok", "stage", "0");
                r.Pub(BusTopics.TransportStatus, "ok", "false");
                Check(r.Rollbacks.Count == 0 && !r.Guard.Active, "success: nothing, attempt closed, later transport fail is not ours");
                r.Guard.Begin("a5");
                r.Pub(BusTopics.NetE2E, "att", "a5", "result", "fail", "stage", "9", "reason", "egress");
                r.Guard.Begin("a6");
                r.Pub(BusTopics.NetE2E, "att", "a6", "result", "skipped", "stage", "0", "reason", "busy");
                Check(r.Rollbacks.Count == 0, "stage 9 and skipped never roll back");
            }
        }

        static void DiskFailureRollsBack()
        {
            using (var r = new Rig()) {
                r.Guard.Begin("a7");
                r.Pub(BusTopics.BlockDegraded, "block", "disk"); // degraded диска — не повод
                Check(r.Rollbacks.Count == 0, "disk degraded is not a rollback");
                r.Pub(BusTopics.BlockFailed, "block", "disk", "reason", "x");
                Check(r.Rollbacks.Count == 1 && r.Rollbacks[0] == "a7|0|broke-disk", "block.failed disk -> rollback broke-disk");
            }
        }

        static void StaleAttemptAndNoAttemptIgnored()
        {
            using (var r = new Rig()) {
                r.Pub(BusTopics.NetE2E, "att", "zz", "result", "fail", "stage", "7");
                r.Guard.Begin("b1");
                r.Pub(BusTopics.NetE2E, "att", "old", "result", "fail", "stage", "7");
                Check(r.Rollbacks.Count == 0 && r.Guard.Active, "e2e of another attempt is ignored");
                r.Pub(BusTopics.VpnState, "state", "error", "reason", "core-not-ready");
                Check(r.Rollbacks.Count == 0 && !r.Guard.Active && r.Notes.Count == 1 && r.Notes[0] == "Ядро VPN не подтвердило запуск", "failed state ends attempt with plain reason");
            }
        }

        static void VpnStateOnStartsE2eOnce()
        {
            using (var r = new Rig()) {
                r.Guard.Begin("c1");
                r.Pub(BusTopics.VpnState, "state", "starting");
                Check(r.E2E.Count == 0, "starting does not start e2e");
                r.Pub(BusTopics.VpnState, "state", "on");
                r.Guard.VpnOn("c1"); // ответ vpn.on.ok пришёл следом
                r.Pub(BusTopics.VpnState, "state", "on");
                Check(r.E2E.Count == 1 && r.E2E[0] == "c1", "e2e starts once per attempt");
            }
        }

        static void ReasonTextsEverywhere()
        {
            foreach (var code in new[] { "core-not-ready", "routes-not-ours", "e2e-fail", "broke-transport", "broke-disk", "broke-bridge" }) {
                Check(VpnReasons.Text(code).Length > 0, "text for " + code);
                Check(VpnWatchdog.FailureSummary(code).Length > 0, "FailureSummary state " + code);
                Check(VpnWatchdog.FailureSummary("error", code) == VpnReasons.Text(code), "FailureSummary error/stage " + code);
            }
            Check(VpnWatchdog.FailureSummary("error", "config-check").Contains("config-check"), "other error stages unchanged");
            Check(VpnReasons.Text("nope").Length == 0, "unknown code has no text");
        }
    }
}
