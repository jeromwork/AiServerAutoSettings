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
            Files.Atomic(file, Json.Encode(new { enabled = true, state = "awaiting-uac" })); File.Delete(Path.Combine(home, "state/vpn-host.json"));
            Check(Json.Str(VpnStatus.Read(home), "state") == "awaiting-uac", "UAC wait is not mistaken for host death");
            var facts = new MainScreenFacts { VpnInstalled = true, VpnWanted = true, Vpn = ConfigBundle.D("enabled", false, "state", "server-unreachable") };
            var view = MainScreenModel.Build(facts);
            Check(!view.Vpn.On && view.Vpn.State == "VPN выключен: сервер не отвечает" && view.Banner.Text == view.Vpn.State, "stale saved intent cannot hide auto-stop in card and banner");
            facts.Vpn = ConfigBundle.D("enabled", true, "state", "starting");
            view = MainScreenModel.Build(facts);
            Check(!view.Vpn.SwitchEnabled && view.Vpn.SwitchText == "Включается…", "starting from a different action also locks switch");
            Console.WriteLine("PASS: " + count + " VPN watchdog, timing and lifecycle checks");
        }
    }
}
