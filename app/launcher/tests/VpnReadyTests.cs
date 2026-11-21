using System;
using System.Collections.Generic;
using System.Net;

namespace RemoteAgents.Launcher
{
    // Микро-тесты V3: ворота готовности ядра и маршрута. События подаются вручную (EventBus manualDispatch + DrainOnce),
    // часов и ожиданий нет; предохранитель — ручной сигнал-делегат.
    internal static class VpnReadyTests
    {
        static int count;
        static void Check(bool ok, string name) { if (!ok) throw new Exception("VpnReady: " + name); count++; }
        static readonly Func<bool> No = () => false, Yes = () => true;
        static void Nop() { }

        static VpnGateOutcome Core(Action<EventBus> feed, Func<bool> exited, Func<bool> cancelled, Func<bool> fuse, out VpnReadyGate gate)
        {
            var bus = new EventBus(true);
            gate = new VpnReadyGate(bus);
            feed(bus); bus.DrainOnce();
            return gate.AwaitCore(exited, cancelled, Nop, fuse, 1);
        }

        internal static void Run()
        {
            VpnReadyGate g;
            Check(Core(b => b.Publish(BusTopics.SingboxStarted, BusTopics.Sources.VpnCore, "core", "vpn", "line", "INFO sing-box started (0.5s)"), No, No, No, out g) == VpnGateOutcome.Ready, "started core=vpn -> Ready");
            Check(g.ReadyLine.Contains("sing-box started"), "ready line kept");
            Check(Core(b => b.Publish(BusTopics.SingboxStarted, BusTopics.Sources.VpnCore, "core", "transport", "line", "x"), No, No, Yes, out g) == VpnGateOutcome.Fuse, "started of another core is not readiness (only fuse ends it)");
            Check(Core(b => { }, No, No, Yes, out g) == VpnGateOutcome.Fuse, "no events -> fuse, success is not declared");
            Check(Core(b => { b.Publish(BusTopics.SingboxStarted, BusTopics.Sources.VpnCore, "core", "vpn", "line", "s"); b.Publish(BusTopics.SingboxFatal, BusTopics.Sources.VpnCore, "core", "vpn", "line", "FATAL boom"); }, No, No, No, out g) == VpnGateOutcome.Fatal, "fatal wins over started");
            Check(g.FatalLine == "FATAL boom", "fatal line kept");
            Check(Core(b => b.Publish(BusTopics.SingboxFatal, BusTopics.Sources.VpnCore, "core", "transport", "line", "FATAL"), No, No, Yes, out g) == VpnGateOutcome.Fuse, "fatal of another core ignored");
            Check(Core(b => { }, Yes, No, No, out g) == VpnGateOutcome.CoreExited, "process exit -> CoreExited");
            Check(Core(b => b.Publish(BusTopics.VpnOff, BusTopics.Sources.Helper, "reason", "button"), No, No, No, out g) == VpnGateOutcome.Off, "vpn.off -> Off");
            Check(g.OffReason == "button", "off reason kept");
            Check(Core(b => { }, No, Yes, No, out g) == VpnGateOutcome.Off, "cancelled generation -> Off");
            Check(Core(b => b.Publish(BusTopics.SingboxStarted, BusTopics.Sources.VpnCore, "core", "vpn", "line", "s"), No, Yes, No, out g) == VpnGateOutcome.Off, "off has priority over ready");
            g.Dispose();

            // Маршрут: ProbeRoute на подставных функциях.
            var probe = IPAddress.Parse("198.18.0.1");
            Func<IPAddress, int> bestTun = a => 7, bestOther = a => a.ToString() == "1.1.1.1" ? 7 : 3;
            Func<string, int> index = n => 7; Func<int, string> name = i => i == 7 ? "RemoteAgents-VPN" : "Ethernet";
            Check(VpnReadyGate.ProbeRoute(bestTun, index, name, probe, "RemoteAgents-VPN").Ok, "both routes on TUN -> ok");
            var bad = VpnReadyGate.ProbeRoute(bestOther, index, name, probe, "RemoteAgents-VPN");
            Check(!bad.Ok && bad.BestProbeName == "Ethernet" && bad.Fields()[5] == "3:Ethernet", "probe route off TUN -> fail with names");
            Check(!VpnReadyGate.ProbeRoute(bestTun, n => -1, name, probe, "RemoteAgents-VPN").Ok, "no TUN adapter -> fail");

            var bus2 = new EventBus(true);
            using (var rg = new VpnReadyGate(bus2)) {
                int calls = 0; VpnRouteResult last;
                Func<VpnRouteResult> okNow = () => { calls++; return VpnReadyGate.ProbeRoute(bestTun, index, name, probe, "x"); };
                Check(rg.AwaitRoute(okNow, No, Nop, No, out last, 1) == VpnGateOutcome.RoutesOk && calls == 1 && last.Ok, "route ok on first probe, no re-probe");
                calls = 0;
                Func<VpnRouteResult> okSecond = () => { calls++; return VpnReadyGate.ProbeRoute(calls >= 2 ? bestTun : bestOther, index, name, probe, "x"); };
                bus2.Publish(BusTopics.WinRouteChanged, BusTopics.Sources.Windows, "family", "ipv4", "ifIndex", "7"); bus2.DrainOnce();
                Check(rg.AwaitRoute(okSecond, No, Nop, Yes, out last, 1) == VpnGateOutcome.RoutesOk && calls == 2, "win.route.changed triggers the re-probe (fuse already true, not consulted before the event)");
                calls = 0;
                Check(rg.AwaitRoute(() => { calls++; return VpnReadyGate.ProbeRoute(bestOther, index, name, probe, "x"); }, No, Nop, Yes, out last, 1) == VpnGateOutcome.RoutesFuse && calls == 1 && !last.Ok, "no event: one probe, then fuse -> fail");
                Check(rg.AwaitRoute(okNow, Yes, Nop, No, out last, 1) == VpnGateOutcome.Off && last == null, "cancelled before the probe -> Off");
            }
            Console.WriteLine("VpnReadyTests: PASS " + count + " checks");
        }
    }
}
