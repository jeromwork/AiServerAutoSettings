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
            TwoSignalsOneRollback();
            ButtonOffMakesE2eStale();
            BridgeFailureRollsBack();
            RollbackBeforeVpnOnBlocksE2e();
            SnapshotOffDoesNotEndAttempt();
            ReasonTextsEverywhere();
            OpCounterReleasesOnlyOnLast();
            HelperRoutesCodeRollsBackAsRoutes();
            RolledBackSnapshotMustPrecedeEnd();
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
                Check(r.Log.Contains("vpn.rollback") && r.Log.Contains("vpn.rollback.ignored"), "rollback logged; repeats logged as ignored");
            }
        }

        static void E2eFailRollsBack()
        {
            using (var r = new Rig()) {
                r.Guard.Begin("a2");
                r.Pub(BusTopics.NetE2E, "att", "a2", "result", "fail", "stage", "7", "reason", "dns", "detail", "timeout");
                r.Pub(BusTopics.NetE2E, "att", "a2", "result", "fail", "stage", "8", "reason", "http");
                Check(r.Rollbacks.Count == 1 && r.Rollbacks[0] == "a2|7|e2e-fail", "e2e fail stage 7 -> one rollback e2e-fail");
                Check(r.Notes[0].Contains("интернет через него не шёл") && r.Notes[0].Contains("не определяются адреса сайтов") && !r.Notes[0].Contains("timeout"), "note in plain words, no raw detail");
                r.Guard.Begin("a3");
                r.Pub(BusTopics.NetE2E, "att", "a3", "result", "fail", "stage", "6", "reason", "route-not-ours");
                Check(r.Rollbacks.Count == 2 && r.Rollbacks[1] == "a3|6|route-not-ours", "stage 6 route-not-ours keeps its code");
                Check(r.Notes[1].Contains("трафик идёт мимо VPN"), "stage 6 plain words");
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

        static void TwoSignalsOneRollback()
        {
            using (var r = new Rig()) {
                r.Guard.Begin("d1");
                r.Pub(BusTopics.NetE2E, "att", "d1", "result", "fail", "stage", "7", "reason", "dns");
                r.Pub(BusTopics.BlockFailed, "block", "disk");
                r.Pub(BusTopics.BlockDegraded, "block", "transport");
                Check(r.Rollbacks.Count == 1 && r.Rollbacks[0] == "d1|7|e2e-fail", "two signals of one attempt -> one rollback");
                Check(r.Log.Contains("vpn.rollback.ignored"), "repeat signal logged as ignored");
            }
        }

        static void ButtonOffMakesE2eStale()
        {
            using (var r = new Rig()) {
                r.Guard.Begin("e1");
                r.Guard.EndCurrent("button-off"); // DisableVpn закрывает попытку явно
                r.Pub(BusTopics.NetE2E, "att", "e1", "result", "fail", "stage", "7");
                Check(r.Rollbacks.Count == 0, "e2e after button off does not roll back");
                Check(r.Log.Contains("vpn.attempt.e2e-stale"), "late e2e logged as stale");
            }
        }

        static void RollbackBeforeVpnOnBlocksE2e()
        {
            using (var r = new Rig()) {
                r.Guard.Begin("g1");
                r.Pub(BusTopics.BlockDegraded, "block", "transport", "reason", "x");
                r.Guard.VpnOn("g1"); // помощник ответил on уже после отката
                Check(r.E2E.Count == 0, "e2e does not start after rollback");
                Check(r.Rollbacks.Count == 1 && r.Rollbacks[0] == "g1|0|broke-transport", "exactly one rollback");
                Check(r.Guard.RolledBack("g1") && !r.Guard.RolledBack("other"), "RolledBack tells CheckVpn not to write intent=true");
                r.Pub(BusTopics.BlockDegraded, "block", "transport");
                Check(r.Rollbacks.Count == 1, "late degraded after rollback does not roll back again");
            }
        }

        static void SnapshotOffDoesNotEndAttempt()
        {
            using (var r = new Rig()) {
                r.Guard.Begin("h1");
                r.Pub(BusTopics.VpnState, "state", "off", "reason", "helper-start");
                Check(r.Guard.Active, "snapshot off at helper connect keeps the attempt");
                r.Guard.VpnOn("h1");
                Check(r.E2E.Count == 1 && r.E2E[0] == "h1", "e2e starts once after snapshot off");
            }
        }

        static void BridgeFailureRollsBack()
        {
            using (var r = new Rig()) {
                r.Guard.Begin("f1");
                r.Pub(BusTopics.BlockFailed, "block", "control");
                Check(r.Rollbacks.Count == 1 && r.Rollbacks[0] == "f1|0|broke-bridge", "block.failed control -> broke-bridge, one rollback");
            }
        }

        static void RolledBackSnapshotMustPrecedeEnd()
        {
            using (var r = new Rig()) {
                r.Guard.Begin("s1");
                r.Pub(BusTopics.BlockDegraded, "block", "transport", "reason", "x");
                Check(r.Guard.RolledBack("s1"), "rolled back before End");
                bool snapshot = r.Guard.RolledBack("s1");
                r.Guard.End("s1", "error");
                Check(!r.Guard.RolledBack("s1"), "End clears the attempt: RolledBack is false afterwards, so the snapshot must be taken first");
                Check(!VpnAttemptGuard.ShowFailureWindow(snapshot), "after rollback no failure window");
                Check(VpnAttemptGuard.ShowFailureWindow(false), "no rollback: failure window shown");
            }
        }

        static void OpCounterReleasesOnlyOnLast()
        {
            var c = new VpnOpCounter();
            c.Enter(); c.Enter(); // включение (ждёт ответа) + откат
            Check(!c.Exit() && c.Running == 1, "rollback end keeps busy while enable still waits");
            Check(c.Exit() && c.Running == 0, "last op end releases busy");
            c.Enter(); Check(c.Exit(), "single op releases");
            Check(c.Exit() && c.Running == 0, "extra exit does not go negative");
        }

        static void HelperRoutesCodeRollsBackAsRoutes()
        {
            using (var r = new Rig()) {
                r.Guard.Begin("h1");
                r.Pub(BusTopics.NetE2E, "att", "h1", "result", "fail", "stage", "6", "reason", "routes-not-ours");
                Check(r.Rollbacks.Count == 1 && r.Rollbacks[0] == "h1|6|route-not-ours", "helper plural code maps to ladder code");
                Check(VpnReasons.IsRoutesNotOurs("routes-not-ours") && VpnReasons.IsRoutesNotOurs("route-not-ours") && !VpnReasons.IsRoutesNotOurs("e2e-fail"), "both codes accepted");
            }
        }

        static void ReasonTextsEverywhere()
        {
            foreach (var code in new[] { "core-not-ready", "route-not-ours", "routes-not-ours", "e2e-fail", "broke-transport", "broke-disk", "broke-bridge" }) {
                Check(VpnReasons.Text(code).Length > 0, "text for " + code);
                Check(VpnWatchdog.FailureSummary(code).Length > 0, "FailureSummary state " + code);
                Check(VpnWatchdog.FailureSummary("error", code) == VpnReasons.Text(code), "FailureSummary error/stage " + code);
            }
            Check(VpnWatchdog.FailureSummary("error", "config-check").Contains("config-check"), "other error stages unchanged");
            Check(VpnReasons.Text("nope").Length == 0, "unknown code has no text");
        }
    }
}
