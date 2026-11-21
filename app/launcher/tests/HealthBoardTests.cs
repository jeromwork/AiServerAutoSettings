using System;
using System.Collections.Generic;
using System.Linq;

namespace RemoteAgents.Launcher
{
    // Микро-тесты шага H1: чистая логика доски готовности, ручные события, без времени и ожиданий.
    public static class HealthBoardTests
    {
        static int assertions;
        static void Check(bool ok, string what) { if (!ok) throw new Exception("Assertion failed: " + what); assertions++; }
        static readonly DateTime T0 = new DateTime(2026, 11, 21, 0, 0, 0, DateTimeKind.Utc);

        public static int Main(string[] args)
        {
            Console.WriteLine("Starting HealthBoardTests...");
            LastReporterAccepts();
            DegradedNoNetworkCounts();
            IncompleteSetNotAccepted();
            RepeatsDoNotDuplicateAccepted();
            OtherDegradedUnreports();
            BridgeAliasAndOutsiders();
            ExpectedBlocksFromState();
            Console.WriteLine("PASS: HealthBoardTests (" + assertions + " assertions passed)");
            return 0;
        }

        static HealthBoard Board() { return new HealthBoard(new[] { "tray", "transport", "disk", "vpn", "bridge" }, T0); }

        static void LastReporterAccepts()
        {
            var b = Board();
            Check(!b.Ready("tray", T0).Completed && !b.Ready("transport", T0).Completed, "first two do not complete");
            Check(!b.Ready("disk", T0).Completed && !b.Ready("vpn", T0).Completed, "four of five do not complete");
            Check(!b.Accepted, "not accepted before last");
            var last = b.Ready("control", T0);
            Check(last.Counted && last.Completed && b.Accepted && b.Missing.Length == 0, "last reporter completes the set");
        }

        static void DegradedNoNetworkCounts()
        {
            var b = new HealthBoard(new[] { "tray", "transport" }, T0);
            b.Ready("tray", T0);
            var r = b.Degraded("transport", "no-network", T0);
            Check(r.Counted && r.Completed && b.Accepted, "no-network degraded counts as a report");
        }

        static void IncompleteSetNotAccepted()
        {
            var b = Board();
            b.Ready("tray", T0); b.Ready("transport", T0); b.Ready("vpn", T0);
            Check(!b.Accepted, "incomplete set is not accepted");
            Check(string.Join(",", b.Missing) == "control,disk", "missing blocks listed: " + string.Join(",", b.Missing));
            Check(!b.Degraded("disk", "connection lost", T0).Counted, "other degraded reason does not count");
            Check(!b.Accepted, "still not accepted");
        }

        static void RepeatsDoNotDuplicateAccepted()
        {
            var b = new HealthBoard(new[] { "tray", "transport" }, T0);
            Check(!b.Ready("tray", T0).Completed, "tray alone");
            Check(!b.Ready("tray", T0).Completed, "repeat of tray does not complete");
            Check(b.Ready("transport", T0).Completed, "completed once");
            Check(!b.Ready("transport", T0).Completed && !b.Ready("tray", T0).Completed, "repeats after accepted do not complete again");
            Check(!b.Degraded("tray", "no-network", T0).Completed, "degraded after accepted does not complete again");
            Check(b.Accepted, "stays accepted");
        }

        static void OtherDegradedUnreports()
        {
            var b = new HealthBoard(new[] { "tray", "transport" }, T0);
            b.Ready("tray", T0); b.Degraded("tray", "not-ok", T0);
            Check(!b.Ready("transport", T0).Completed, "tray was unreported by degraded");
            Check(b.Ready("tray", T0).Completed, "tray reported again completes");
        }

        static void BridgeAliasAndOutsiders()
        {
            var b = new HealthBoard(new[] { "tray", "bridge" }, T0);
            Check(!b.Ready("update", T0).Counted, "block outside the set is ignored");
            b.Ready("tray", T0);
            Check(b.Ready("control", T0).Completed, "control is the bridge block");
        }

        static void ExpectedBlocksFromState()
        {
            var none = HealthBoard.ExpectedBlocks(new Dictionary<string, object>());
            Check(string.Join(",", none) == "tray,transport", "always tray and transport: " + string.Join(",", none));
            var state = new Dictionary<string, object> { { "runningComponents", new List<object> { "disk", "bridge", "disk" } }, { "vpnOn", true } };
            var set = HealthBoard.ExpectedBlocks(state);
            Check(string.Join(",", set.OrderBy(x => x, StringComparer.Ordinal)) == "control,disk,transport,tray,vpn", "components, bridge alias, vpn and no duplicates: " + string.Join(",", set));
            state["vpnOn"] = false;
            Check(!HealthBoard.ExpectedBlocks(state).Contains("vpn"), "vpn only when it was on");
        }
    }
}
