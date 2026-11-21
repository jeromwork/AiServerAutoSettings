using System;
using System.IO;
using System.Diagnostics;

namespace RemoteAgents.Launcher
{
    internal static class VpnTests
    {
        static int count;
        static void Check(bool ok, string name) { if (!ok) throw new Exception("VPN: " + name); count++; }
#if PORTABLE_TEST
        // Focused entry point; do not invoke the unrelated portable suites.
        static int Main(string[] args)
        {
            bool freshnessOnly = args.Length == 1 && args[0] == "--freshness-only";
            string root = args.Length > 0 && !freshnessOnly ? args[0] : Path.Combine(Path.GetTempPath(), "vpn-tests-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            if (freshnessOnly) { try { Freshness(root); } finally { Directory.Delete(root, true); } return 0; }
            Run(root); VpnTunTests.Run(root); VpnReadyTests.Run(); return 0;
        }
#endif
        // Fixed clocks and manually supplied heartbeats: no real waits or network access.
        static void Freshness(string root, [System.Runtime.CompilerServices.CallerFilePath] string caller = "")
        {
            int before = count;
            string repo = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(caller), "../../.."));
            var heartbeat = System.Text.RegularExpressions.Regex.Match(
                File.ReadAllText(Path.Combine(repo, "transport/Transport.Daemon.ps1")), @"(?m)^\$StatusHeartbeatMs=(\d+)");
            Check(heartbeat.Success, "daemon heartbeat is declared");
            int heartbeatMs = int.Parse(heartbeat.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture);
            Check(heartbeatMs > 0 && (long)VpnWatchdog.TransportStatusMaxAgeSec * 1000 >= 3L * heartbeatMs,
                "freshness window covers at least three daemon heartbeats");
            DateTime now = new DateTime(2026, 11, 21, 12, 0, 0, DateTimeKind.Utc);
            var transport = ConfigBundle.D("ok", true, "active", "a", "updatedAt", now.ToString("o"),
                "helper", ConfigBundle.D("udp", true), "candidates", new object[] { ConfigBundle.D("tag", "a", "state", "ok", "enabled", true) });
            string home = Path.Combine(root, "freshness");
            Directory.CreateDirectory(Path.Combine(home, "state")); Directory.CreateDirectory(Path.Combine(home, "status"));
            string file = Path.Combine(home, "status/vpn.json"), transportFile = Path.Combine(home, "status/transport.json");
            using (var self = Process.GetCurrentProcess()) {
                Files.Atomic(Path.Combine(home, "state/vpn-host.json"), Json.Encode(new {
                    pid = self.Id, startedTicks = self.StartTime.ToUniversalTime().Ticks.ToString(System.Globalization.CultureInfo.InvariantCulture)
                }));
                foreach (int age in new[] { 0, 4, 5, 6, 14, 15, 16, -1 }) {
                    DateTime clock = now.AddSeconds(age);
                    bool fresh = age >= 0 && age <= 15;
                    Check(VpnWatchdog.TransportReady(transport, clock, "a") == fresh, "transport freshness at age " + age);
                    Check(VpnTun.PathState(transport, clock) == (fresh ? "" : "no-path"), "TUN freshness at age " + age);
                    Files.Atomic(transportFile, Json.Encode(transport) + "\r\n");
                    File.SetLastWriteTimeUtc(transportFile, now);
                    if (age >= 0)
                        Check((StatusView.Read(home, "transport", clock, VpnWatchdog.TransportStatusMaxAgeSec).Count > 0) == fresh,
                            "tray transport read at age " + age);
                    foreach (string owner in new[] { "net-helper", "legacy-host" }) {
                        File.Delete(Path.Combine(home, "state/vpn.stop"));
                        Files.Atomic(file, Json.Encode(new { ok = true, enabled = true, state = "on", owner, updatedAt = now.ToString("o") }) + "\r\n");
                        var read = VpnStatus.Read(home, clock);
                        Check(Json.Bool(read, "ok") == fresh, owner + " VPN freshness at age " + age);
                        if (owner == "net-helper") {
                            Check(Json.Bool(read, "enabled") && Json.Bool(read, "statusStale") == !fresh,
                                "helper preserves intent and marks stale/future status at age " + age);
                            Check(Json.Bool(Json.Read(file), "ok"), "helper stale read never rewrites status at age " + age);
                        }
                        Check(Json.Str(read, "state") == (fresh || owner == "net-helper" ? "on" : "watchdog-stalled"),
                            owner + " stale/future status handling at age " + age);
                        Check(File.Exists(Path.Combine(home, "state/vpn.stop")) == (!fresh && owner != "net-helper"),
                            owner + " stop handling at age " + age);
                    }
                }
            }
            transport["ok"] = false;
            Check(!VpnWatchdog.TransportReady(transport, now), "recent failure is not ready");
            transport["ok"] = true;
            transport["updatedAt"] = "invalid";
            Check(!VpnWatchdog.TransportReady(transport, now), "invalid timestamp is not ready");
            int stops = 0, restarts = 0;
            System.Collections.Generic.Dictionary<string, object> published = null;
            var monitor = new VpnTunMonitor(0, transport, ConfigBundle.D(), value => published = value, reason => stops++, () => restarts++);
            for (int ms = 0; ms <= 4 * heartbeatMs; ms += 1000) {
                if (ms % heartbeatMs == 0) transport["updatedAt"] = now.AddMilliseconds(ms).ToString("o");
                Check(monitor.Step(ms, now.AddMilliseconds(ms), true, transport, "") && Json.Bool(published, "ok")
                    && Json.Str(published, "state") == "on", "heartbeat gap does not flicker at fake millisecond " + ms);
            }
            Check(stops == 0 && restarts == 0, "heartbeat gaps never stop or restart the core");
            Console.WriteLine("PASS: VPN freshness (" + (count - before) + " checks, fake clocks; Watchdog/Status/TUN/tray, heartbeat gaps)");
        }
        internal static void Run(string root)
        {
            Freshness(root);
            Check(Product.VpnEnabled, "VPN capability is restored");
            string gateName = VpnWatchdog.OwnerMutex + "-test-" + Guid.NewGuid().ToString("N");
            using (var ownerGate = new System.Threading.Mutex(false, gateName)) {
                ownerGate.WaitOne();
                try {
                    Check(!System.Threading.Tasks.Task.Run(() => {
                        using (var otherHome = new System.Threading.Mutex(false, gateName)) {
                            bool entered = otherHome.WaitOne(0); if (entered) otherHome.ReleaseMutex(); return entered;
                        }
                    }).GetAwaiter().GetResult(), "a second home or product cannot own machine VPN or cleanup concurrently");
                } finally { ownerGate.ReleaseMutex(); }
            }
            int closed = 0;
            using (var lease = new VpnLease(() => System.Threading.Interlocked.Increment(ref closed), 100)) {
                Check(System.Threading.SpinWait.SpinUntil(() => System.Threading.Interlocked.CompareExchange(ref closed, 0, 0) == 1, 1500), "blocked lifecycle closes fake core Job independently");
                Check(lease.Expired && closed == 1, "emergency close runs once");
            }
            closed = 0;
            using (var lease = new VpnLease(() => System.Threading.Interlocked.Increment(ref closed), 200)) {
                for (int i = 0; i < 5; i++) { lease.Pulse(); System.Threading.Thread.Sleep(50); }
                Check(!lease.Expired && closed == 0, "a progressing lifecycle retains its Job");
            }
            Check(VpnLease.DeadlineMs < 5000, "blocked host fail-open deadline");
            closed = 0;
            using (var lease = new VpnLease(() => System.Threading.Interlocked.Increment(ref closed), 1000)) {
                var waitingForNetwork = Stopwatch.StartNew();
                while (waitingForNetwork.ElapsedMilliseconds < 5000) { lease.Pulse(); System.Threading.Thread.Sleep(50); }
                Check(!lease.Expired && closed == 0, "progress beyond former 4.5 second health deadline never closes a Job without network proof");
            }
            DateTime now = DateTime.UtcNow;
            var status = ConfigBundle.D("ok", true, "active", "a", "updatedAt", now.ToString("o"), "candidates", new object[] { ConfigBundle.D("tag", "a", "state", "ok", "enabled", true) });
            Check(VpnWatchdog.TransportReady(status, now, "a"), "fresh checked active path");
            Check(!VpnWatchdog.TransportReady(status, now, "b"), "optional tag filter rejects another path");
            Check(!VpnWatchdog.TransportReady(status, now.AddSeconds(16)), "stale transport is a failure");
            Check(!VpnWatchdog.TransportReady(status, now.AddSeconds(-1)), "future proof is rejected");
            status["candidates"] = new object[] { ConfigBundle.D("tag", "a", "state", "remembered") };
            Check(!VpnWatchdog.TransportReady(status, now), "remembered path is not current proof");
            status["candidates"] = new object[] { ConfigBundle.D("tag", "a", "state", "ok", "enabled", false) };
            Check(!VpnWatchdog.TransportReady(status, now), "disabled candidate cannot authorize TUN");
            var home = Path.Combine(root, "vpn-status"); Directory.CreateDirectory(Path.Combine(home, "state")); Directory.CreateDirectory(Path.Combine(home, "status"));
            string file = Path.Combine(home, "status/vpn.json");
            Files.Atomic(file, Json.Encode(new { enabled = false, state = "server-unreachable", summary = VpnWatchdog.FailureSummary("server-unreachable"), updatedAt = now.AddDays(-1).ToString("o") }));
            Check(Json.Str(VpnStatus.Read(home), "state") == "server-unreachable", "legacy terminal reason persists after status heartbeat expires");
            Files.Atomic(file, Json.Encode(new { enabled = true, state = "on", updatedAt = DateTime.UtcNow.ToString("o") }));
            using (var self = Process.GetCurrentProcess()) {
                Files.Atomic(Path.Combine(home, "state/vpn-host.json"), Json.Encode(new { pid = self.Id, startedTicks = "0" }));
                Check(Json.Str(VpnStatus.Read(home), "state") == "core-exited" && !Json.Bool(Json.Read(file), "enabled"), "reused PID is reconciled to off in the shared status file");
                Files.Atomic(file, Json.Encode(new { enabled = true, state = "on", updatedAt = DateTime.UtcNow.ToString("o") }));
                Files.Atomic(Path.Combine(home, "state/vpn-host.json"), Json.Encode(new { pid = self.Id, startedTicks = self.StartTime.ToUniversalTime().Ticks.ToString(System.Globalization.CultureInfo.InvariantCulture) }));
                Check(Json.Str(VpnStatus.Read(home), "state") == "on", "live pinned owner retains status");
            }
            Files.Atomic(file, Json.Encode(new { enabled = true, state = "on", updatedAt = now.AddSeconds(-16).ToString("o") }));
            Check(Json.Str(VpnStatus.Read(home), "state") == "watchdog-stalled" && File.Exists(Path.Combine(home, "state/vpn.stop")), "stale heartbeat never displays active protection");
            File.Delete(Path.Combine(home, "state/vpn.stop"));
            using (var self = Process.GetCurrentProcess()) {
                var pending = new { enabled = true, state = "awaiting-uac", updatedAt = now.AddMinutes(-10).ToString("o") };
                Files.Atomic(file, Json.Encode(pending)); File.Delete(Path.Combine(home, "state/vpn-host.json"));
                Files.Atomic(Path.Combine(home, "state/vpn-session.json"), Json.Encode(new { pid = self.Id, startedTicks = self.StartTime.ToUniversalTime().Ticks.ToString(System.Globalization.CultureInfo.InvariantCulture) }));
                Check(Json.Str(VpnStatus.Read(home), "state") == "awaiting-uac", "slow valid UAC wait is not mistaken for host death");
                Files.Atomic(Path.Combine(home, "state/vpn-session.json"), Json.Encode(new { pid = self.Id, startedTicks = "0" }));
                var cancelled = VpnStatus.Read(home);
                var pendingFacts = new MainScreenFacts { VpnInstalled = true, Vpn = cancelled };
                Check(Json.Str(cancelled, "state") == "off" && !Json.Bool(cancelled, "enabled") && MainScreenModel.Build(pendingFacts).Vpn.SwitchEnabled, "dead or reused pending launcher unlocks the next launch");
                Check(File.Exists(Path.Combine(home, "state/vpn.stop")), "late UAC acceptance remains cancelled after pending launcher death");
            }
            var facts = new MainScreenFacts { VpnInstalled = true, VpnWanted = true, Vpn = ConfigBundle.D("enabled", false, "state", "server-unreachable") };
            var view = MainScreenModel.Build(facts);
            Check(!view.Vpn.On && view.Vpn.State == "VPN выключен: сервер не отвечает" && view.Banner.Text == view.Vpn.State, "stale saved intent cannot hide auto-stop in card and banner");
            facts.Vpn = ConfigBundle.D("enabled", true, "state", "starting");
            view = MainScreenModel.Build(facts);
            Check(!view.Vpn.SwitchEnabled && view.Vpn.SwitchText == "Включается…", "starting from a different action also locks switch");
            var dnsPolicy = ConfigBundle.D("strictRoute", false, "networks", new object[] {
                ConfigBundle.D("name", "Office", "interfaceIndex", 7, "servers", new[] { "10.9.0.53", "fd00::53" }, "suffixes", new[] { "corp.example" }, "nrpt", new object[0]),
                ConfigBundle.D("name", "Tailscale", "interfaceIndex", 8, "servers", new string[0], "suffixes", new string[0], "nrpt", new object[] { ConfigBundle.D("namespaces", new[] { ".tail123.ts.net" }, "servers", new[] { "100.100.100.100" }) })
            });
            facts.Vpn = ConfigBundle.D("ok", true, "enabled", true, "state", "on", "dnsPolicy", dnsPolicy);
            facts.Transport = ConfigBundle.D("ok", true);
            view = MainScreenModel.Build(facts);
            Check(view.Vpn.On && view.Vpn.SwitchEnabled && view.Vpn.Tone == Tone.Warning && view.Vpn.Detail.Contains("DNS: защита частичная из-за Office, Tailscale"), "partial DNS is visible without making healthy VPN a failure or locking its switch");
            string detail = VpnStatus.DnsDetail(facts.Vpn);
            Check(detail.Contains("strict_route=false") && detail.Contains("fd00::53") && detail.Contains("corp.example") && detail.Contains(".tail123.ts.net") && detail.Contains("100.100.100.100"), "diagnostics explain servers, suffixes, NRPT and residual multihomed risk");
            Check(MainScreenModel.Report(facts, "").Contains(detail.Replace("\r\n", "\n")), "copied diagnostics include complete DNS decision");
            using (var self = Process.GetCurrentProcess()) {
                facts.Vpn["updatedAt"] = DateTime.UtcNow.ToString("o");
                Files.Atomic(file, Json.Encode(facts.Vpn));
                Files.Atomic(Path.Combine(home, "state/vpn-host.json"), Json.Encode(new { pid = self.Id, startedTicks = self.StartTime.ToUniversalTime().Ticks.ToString(System.Globalization.CultureInfo.InvariantCulture) }));
                Check(VpnStatus.DnsDetail(VpnStatus.Read(home)) == detail, "shared live status retains the session DNS decision after JSON roundtrip");
            }
            facts.Vpn["dnsPolicy"] = ConfigBundle.D("strictRoute", true, "networks", new object[0]);
            view = MainScreenModel.Build(facts);
            Check(view.Vpn.Tone == Tone.Ok && !view.Vpn.Detail.Contains("защита частичная") && VpnStatus.DnsDetail(facts.Vpn).Contains("strict_route=true"), "next strict session clears partial warning and explains WFP protection");
            facts.Vpn["dnsPolicy"] = dnsPolicy; facts.Vpn["enabled"] = false; facts.Vpn["ok"] = false; facts.Vpn["state"] = "off";
            Check(VpnStatus.DnsSummary(facts.Vpn).Length == 0 && VpnStatus.DnsDetail(facts.Vpn).Length == 0 && !MainScreenModel.Build(facts).Vpn.Detail.Contains("защита частичная"), "disabled session never shows stale DNS protection");
            Console.WriteLine("PASS: " + count + " VPN watchdog, timing and lifecycle checks");
        }
    }
}
