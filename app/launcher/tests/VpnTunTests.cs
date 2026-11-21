using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;

namespace RemoteAgents.Launcher
{
    internal static class VpnTunTests
    {
        static int count;
        static readonly DateTime ProcessStarted = new DateTime(2026, 11, 20, 12, 0, 0, DateTimeKind.Utc);
        static bool FakeDaemonAlive(int pid, DateTime started) { return pid == 42 && VpnWatchdog.ProcessStartMatches(ProcessStarted, started); }
#if PORTABLE_TEST
        // Focused executable: the default runs every VpnTun check, without unrelated suites.
        static int Main(string[] args)
        {
            if (args.Length == 1 && args[0] == "--vpn-route-watch-only") { RouteWatchChecks(); return 0; }
            if (args.Length == 1 && args[0] == "--vpn-scan-events-only") { ScanEventChecks(); NetHelperVersionTests.Run(); return 0; }
            string root = Path.Combine(Path.GetTempPath(), "vpn-tun-tests-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            try {
                if (args.Length == 1 && args[0] == "--vpn-status-only") StatusChecks(root);
                else if (args.Length == 0) Run(root);
                else throw new ArgumentException("Expected no arguments or --vpn-status-only");
            } finally { Directory.Delete(root, true); }
            return 0;
        }
#endif
        static void Check(bool value, string name) { if (!value) throw new Exception("VpnTun: " + name); count++; }
        static Dictionary<string, object> D(params object[] values) { return VpnTun.D(values); }
        static Dictionary<string, object> Snapshot(string name, string description, params string[] routes)
        {
            return D("Adapters", new[] { D("Name", name, "InterfaceDescription", description, "ifIndex", 7, "Status", "Up", "Virtual", true) },
                "Routes", routes.Select(r => D("InterfaceIndex", 7, "DestinationPrefix", r)).ToArray(), "DnsServers", new object[0], "DnsClients", new object[0], "Nrpt", new object[0]);
        }
        static void MonitorChecks(DateTime now, Dictionary<string, object> transport, Dictionary<string, object> policy)
        {
            int stops = 0, restarts = 0; string stopped = "";
            Dictionary<string, object> status = null;
            var monitor = new VpnTunMonitor(0, transport, policy, value => status = value, reason => { stops++; stopped = reason; }, () => restarts++, processAlive: FakeDaemonAlive);
            Check(monitor.Step(0, now, true, transport, "") && Json.Str(status, "state") == "on", "running TUN starts healthy");
            transport["ok"] = false;
            transport["reason"] = D("code", "all-paths-penalized", "text", "Все пути временно недоступны, повторяю");
            for (int ms = 500; ms <= 120000; ms += 500) Check(monitor.Step(ms, now.AddMilliseconds(ms), true, transport, ""), "unavailable path never stops the loop");
            string since = Json.Str(Json.Map(status["reason"]), "since");
            Check(stops == 0 && restarts == 0 && Json.Bool(status, "enabled") && !Json.Bool(status, "ok") && Json.Str(status, "state") == "searching", "two minutes without path keeps the same TUN Job, without ten second auto retry");
            Check(Json.Str(Json.Map(status["reason"]), "code") == "all-paths-penalized" && since == now.AddMilliseconds(500).ToString("o"), "contract reason and stable since survive waiting");
            transport["localNet"] = "down";
            monitor.Step(120500, now.AddMilliseconds(120500), true, transport, "");
            Check(stops == 0 && Json.Str(Json.Map(status["reason"]), "code") == "local-network-down", "local network outage reports searching without Stop");
            transport["ok"] = true; transport["localNet"] = "ok"; transport["reason"] = D();
            transport["updatedAt"] = now.AddMilliseconds(121000).ToString("o");
            monitor.Step(121000, now.AddMilliseconds(121000), true, transport, "");
            Check(Json.Bool(status, "ok") && Json.Bool(status, "enabled") && Json.Str(status, "state") == "on" && stops == 0 && restarts == 0, "ok to searching to ok retains the same Job");
            Json.Map(transport["helper"])["udp"] = false;
            monitor.Step(121500, now.AddMilliseconds(121500), true, transport, "");
            Check(Json.Str(status, "state") == "searching" && Json.Str(Json.Map(status["reason"]), "code") == "no-udp" && stops == 0, "loss of UDP is status only");
            Json.Map(transport["helper"])["udp"] = true;
            transport["configRevision"] = "new"; transport["network"] = "new-network";
            monitor.Step(122000, now.AddMilliseconds(122000), true, transport, "");
            Check(Json.Str(Json.Map(status["reason"]), "code") == "path-changed" && stops == 0, "revision and network change cannot close the Job");
            monitor.Step(122500, now.AddMilliseconds(122500), true, transport, "");
            Check(Json.Str(status, "state") == "on", "new ready path resumes without restart");
            var conflict = VpnTun.Conflict(Snapshot("Happ TUN", "Wintun", "0.0.0.0/0"));
            monitor.Step(123000, now.AddMilliseconds(123000), true, transport, conflict);
            Check(Json.Str(status, "state") == "conflict" && Json.Bool(status, "enabled") && Json.Str(status, "summary").Contains("Сейчас работает Happ TUN. Отключите его") && stops == 0 && restarts == 0, "foreign VPN appearing after enable is visible without closing or restarting our core");
            transport["updatedAt"] = now.AddMilliseconds(123500).ToString("o");
            monitor.Step(123500, now.AddMilliseconds(123500), true, transport, "");
            Check(Json.Str(status, "state") == "on", "removing conflict resumes in place");
            monitor.Step(124000, now.AddMilliseconds(124000), true, transport, "", true);
            Check(Json.Str(status, "state") == "searching" && stops == 0, "inventory failure cannot close a healthy core");
            monitor.Step(124500, now.AddMilliseconds(124500), false, transport, "");
            monitor.Step(124550, now.AddMilliseconds(124550), false, transport, "");
            Check(Json.Str(status, "state") == "searching" && Json.Bool(status, "enabled") && restarts == 1 && stops == 0, "core exit restarts inside Job, repeated exits are rate limited");
            monitor.Step(124600, now.AddMilliseconds(124600), true, transport, "");
            Check(Json.Str(status, "state") == "on", "restarted core returns to on");
            Check(!monitor.Step(127101, now.AddMilliseconds(127101), true, transport, "") && stops == 1 && stopped == "watchdog-stalled", "owner-loop hang still invokes Stop");
            transport["ok"] = false; transport["reason"] = D("code", "path-dial-failed", "text", "password=private-value");
            var masked = new VpnTunMonitor(0, transport, policy, value => status = value, reason => stops++, () => restarts++, processAlive: FakeDaemonAlive);
            masked.Step(0, now, true, transport, "");
            Check(!Json.Encode(status).Contains("private-value"), "transport reason uses existing secret masking");
        }
        // Synchronous bus dispatch and fake interfaces: no Windows APIs or elapsed-time waits.
        static void RouteWatchChecks()
        {
            foreach (string topic in new[] { BusTopics.WinRouteChanged, BusTopics.WinIfaceChanged, BusTopics.WinAddrChanged, BusTopics.TickVpnScan }) {
                using (var bus = new EventBus(manualDispatch: true)) {
                    int best = 7, tun = 7, probes = 0, scans = 0, stops = 0, wakes = 0;
                    var health = new List<BusEvent>();
                    using (bus.Subscribe(BusTopics.VpnHealth, e => health.Add(e)))
                    using (var watch = new VpnRouteWatch(bus, () => { probes++; return best; }, () => tun,
                        () => scans++, () => stops++, () => wakes++)) {
                        Check(watch.Process() && probes == 1 && scans == 1, "initial fact check closes subscribe race");
                        for (int i = 0; i < 8; i++) bus.Publish(topic, BusTopics.Sources.Windows);
                        bus.DrainOnce();
                        Check(probes == 1 && stops == 0, "bus callback only queues work");
                        Check(watch.Process() && probes == 2 && scans == 2 && health.Count == 0 && stops == 0,
                            "burst with our TUN checks once and does not roll back");
                        Check(watch.Process() && probes == 2, "idle owner pass does not probe");
                        best = 9;
                        for (int i = 0; i < 8; i++) bus.Publish(topic, BusTopics.Sources.Windows);
                        bus.DrainOnce();
                        Check(!watch.Process() && probes == 3 && scans == 2 && stops == 1, "lost route rolls back once before scans");
                        bus.DrainOnce();
                        Check(health.Count == 1 && health[0].Get("result") == "fail" && health[0].Get("reason") == "routes-lost"
                            && health[0].Get("best1111") == "9" && health[0].Get("tunIf") == "7", "health contains failed route facts");
                        bus.Publish(topic, BusTopics.Sources.Windows); bus.DrainOnce();
                        Check(!watch.Process() && probes == 3 && stops == 1 && health.Count == 1, "later events cannot repeat rollback");
                        int previousWakes = wakes;
                        watch.Dispose();
                        bus.Publish(topic, BusTopics.Sources.Windows); bus.DrainOnce();
                        Check(wakes == previousWakes, "disposed watch unsubscribes");
                    }
                }
            }
            foreach (int badTun in new[] { -1, 0, 7 }) {
                using (var bus = new EventBus(manualDispatch: true)) {
                    int stops = 0;
                    using (var watch = new VpnRouteWatch(bus, () => -1, () => badTun, () => { }, () => stops++, () => { }))
                        Check(!watch.Process() && stops == 1, "missing TUN or failed API fails closed");
                }
            }
            Console.WriteLine("PASS: V5 route watch (manual bus, healthy/lost/missing routes, burst, single rollback, disposal)");
        }
        static void ScanEventChecks()
        {
            using (var bus = new EventBus(manualDispatch: true)) {
                var transport = D("pid", 42, "startedAt", ProcessStarted.ToString("o"), "ok", true, "active", "a",
                    "configRevision", "r1", "helper", D("udp", true, "vpnInPort", 17881), "endpoints", new[] { "198.51.100.7" },
                    "candidates", new[] { D("tag", "a", "state", "ok", "enabled", true) });
                var binding = VpnTunBinding.Resolve(transport, host => new[] { host });
                var rebind = new VpnTunRebind(0, binding, "config", evidence => binding, (b, e, c) => c, c => true);
                var scan = new VpnTunConflictScan(0, () => Snapshot("OpenVPN", "TAP OpenVPN", "192.168.9.0/24"));
                // Advancing fake time alone must never start the old five-second scans.
                foreach (long now in new long[] { 0, 5000, 10000, 60000, 600000 }) {
                    rebind.Tick(now, ProcessStarted, transport, FakeDaemonAlive); scan.Tick(now);
                    Check(!rebind.Preparing && !scan.Preparing, "elapsed time does not schedule DNS/inventory");
                }
                using (var watch = new VpnRouteWatch(bus, () => 7, () => 7,
                    () => { rebind.RequestScan(); scan.RequestScan(); }, () => { throw new Exception("unexpected rollback"); }, () => { })) {
                    bus.Publish(BusTopics.WinIfaceChanged, BusTopics.Sources.Windows);
                    bus.FireTick(BusTopics.Ticks.VpnScan);
                    bus.DrainOnce(); Check(watch.Process(), "interface/tick requests coalesce");
                    Check(!rebind.Preparing && !scan.Preparing, "callbacks do not launch workers");
                    rebind.Tick(600001, ProcessStarted, transport, FakeDaemonAlive); scan.Tick(600001);
                    Check(rebind.Preparing && scan.Preparing, "event requests start both workers on owner pass");
                }
            }
            Check(VpnRouteWatch.ScanPeriodMs >= 60000, "periodic fallback is rare");
            Console.WriteLine("PASS: V5 scan events (fake time, no periodic scans, interface/tick requests start workers)");
        }
        static void ConflictScanChecks()
        {
            int calls = 0;
            using (var entered = new ManualResetEvent(false))
            using (var release = new ManualResetEvent(false)) {
                var scan = new VpnTunConflictScan(0, () => { int call = Interlocked.Increment(ref calls); entered.Set(); release.WaitOne(); return call == 1 ? Snapshot("Happ TUN", "Wintun", "0.0.0.0/0") : Snapshot("OpenVPN", "TAP OpenVPN", "192.168.9.0/24"); });
                scan.Tick(4999); Check(calls == 0, "adapter scan waits for an event");
                scan.RequestScan();
                try {
                    scan.Tick(5000); Check(entered.WaitOne(1500), "fixed adapter snapshot starts asynchronously");
                    scan.Tick(15000); Check(calls == 1 && scan.Conflict == "", "slow inventory never blocks the owner tick or overlaps another snapshot");
                } finally { release.Set(); }
                Check(SpinWait.SpinUntil(() => { scan.Tick(15001); return scan.Conflict == "Happ TUN"; }, 1500), "completed snapshot detects foreign VPN on the running session");
                scan.Tick(20000); Check(calls == 1, "slow snapshot cannot queue catch-up scans");
                scan.RequestScan(); scan.Tick(20001);
                Check(SpinWait.SpinUntil(() => { scan.Tick(20002); return scan.Conflict == ""; }, 1500) && calls == 2, "next adapter snapshot detects removal without changing either VPN");
            }
            var failed = new VpnTunConflictScan(0, () => { throw new IOException("inventory unavailable"); });
            failed.RequestScan(); failed.Tick(5000);
            Check(SpinWait.SpinUntil(() => { failed.Tick(5001); return failed.Failed; }, 1500), "inventory exception is consumed as status");
        }
        // Fake time and gated workers exercise the production monitor without DNS,
        // Windows processes, real network changes or sleeps in the owner loop.
        sealed class RebindFixture : IDisposable
        {
            readonly DateTime utc = ProcessStarted;
            readonly VpnTun settings = VpnTun.Read(D("socksPort", 17881));
            readonly Dictionary<string, object> snapshot = Snapshot("OpenVPN", "TAP OpenVPN", "192.168.9.0/24");
            internal readonly ManualResetEvent ResolveEntered = new ManualResetEvent(false), ResolveRelease = new ManualResetEvent(true);
            internal readonly ManualResetEvent BuildEntered = new ManualResetEvent(false), BuildRelease = new ManualResetEvent(true);
            internal readonly Dictionary<string, object> Transport;
            internal readonly VpnTunRebind Rebind;
            internal readonly VpnTunMonitor Monitor;
            internal Dictionary<string, object> Status, RunningConfig;
            internal int Resolves, Builds, Restarts, DeadRestarts, Stops;
            internal bool ResolveFails, BuildFails, StartFails;
            internal string[] Addresses = { "198.51.100.7" };
            internal readonly List<long> BuildTimes = new List<long>(), RestartTimes = new List<long>();
            long time;
            internal RebindFixture()
            {
                Transport = D("pid", 42, "startedAt", ProcessStarted.ToString("o"), "ok", true, "active", "a", "updatedAt", utc.ToString("o"), "configRevision", "r1", "network", "wifi1", "localNet", "ok",
                    "helper", D("udp", true, "vpnInPort", 17881), "endpoints", new[] { "relay.example" }, "lan", D("subnets", new[] { "192.168.77.0/24" }),
                    "candidates", new[] { D("tag", "a", "state", "ok", "enabled", true) });
                var binding = VpnTunBinding.Resolve(Transport, host => Addresses);
                RunningConfig = MakeConfig(binding, Transport);
                Rebind = new VpnTunRebind(0, binding, Json.Encode(RunningConfig), evidence => {
                    Interlocked.Increment(ref Resolves); ResolveEntered.Set(); ResolveRelease.WaitOne();
                    if (ResolveFails) throw new IOException("fake DNS failure");
                    return VpnTunBinding.Resolve(evidence, host => Addresses);
                }, (updated, evidence, current) => {
                    Interlocked.Increment(ref Builds); lock (BuildTimes) BuildTimes.Add(Interlocked.Read(ref time));
                    BuildEntered.Set(); BuildRelease.WaitOne();
                    if (BuildFails) throw new InvalidDataException("fake config check failure");
                    return Json.Encode(MakeConfig(updated, evidence));
                }, candidate => {
                    Restarts++; RestartTimes.Add(time);
                    Check(Json.Bool(Status, "enabled") && Json.Str(Status, "state") == "searching" && Json.Str(Json.Map(Status["reason"]), "code") == "vpn-rebind", "searching is published before replacing the core in its Job");
                    if (StartFails) return false;
                    RunningConfig = Json.Map(Json.Parse(candidate)); return true;
                });
                Monitor = new VpnTunMonitor(0, Transport, VpnTun.DnsPolicy(snapshot), value => {
                    Status = value;
                    Check(Json.Bool(value, "enabled"), "rebind preserves enabled on every publication");
                }, reason => Stops++, () => DeadRestarts++, Rebind, FakeDaemonAlive);
            }
            Dictionary<string, object> MakeConfig(VpnTunBinding binding, Dictionary<string, object> evidence)
            { return Json.Map(Json.Parse(Json.Encode(settings.Config("ra-helper", Convert.ToBase64String(new byte[32]), binding.Ips, Json.Strings(Json.Get(Json.Map(evidence["lan"]), "subnets")), snapshot, VpnTun.DnsPolicy(snapshot), binding.Port)))); }
            internal int RunningPort { get { return Json.Int(Json.Map(Json.Array(RunningConfig["outbounds"])[0]), "server_port", 0); } }
            internal void Port(int port) { Json.Map(Transport["helper"])["vpnInPort"] = port; }
            internal void Step(long ms, bool alive = true)
            {
                Interlocked.Exchange(ref time, ms); var now = utc.AddMilliseconds(ms); Transport["updatedAt"] = now.ToString("o");
                Check(Monitor.Step(ms, now, alive, Transport, ""), "rebind owner loop keeps progressing");
            }
            internal void Advance(long ms)
            { while (time < ms) Step(Math.Min(time + 500, ms)); }
            internal void Await(long ms, Func<bool> done, string name)
            { Check(SpinWait.SpinUntil(() => { Step(ms); return done(); }, 1500), name); }
            public void Dispose() { ResolveRelease.Set(); BuildRelease.Set(); }
        }
        static void RebindChecks()
        {
            // (a), (d), (f): keep DNS gated over five seconds of injected time.
            using (var f = new RebindFixture()) {
                f.ResolveRelease.Reset(); f.Port(17891);
                f.Step(0);
                Check(f.ResolveEntered.WaitOne(1500), "rebind resolver runs in the background");
                Check(Json.Str(f.Status, "state") == "searching" && Json.Str(Json.Map(f.Status["reason"]), "code") == "vpn-rebind", "port mismatch never reports on while resolver is pending");
                string since = Json.Str(Json.Map(f.Status["reason"]), "since");
                for (int ms = 500; ms <= 5000; ms += 500) {
                    f.Step(ms);
                    Check(Json.Str(f.Status, "state") != "on" && f.RunningPort == 17881, "old core cannot report on with a different transport port");
                }
                Check(f.Resolves == 1 && f.Builds == 0 && f.Stops == 0 && f.DeadRestarts == 0, "five second simulated DNS delay neither blocks steps nor overlaps work nor triggers emergency Stop");
                Check(Json.Str(Json.Map(f.Status["reason"]), "since") == since, "vpn-rebind since remains stable during resolution");
                f.ResolveRelease.Set();
                f.Await(5001, () => f.Restarts == 1, "new port prepared and activated once");
                Check(f.Builds == 1 && f.RunningPort == 17891 && f.Rebind.Binding.Port == 17891 && f.Stops == 0, "one rebuild and one core restart use the new SOCKS port without Stop");
                f.Step(5002); Check(Json.Str(f.Status, "state") == "on", "on resumes only after observing the new running core");
                f.Step(5003, false);
                Check(f.DeadRestarts == 1 && f.Rebind.Config == Json.Encode(f.RunningConfig), "dead-core restart retains the updated working config");
            }
            // (b): DNS changes for the same host/revision are picked up on a network/tick event.
            using (var f = new RebindFixture()) {
                f.Addresses = new[] { "2001:db8::9", "198.51.100.8", "198.51.100.8" };
                f.Rebind.RequestScan(); f.Advance(5000); f.Await(5001, () => f.Restarts == 1, "changed resolved endpoint set triggers rebind without revision change");
                var excluded = Json.Strings(Json.Map(Json.Array(f.RunningConfig["inbounds"])[0])["route_exclude_address"]);
                Check(excluded.Contains("198.51.100.8/32") && excluded.Contains("2001:db8::9/128") && !excluded.Contains("198.51.100.7/32") && excluded.Contains("192.168.77.0/24") && excluded.Contains("192.168.9.0/24"), "new config replaces server exclusions and preserves LAN/foreign-adapter routes");
                f.Addresses = new[] { "198.51.100.8", "2001:0db8::9" };
                f.Transport["endpoints"] = new[] { "other.example" }; f.Transport["configRevision"] = "r2";
                f.Advance(10001); f.Await(10002, () => f.Rebind.Binding.Revision == "r2", "new endpoint name with same resolved IP set is consumed");
                Check(f.Builds == 1 && f.Restarts == 1 && f.Stops == 0, "endpoint alias, duplicate IPs and DNS answer order do not restart a matching config");
                f.Transport["endpoints"] = new[] { "198.51.100.9" }; f.Transport["configRevision"] = "r3";
                f.Advance(15002); f.Await(15003, () => f.Restarts == 2, "changed publisher endpoint list rebuilds VPN");
                Check(f.Rebind.Binding.Ips.SequenceEqual(new[] { "198.51.100.9" }) && f.Stops == 0, "published literal endpoint replaces resolved server set");
            }
            // (c): network/revision alone cause no construction or restart.
            using (var f = new RebindFixture()) {
                f.Transport["configRevision"] = "r2"; f.Transport["network"] = "wifi2";
                f.Step(0); f.Await(1, () => f.Rebind.Binding.Revision == "r2", "unchanged binding accepts new network/revision");
                f.Step(500);
                Check(f.Builds == 0 && f.Restarts == 0 && f.Stops == 0 && Json.Str(f.Status, "state") == "on", "Wi-Fi and revision changes leave identical VPN config/core alone");
                f.Transport.Remove("helper"); f.Transport.Remove("endpoints"); f.Transport.Remove("configRevision");
                f.Advance(15000);
                Check(f.Builds == 0 && f.Restarts == 0 && f.Resolves == 1, "old transport status without binding fields never loops through rebuilds");
            }
            // (e): a second change one second later waits for the five second bound.
            using (var f = new RebindFixture()) {
                f.Port(17891); f.Step(0); f.Await(1, () => f.Restarts == 1, "first rapid port update applied");
                f.Port(17901); f.Advance(1001);
                Check(f.Builds == 1 && f.Restarts == 1 && Json.Str(f.Status, "state") == "searching", "second port change at one second is deferred");
                f.Advance(5000); Check(f.Builds == 1 && f.Restarts == 1, "no second construction/restart before five seconds");
                f.Step(5001); f.Await(5002, () => f.Restarts == 2, "latest port is eventually applied after cooldown");
                Check(f.RunningPort == 17901 && f.RestartTimes[1] - f.RestartTimes[0] >= 5000 && f.BuildTimes[1] - f.BuildTimes[0] >= 5000 && f.Stops == 0, "both config construction and restart obey five second rate limit");
            }
            // (g): resolver/check failures never damage the current config; retry >=10s.
            using (var f = new RebindFixture()) {
                string before = f.Rebind.Config; f.ResolveFails = true; f.Port(17891);
                f.Step(0); f.Await(1, () => f.Rebind.Failed, "DNS failure becomes searching status");
                Check(f.Rebind.Config == before && f.RunningPort == 17881 && f.Builds == 0 && f.Restarts == 0 && f.Stops == 0 && Json.Str(f.Status, "state") == "searching", "failed resolution keeps the previous config and never calls Stop");
                f.Transport["configRevision"] = "r2"; f.Advance(10000);
                Check(f.Resolves == 1 && !f.Rebind.Preparing && Json.Str(f.Status, "state") != "on", "DNS error retry is delayed ten seconds even when revision changes");
                f.ResolveFails = false; f.Rebind.RequestScan(); f.Step(10001); f.Await(10002, () => f.Restarts == 1, "DNS recovers automatically after retry delay");
                Check(f.RunningPort == 17891 && f.Stops == 0, "recovered binding needs no manual disable or enable");
            }
            // A completed background result may already be obsolete. Also gate
            // construction itself to prove it never executes inside Step.
            using (var f = new RebindFixture()) {
                f.BuildRelease.Reset(); f.Port(17891); f.Step(0);
                Check(f.BuildEntered.WaitOne(1500), "config construction runs on the worker");
                f.Port(17901); f.Advance(1000);
                Check(f.Restarts == 0 && Json.Str(f.Status, "state") == "searching", "blocked config construction does not block owner ticks");
                f.BuildRelease.Set();
                f.Await(1001, () => !f.Rebind.Preparing, "obsolete background build is discarded");
                f.Advance(6001);
                f.Await(6002, () => f.Restarts == 1, "stale result discarded and latest binding activated");
                Check(f.RunningPort == 17901 && f.Builds == 2 && f.Stops == 0, "obsolete config is never launched");
            }
            foreach (bool failBuild in new[] { true, false }) using (var f = new RebindFixture()) {
                string before = f.Rebind.Config; f.BuildFails = failBuild; f.StartFails = !failBuild; f.Port(17891);
                f.Step(0); f.Await(1, () => f.Rebind.Failed, "config check/start failure is contained by rebind");
                Check(f.Rebind.Config == before && f.Rebind.Binding.Port == 17881 && f.Stops == 0 && Json.Str(f.Status, "state") == "searching", "failed config check or core launch cannot mark candidate as running");
            }
        }
        static void ConfigFileChecks(string root, VpnTun settings, Dictionary<string, object> snapshot, Dictionary<string, object> policy)
        {
            string directory = Path.Combine(root, "vpn-config-slots");
            Directory.CreateDirectory(directory);
            // Exercise the production slot selector and file writer over repeated
            // enable/rebind/disable cycles, without Windows Jobs or real secrets.
            for (int session = 0; session < 6; session++) {
                string current = null;
                for (int update = 0; update < 4; update++) {
                    string candidate = VpnTunSession.ConfigPath(directory, current);
                    Check(candidate != current, "rebind writes the inactive config slot");
                    Files.Atomic(candidate, Json.Encode(settings.Config("ra-helper", Convert.ToBase64String(new byte[32]),
                        new[] { "198.51.100.7" }, new string[0], snapshot, policy, 17881 + session)));
                    current = candidate;
                    Check(Directory.GetFiles(directory, "vpn-tun*.json").Length <= 2, "repeated enable/rebind/disable never accumulates credential configs");
                }
                // Disable ends this simulated core lifetime; the next enable starts
                // from the same first slot, without retaining the session number.
            }
            var files = Directory.GetFiles(directory, "vpn-tun*.json");
            Check(files.Select(Path.GetFileName).OrderBy(name => name).SequenceEqual(new[] { "vpn-tun-a.json", "vpn-tun-b.json" }), "only the two fixed config filenames remain");
            foreach (string file in files)
                Check(Json.Int(Json.Map(Json.Array(Json.Read(file)["outbounds"])[0]), "server_port", 0) == 17886, "both config slots overwrite previous sessions");
        }
        static void StatusChecks(string root)
        {
            int before = count;
            var now = ProcessStarted;
            string home = Path.Combine(root, "helper-vpn-status");
            Directory.CreateDirectory(Path.Combine(home, "status"));
            var serviceStatus = D("owner", "net-helper", "enabled", true, "ok", true, "state", "on", "updatedAt", now.ToString("o"));
            Files.Atomic(Path.Combine(home, "status/vpn.json"), Json.Encode(serviceStatus));
            Check(Json.Str(VpnStatus.Read(home, now), "state") == "on", "helper status does not require a legacy host receipt");
            serviceStatus["updatedAt"] = now.AddDays(-1).ToString("o");
            Files.Atomic(Path.Combine(home, "status/vpn.json"), Json.Encode(serviceStatus));
            var stale = VpnStatus.Read(home, now);
            Check(Json.Bool(stale, "enabled") && !Json.Bool(stale, "ok") && Json.Bool(stale, "statusStale") && Json.Str(stale, "state") == "on" && !File.Exists(Path.Combine(home, "state/vpn.stop")), "stale file cannot claim service shutdown or request a legacy stop");
            Check(Json.Str(Json.Read(Path.Combine(home, "status/vpn.json")), "state") == "on", "stale read never rewrites service status");
            foreach (string state in new[] { "searching", "conflict", "starting" }) {
                serviceStatus["state"] = state; serviceStatus["ok"] = state != "starting"; serviceStatus["summary"] = state == "starting" ? "Включается…" : "VPN включён"; serviceStatus["reason"] = D("code", "no-candidates", "text", "Нет подходящих путей", "since", now.ToString("o"));
                Files.Atomic(Path.Combine(home, "status/vpn.json"), Json.Encode(serviceStatus));
                var retained = VpnStatus.Read(home, now);
                Check(Json.Bool(retained, "statusStale") == (state != "starting"), "day-old " + state + " status applies the correct freshness policy");
                if (state == "starting") Check(!Json.Bool(retained, "ok") && Json.Str(retained, "summary") == "Включается…", "day-old starting preserves progress without a stale error");
                Check(Json.Bool(retained, "enabled") && Json.Str(retained, "state") == state && Json.Str(Json.Map(retained["reason"]), "code") == "no-candidates", "stale active " + state + " preserves intent and reason");
            }
            Check(!File.Exists(Path.Combine(home, "state/vpn.stop")), "service status never requests a legacy stop");
            Console.WriteLine("PASS: VpnStatus " + (count - before) + " checks (fake UTC clock)");
        }
        internal static void Run(string root)
        {
            var settings = VpnTun.Read(D("socksPort", 17881, "excludeCidrs", new[] { "203.0.113.0/24" }));
            var snapshot = Snapshot("OpenVPN", "TAP OpenVPN", "192.168.9.0/24");
            var strict = VpnTun.DnsPolicy(snapshot);
            var config = Json.Map(Json.Parse(Json.Encode(settings.Config("ra-helper", Convert.ToBase64String(new byte[32]), new[] { "198.51.100.7", "2001:db8::9" }, new[] { "192.168.77.0/24" }, snapshot, strict))));
            var tun = Json.Map(Json.Array(config["inbounds"])[0]);
            Check(Json.Bool(tun, "auto_route") && Json.Bool(tun, "strict_route") && Json.Str(tun, "interface_name") == "RemoteAgents-VPN", "default TUN route and strict DNS policy");
            var exclusions = Json.Strings(tun["route_exclude_address"]);
            foreach (var cidr in new[] { "10.0.0.0/8", "203.0.113.0/24", "192.168.77.0/24", "192.168.9.0/24", "198.51.100.7/32", "2001:db8::9/128" }) Check(exclusions.Contains(cidr), "excluded " + cidr);
            var socks = Json.Map(Json.Array(config["outbounds"])[0]);
            Check(Json.Str(socks, "type") == "socks" && Json.Str(socks, "server") == "127.0.0.1" && Json.Int(socks, "server_port", 0) == 17881 && Json.Str(socks, "password").Length > 0 && !socks.ContainsKey("bind_interface"), "authenticated loopback SOCKS without physical binding");
            var dns = Json.Map(Json.Array(Json.Map(config["dns"])["servers"])[0]);
            Check(Json.Str(dns, "type") == "https" && Json.Str(dns, "detour") == "vpn-active" && !dns.ContainsKey("bind_interface"), "DoH crosses SOCKS");
            var route = Json.Map(config["route"]); var rules = Json.Array(route["rules"]).Select(Json.Map).ToArray();
            Check(Json.Str(route, "final") == "vpn-active" && Json.Str(rules[0], "override_address") == "example.com" && Json.Strings(rules[0]["ip_cidr"]).Contains("198.18.0.1/32") && Json.Bool(rules[1], "disable_cache") && Json.Str(rules[1], "server") == "vpn-dns", "synthetic probe and uncached DNS precede exclusions");
            Check(Json.Str(Json.Map(config["log"]), "level") == "info", "core log level info (readiness line)");
            Check(Json.Str(rules[3], "action") == "hijack-dns" && Json.Int(rules[3], "ip_version", 0) == 6 && Json.Strings(rules[3]["port"]).SequenceEqual(new[] { "53" }) && Json.Strings(rules[3]["inbound"]).SequenceEqual(new[] { "vpn-tun" }), "IPv6 DNS hijack precedes IPv6 reject");
            Check(Json.Str(rules[4], "action") == "reject" && Json.Int(rules[4], "ip_version", 0) == 6 && Json.Strings(rules[5]["process_name"]).Contains("sing-box.exe"), "IPv6 reject after probe rules, before process_name/sniff");
            var dnsRule = Json.Map(Json.Array(Json.Map(config["dns"])["rules"])[0]);
            Check(Json.Strings(dnsRule["query_type"]).SequenceEqual(new[] { "AAAA" }) && Json.Str(dnsRule, "action") == "predefined" && Json.Str(dnsRule, "rcode") == "NOERROR", "AAAA answered empty first");
            var direct = Json.Map(Json.Array(config["outbounds"])[1]);
            Check(Json.Str(Json.Map(direct["domain_resolver"]), "strategy") == "ipv4_only" && Json.Str(Json.Map(direct["domain_resolver"]), "server") == "vpn-local", "vpn-direct resolves IPv4 only");
            var built = settings.Config("ra-helper", "S3CR3T-PASSWORD-VALUE", new[] { "198.51.100.7" }, new string[0], snapshot, strict, 17881);
            string text = Json.Encode(built);
            var cfgFacts = settings.ConfigFacts(built, text);
            string Fact(string[] f, string name) { for (int i = 0; i + 1 < f.Length; i += 2) if (f[i] == name) return f[i + 1]; return null; }
            Check(Fact(cfgFacts, "level") == "info" && Fact(cfgFacts, "covers1111") == "0" && Fact(cfgFacts, "covers_probe") == "0" && Fact(cfgFacts, "sha256").Length == 64 && Fact(cfgFacts, "json") == null, "vpn.config facts have no inline json");
            // Конфиг по частям: каждая строка журнала целиком (без [cut]), части склеиваются в исходный JSON; обрезка — флаг truncated=1.
            Func<string[][], string[]> lines = parts => parts.Select(f => RaLog.Format(new DateTimeOffset(ProcessStarted), LogLevel.Info, "vpn", "vpn.config.json", new[] { new KeyValuePair<string, string>(f[0], f[1]), new KeyValuePair<string, string>(f[2], f[3]), new KeyValuePair<string, string>(f[4], f[5]) }, "abcd")).ToArray();
            Func<string, string> jsonOf = line => { string v = line.Substring(line.IndexOf(" json=", StringComparison.Ordinal) + 6); if (v.StartsWith("\"")) v = v.Substring(1, v.Length - 2).Replace("\\\"", "\"").Replace("\\\\", "\\"); return v; };
            string whole = LogMask.Clean(Json.Encode(VpnTun.MaskSecrets(built)));
            Func<string[][], string> joined = parts => string.Concat(lines(parts).Select(jsonOf));
            var partsAll = VpnTun.ConfigJsonParts(built, 16000, 800); var partsDefault = lines(VpnTun.ConfigJsonParts(built)); var linesAll = lines(partsAll);
            Check(partsAll.Length > 1 && partsAll.All(f => f[3] == "0") && partsAll[0][1] == "1/" + partsAll.Length && Fact(cfgFacts, "json_parts") == partsDefault.Length.ToString(), "vpn.config.json part numbering");
            Check(linesAll.All(l => l.Length <= RaLog.MaxLine && !l.EndsWith("[cut]")), "vpn.config.json lines fit MaxLine");
            Check(joined(partsAll) == whole && string.Concat(partsDefault.Select(jsonOf)) == whole, "vpn.config.json parts restore whole json");
            Check(!whole.Contains("S3CR3T-PASSWORD-VALUE") && whole.Contains("***"), "config json parts mask secrets");
            var partsCut = VpnTun.ConfigJsonParts(built, 1000, 300);
            Check(partsCut.Length > 1 && partsCut.All(f => f[3] == "1") && joined(partsCut) == LogMask.Clean(Json.Encode(VpnTun.MaskSecrets(built)).Substring(0, 1000)), "truncation flagged in every part and matches what was logged");
            var quoted = VpnTun.ConfigJsonParts(D("a", new string('"', 50)), 16000, 40);
            Check(quoted.All(f => f[5].Length + f[5].Count(ch => ch == '"' || ch == '\\') <= 40) && string.Concat(quoted.Select(f => f[5])) == Json.Encode(D("a", new string('"', 50))), "escaped quotes counted twice when splitting");
            var failFields = VpnTun.CheckFields(new InvalidDataException("x"), "7", "bad config pw-Zq9 end", "pw-Zq9");
            Check(Array.IndexOf(failFields, "result") >= 0 && failFields[Array.IndexOf(failFields, "result") + 1] == "fail" && failFields[1] == "7" && !string.Join(" ", failFields).Contains("pw-Zq9") && VpnTun.CheckLevel(new InvalidDataException()) == LogLevel.Warn && VpnTun.CheckLevel(null) == LogLevel.Info && VpnTun.CheckFields(null, "7", "", "pw")[1] == "0", "vpn.check fields: fail/Warn, code kept, password masked");
            var tunSnapshot = D("Adapters", new[] { D("Name", "RemoteAgents-VPN", "ifIndex", 21) }, "Routes", new[] { D("InterfaceIndex", 21, "DestinationPrefix", "1.0.0.0/8"), D("InterfaceIndex", 21, "DestinationPrefix", "2.0.0.0/7"), D("InterfaceIndex", 21, "DestinationPrefix", "fdfe:7261::/126"), D("InterfaceIndex", 5, "DestinationPrefix", "0.0.0.0/0") });
            var tr = VpnTun.TunRoutes(tunSnapshot, "RemoteAgents-VPN");
            Check(tr[1] == "2" && tr[3] == "1" && tr[5] == "1.0.0.0/8,2.0.0.0/7,fdfe:7261::/126", "tunroutes counted per family on the TUN interface");
            Check(VpnTun.Conflict(Snapshot("Happ TUN", "Wintun", "0.0.0.0/0")) == "Happ TUN", "Happ full TUN conflicts");
            Check(VpnTun.Conflict(Snapshot("Happ TUN", "Wintun")).Length > 0, "unknown Up TUN conflicts without route evidence");
            Check(VpnTun.Conflict(Snapshot("Happ TUN", "Wintun", "172.20.0.0/24")).Length > 0, "an attached subnet does not hide unknown Up TUN");
            Check(VpnTun.Conflict(snapshot).Length == 0, "OpenVPN /24 is compatible");
            Check(VpnTun.Conflict(Snapshot("WG", "WireGuard", "192.168.10.0/24")).Length == 0, "partial WireGuard is compatible");
            Check(VpnTun.Conflict(Snapshot("OpenVPN", "TAP OpenVPN", "0.0.0.0/1", "128.0.0.0/1")).Length > 0, "OpenVPN split default conflicts");
            Check(VpnTun.Conflict(Snapshot("OpenVPN", "OpenVPN", "::/1", "8000::/1")).Length > 0, "IPv6 split default conflicts");
            Check(VpnTun.Conflict(Snapshot("Teredo", "Microsoft Teredo", "::/0")).Length == 0, "Teredo IPv6 default is ignored");
            Check(VpnTun.Conflict(Snapshot("RemoteAgents-LAN", "Wintun", "0.0.0.0/0")).Length == 0, "our LAN is independent");
            var physical = Snapshot("Ethernet", "Physical", "0.0.0.0/0");
            Json.Map(Json.Array(physical["Adapters"])[0])["Virtual"] = false;
            Json.Map(Json.Array(physical["Adapters"])[0])["HardwareInterface"] = true;
            Check(VpnTun.Conflict(physical).Length == 0, "physical default is compatible");
            var splitDns = Snapshot("OpenVPN", "OpenVPN", "192.168.9.0/24");
            splitDns["DnsClients"] = new[] { D("InterfaceIndex", 7, "ConnectionSpecificSuffix", "corp.example") };
            Check(!Json.Bool(VpnTun.DnsPolicy(splitDns), "strictRoute"), "partial network suffix preserves split DNS");
            splitDns["DnsClients"] = new object[0]; splitDns["Nrpt"] = new[] { D("Namespace", new[] { ".corp.example" }, "NameServers", new[] { "10.9.0.53" }) };
            Check(!Json.Bool(VpnTun.DnsPolicy(splitDns), "strictRoute"), "NRPT conservatively relaxes strict route with partial network");
            splitDns["Adapters"] = new object[0]; Check(Json.Bool(VpnTun.DnsPolicy(splitDns), "strictRoute"), "stale NRPT alone does not relax DNS");
            bool denied = false; try { VpnTun.DnsPolicy(D()); } catch (InvalidDataException) { denied = true; } Check(denied, "missing DNS inventory fails closed");
            var now = ProcessStarted;
            var transport = D("pid", 42, "startedAt", ProcessStarted.ToString("o"), "ok", true, "active", "a", "updatedAt", now.ToString("o"), "helper", D("udp", false), "candidates", new[] { D("tag", "a", "state", "ok", "enabled", true) });
            Check(VpnTun.PathState(transport, now, FakeDaemonAlive) == "no-udp", "TCP-only path refuses full VPN");
            Json.Map(transport["helper"])["udp"] = true;
            Check(VpnTun.PathState(transport, now, FakeDaemonAlive) == "", "live checked daemon path is accepted");
            transport["updatedAt"] = now.AddDays(-1).ToString("o");
            Check(VpnTun.PathState(transport, now, FakeDaemonAlive) == "", "day-old snapshot remains ready while its daemon is alive");
            Check(VpnTun.PathState(transport, now, (pid, started) => false) == "no-path", "dead daemon refuses VPN regardless of snapshot age");
            MonitorChecks(now, transport, strict);
            RouteWatchChecks(); ScanEventChecks();
            ConflictScanChecks();
            RebindChecks();
            ConfigFileChecks(root, settings, snapshot, strict);
            string command; Dictionary<string, object> request;
            Check(NetHelperProtocol.TryRequest(Json.Encode(settings.Request()) + "\r\n", out command, out request) && command == "vpn.on", "typed VPN command with CRLF");
            foreach (string invalid in new[] { "{\"cmd\":\"vpn.on\",\"socksPort\":17881,\"socksPort\":9}", "{\"cmd\":\"vpn.on\",\"socksPort\":17881,\"c\\u006dd\":\"vpn.off\"}", "{\"cmd\":\"vpn.on\",\"socksPort\":17881,\"path\":\"bad\"}", "{\"cmd\":\"vpn.on\",\"socksPort\":0}", "{\"cmd\":\"vpn.on\",\"socksPort\":17881,\"excludeCidrs\":[\"bad\"]}", "{\"cmd\":\"vpn.on\",\"socksPort\":17881,\"dnsServer\":{}}", "{\"cmd\":\"vpn.on\",\"socksPort\":17881,\"excludeCidrs\":{}}", "{\"cmd\":\"vpn.on\",\"socksPort\":\"17881\"}" })
                Check(!NetHelperProtocol.TryRequest(invalid, out command, out request), "reject malformed/duplicate/untyped privileged fields");
            var facts = new MainScreenFacts { VpnInstalled = true, Vpn = D("owner", "net-helper", "enabled", false, "state", "conflict", "conflictName", "Happ", "summary", VpnWatchdog.FailureSummary("conflict", "Happ")) };
            var view = MainScreenModel.Build(facts);
            Check(view.Vpn.Tone == Tone.Warning && view.Banner.Tone == Tone.Warning && view.Vpn.State.Contains("Happ") && view.Vpn.SwitchText == "Включить VPN", "yellow conflict card and tray facts name other VPN");
            StatusChecks(root);
            string singbox = Environment.GetEnvironmentVariable("SINGBOX");
            if (!string.IsNullOrEmpty(singbox)) {
                Directory.CreateDirectory(root); string file = Path.Combine(root, "vpn-tun-check.json"); Files.Atomic(file, Json.Encode(config));
                using (var process = Process.Start(new ProcessStartInfo(singbox, Files.Arguments(new[] { "check", "-c", file })) { UseShellExecute = false })) {
                    Check(process.WaitForExit(3000), "sing-box check within budget"); Check(process.ExitCode == 0, "sing-box accepts generated config");
                }
            }
            Console.WriteLine("PASS: VpnTun " + count + " checks (fake clocks and gated worker events)");
        }
    }
}
