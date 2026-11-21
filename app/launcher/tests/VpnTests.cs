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
            bool readinessOnly = args.Length == 1 && (args[0] == "--path-readiness-only" || args[0] == "--freshness-only");
            string root = args.Length > 0 && !readinessOnly ? args[0] : Path.Combine(Path.GetTempPath(), "vpn-tests-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            if (readinessOnly) { try { PathReadiness(root); } finally { Directory.Delete(root, true); } return 0; }
            Run(root); VpnTunTests.Run(root); VpnReadyTests.Run(); return 0;
        }
#endif
        static readonly DateTime ProcessStarted = new DateTime(2026, 11, 20, 12, 0, 0, DateTimeKind.Utc);
        static bool FakeDaemonAlive(int pid, DateTime started) { return pid == 42 && VpnWatchdog.ProcessStartMatches(ProcessStarted, started); }
        static System.Collections.Generic.Dictionary<string, object> ReadyTransport()
        {
            return ConfigBundle.D("pid", 42, "startedAt", ProcessStarted.ToString("o"), "ok", true, "active", "a",
                "updatedAt", ProcessStarted.AddDays(-1).ToString("o"), "phase", "ok", "helper", ConfigBundle.D("udp", true),
                "candidates", new object[] { ConfigBundle.D("tag", "a", "state", "ok", "enabled", true) });
        }
        static void OldSnapshotLiveDaemonReady()
        {
            var transport = ReadyTransport();
            Check(VpnWatchdog.TransportReady(transport, FakeDaemonAlive), "(a) OldSnapshotLiveDaemonReady: day-old status and live daemon are ready");
            Check(VpnTun.PathState(transport, processAlive: FakeDaemonAlive) == "", "(a) path step accepts old snapshot");
            transport["updatedAt"] = "invalid";
            Check(VpnWatchdog.TransportReady(transport, FakeDaemonAlive), "(a) readiness never parses the heartbeat");
            System.Collections.Generic.Dictionary<string, object> published = null;
            var monitor = new VpnTunMonitor(0, transport, ConfigBundle.D(), value => published = value,
                reason => { throw new Exception("unexpected stop"); }, () => { throw new Exception("unexpected restart"); }, processAlive: FakeDaemonAlive);
            Check(monitor.Step(0, ProcessStarted, true, transport, "") && Json.Bool(published, "ok"), "(a) monitor uses the same process facts");
        }
        static void DeadDaemonNotReady()
        {
            Check(!VpnWatchdog.TransportReady(ReadyTransport(), (pid, started) => false), "(b) DeadDaemonNotReady");
            Check(!VpnWatchdog.TransportReady(ReadyTransport(), (pid, started) => { throw new InvalidOperationException(); }), "(b) process access exception fails closed");
        }
        static void ReusedPidNotReady()
        {
            var transport = ReadyTransport(); transport["startedAt"] = ProcessStarted.AddDays(-1).ToString("o");
            Check(!VpnWatchdog.TransportReady(transport, FakeDaemonAlive), "(c) ReusedPidNotReady: same PID, different process start");
            Check(VpnWatchdog.ProcessStartMatches(ProcessStarted, ProcessStarted.AddSeconds(1)), "(c) rounded process start matches");
            Check(!VpnWatchdog.ProcessStartMatches(ProcessStarted, ProcessStarted.AddSeconds(3)), "(c) different process start does not match");
        }
        static void LegacyDaemonNotReady()
        {
            var transport = ReadyTransport(); transport.Remove("pid");
            Check(!VpnWatchdog.TransportReady(transport, FakeDaemonAlive) && VpnWatchdog.TransportProblem(transport, FakeDaemonAlive) == "old-daemon", "(d) LegacyDaemonNotReady: explicit old daemon reason");
            transport["pid"] = 42; transport["startedAt"] = "invalid";
            Check(!VpnWatchdog.TransportReady(transport, FakeDaemonAlive), "(d) malformed process identity fails closed");
            transport.Remove("startedAt");
            Check(!VpnWatchdog.TransportReady(transport, FakeDaemonAlive), "(d) missing process start fails closed");
        }
        static void ActiveCandidateMustBeOkEnabled()
        {
            var transport = ReadyTransport();
            Check(!VpnWatchdog.TransportReady(transport, FakeDaemonAlive, "b"), "(e) optional tag filter");
            foreach (var candidate in new[] {
                ConfigBundle.D("tag", "a", "state", "remembered", "enabled", true),
                ConfigBundle.D("tag", "a", "state", "ok", "enabled", false),
                ConfigBundle.D("tag", "a", "state", "ok"),
                ConfigBundle.D("tag", "b", "state", "ok", "enabled", true) }) {
                transport["candidates"] = new object[] { candidate };
                Check(!VpnWatchdog.TransportReady(transport, FakeDaemonAlive), "(e) ActiveCandidateMustBeOkEnabled");
            }
            transport = ReadyTransport(); transport["ok"] = false;
            Check(!VpnWatchdog.TransportReady(transport, FakeDaemonAlive), "(e) failed status is not ready");
            transport = ReadyTransport(); transport["active"] = "";
            Check(!VpnWatchdog.TransportReady(transport, FakeDaemonAlive), "(e) empty active is not ready");
            transport = ReadyTransport(); Json.Map(transport["helper"])["udp"] = false;
            Check(VpnTun.PathState(transport, processAlive: FakeDaemonAlive) == "no-udp", "(e) ready TCP-only channel retains no-udp refusal");
        }
        static void EarlyEnableWaitsForChange()
        {
            var waiting = new VpnPathWait(100, FakeDaemonAlive);
            waiting.Changed(ConfigBundle.D());
            Check(!waiting.Complete, "(f) EarlyEnableWaitsForChange: early enable remains pending");
            waiting.Changed(ReadyTransport()); // File change is supplied manually, no real watcher or time.
            Check(waiting.Complete && waiting.State == "" && VpnTun.PathState(waiting.Transport, processAlive: FakeDaemonAlive) == "", "(f) manual file change passes the path step without refusal");
            waiting.CheckFuse(long.MaxValue);
            Check(waiting.State == "", "(f) completed path result is terminal");
        }
        static void StartFuseNoPath()
        {
            long clock = 100;
            var waiting = new VpnPathWait(clock, FakeDaemonAlive); waiting.Changed(ConfigBundle.D());
            clock += VpnPathWait.VpnStartFuseMs; waiting.CheckFuse(clock); // Fake clock; no timer or timeout is executed.
            Check(waiting.Complete && waiting.State == "no-path", "(g) StartFuseNoPath: fuse gives the former refusal");
            waiting.Changed(ReadyTransport());
            Check(waiting.State == "no-path", "(g) late notification cannot reverse refusal");
        }
        static void DaemonPublishesProcessIdentity(string repo)
        {
            string source = File.ReadAllText(Path.Combine(repo, "transport/Transport.Daemon.ps1"));
            int start = source.IndexOf("function Publish-TransportStatus {", StringComparison.Ordinal);
            string publish = source.Substring(start, source.IndexOf("function Update-DaemonNetworkRows", start, StringComparison.Ordinal) - start);
            Check(publish.Contains("$doc=[ordered]@{pid=$PID;startedAt=$script:transportProcessStartedAt;"), "(h) DaemonPublishesProcessIdentity: document writes PID and startedAt");
            Check(publish.Contains("[Diagnostics.Process]::GetCurrentProcess()") && publish.Contains("$process.StartTime.ToUniversalTime().ToString('o')") && publish.Contains("$process.Dispose()"), "(h) publisher uses UTC ISO process start and disposes the process handle");
        }
        static void PathReadiness(string root, [System.Runtime.CompilerServices.CallerFilePath] string caller = "")
        {
            int before = count;
            string repo = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(caller), "../../.."));
            OldSnapshotLiveDaemonReady(); DeadDaemonNotReady(); ReusedPidNotReady(); LegacyDaemonNotReady();
            ActiveCandidateMustBeOkEnabled(); EarlyEnableWaitsForChange(); StartFuseNoPath(); DaemonPublishesProcessIdentity(repo);
            string home = Path.Combine(root, "path-readiness");
            Files.Atomic(Path.Combine(home, "status/transport.json"), Json.Encode(ReadyTransport()));
            Check(StatusView.ReadSnapshot(home, "transport").Count > 0 && Json.Bool(StatusView.ReadTransport(home, FakeDaemonAlive), "ok"), "snapshot and UI reader keep old live transport");
            var dead = StatusView.ReadTransport(home, (pid, started) => false);
            Check(!Json.Bool(dead, "ok") && Json.Str(dead, "phase") != "ok", "UI reader rejects dead daemon without presenting phase ok");
            foreach (string source in new[] { "TrayContext.cs", "LanTun.cs", "SetupWizard.cs" })
                Check(File.ReadAllText(Path.Combine(repo, "app/launcher", source)).Contains("StatusView.ReadTransport(home)"), source + " uses common facts policy");
            string client = File.ReadAllText(Path.Combine(repo, "app/launcher/HelperClient.cs"));
            Check(client.Contains("VpnStartFuseMs = " + VpnPathWait.VpnStartFuseMs + ";"), "path wait shares the existing client fuse budget");
            Console.WriteLine("PASS: R0 path readiness (" + (count - before) + " checks; fake processes, clock and file-change events; a-h)");
        }
        internal static void Run(string root)
        {
            PathReadiness(root);
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
