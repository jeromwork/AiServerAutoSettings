using System;
using System.IO;
using System.Diagnostics;

namespace RemoteAgents.Launcher
{
    internal static class VpnTests
    {
        static int count;
        static void Check(bool ok, string name) { if (!ok) throw new Exception("VPN: " + name); count++; }
        internal static void Run(string root)
        {
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
            using (var lease = new VpnLease(() => System.Threading.Interlocked.Increment(ref closed), 1000, 150)) {
                var slowChecks = Stopwatch.StartNew();
                while (closed == 0 && slowChecks.ElapsedMilliseconds < 1500) { lease.Pulse(); System.Threading.Thread.Sleep(20); }
                Check(lease.Expired && closed == 1, "progressing slow checks cannot renew the last successful health proof");
            }
            closed = 0;
            using (var lease = new VpnLease(() => System.Threading.Interlocked.Increment(ref closed), 1000, 200)) {
                for (int i = 0; i < 6; i++) { lease.Pulse(); lease.Confirmed(); System.Threading.Thread.Sleep(50); }
                Check(!lease.Expired && closed == 0, "only confirmed health renews the health deadline");
            }
            Check(VpnLease.HealthDeadlineMs + VpnWatchdog.PollMs < 5000, "absolute health cutoff has shutdown headroom within five seconds");
            var policy = new VpnWatchdog();
            Check(!policy.Sample(false, true) && policy.Failures == 1, "transport failure counts even if HTTPS works");
            Check(policy.Sample(true, false), "second consecutive failure disables, including mixed causes");
            policy = new VpnWatchdog();
            Check(!policy.Sample(true, false) && !policy.Sample(true, true) && policy.Failures == 0 && !policy.Sample(false, false), "success resets consecutive failures");
            Check(policy.Sample(false, false), "two complete failures disable");
            Check(VpnWatchdog.IntervalMs >= 2000 && VpnWatchdog.IntervalMs <= 3000 && VpnWatchdog.ProbeTimeoutMs <= 3000, "requested cadence and bounded probe");
            Check(2 * VpnWatchdog.IntervalMs + VpnWatchdog.ProbeTimeoutMs + 3 * VpnWatchdog.PollMs <= 5000, "worst phase and two expired probes fit five seconds including polling");
            DateTime now = DateTime.UtcNow;
            var status = ConfigBundle.D("ok", true, "active", "a", "updatedAt", now.ToString("o"), "candidates", new object[] { ConfigBundle.D("tag", "a", "state", "ok", "enabled", true) });
            Check(VpnWatchdog.TransportReady(status, now, "a"), "fresh checked active path");
            Check(!VpnWatchdog.TransportReady(status, now, "b"), "changed path cannot reuse previous VPN config");
            Check(!VpnWatchdog.TransportReady(status, now.AddSeconds(4)), "stale transport is a failure");
            Check(!VpnWatchdog.TransportReady(status, now.AddSeconds(-1)), "future proof is rejected");
            status["candidates"] = new object[] { ConfigBundle.D("tag", "a", "state", "remembered") };
            Check(!VpnWatchdog.TransportReady(status, now), "remembered path is not current proof");
            status["candidates"] = new object[] { ConfigBundle.D("tag", "a", "state", "ok", "enabled", false) };
            Check(!VpnWatchdog.TransportReady(status, now), "disabled candidate cannot authorize TUN");
            var home = Path.Combine(root, "vpn-status"); Directory.CreateDirectory(Path.Combine(home, "state")); Directory.CreateDirectory(Path.Combine(home, "status"));
            string file = Path.Combine(home, "status/vpn.json");
            Files.Atomic(file, Json.Encode(new { enabled = false, state = "server-unreachable", summary = VpnWatchdog.FailureSummary("server-unreachable"), updatedAt = now.AddDays(-1).ToString("o") }));
            Check(Json.Str(VpnStatus.Read(home), "state") == "server-unreachable", "automatic stop reason persists after status heartbeat expires");
            Files.Atomic(file, Json.Encode(new { enabled = true, state = "on", updatedAt = DateTime.UtcNow.ToString("o") }));
            using (var self = Process.GetCurrentProcess()) {
                Files.Atomic(Path.Combine(home, "state/vpn-host.json"), Json.Encode(new { pid = self.Id, startedTicks = "0" }));
                Check(Json.Str(VpnStatus.Read(home), "state") == "core-exited" && !Json.Bool(Json.Read(file), "enabled"), "reused PID is reconciled to off in the shared status file");
                Files.Atomic(file, Json.Encode(new { enabled = true, state = "on", updatedAt = DateTime.UtcNow.ToString("o") }));
                Files.Atomic(Path.Combine(home, "state/vpn-host.json"), Json.Encode(new { pid = self.Id, startedTicks = self.StartTime.ToUniversalTime().Ticks.ToString(System.Globalization.CultureInfo.InvariantCulture) }));
                Check(Json.Str(VpnStatus.Read(home), "state") == "on", "live pinned owner retains status");
            }
            Files.Atomic(file, Json.Encode(new { enabled = true, state = "on", updatedAt = now.AddSeconds(-4).ToString("o") }));
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
