using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Security.Principal;
using System.Threading;

namespace RemoteAgents.Launcher
{
    // Elevated, short-lived owner. Never a service or a Scheduled Task. Only this
    // process owns the Job handle: abrupt host death closes it in the kernel.
    internal static class VpnHost
    {
        internal static int Run(string[] args)
        {
            string home = Path.GetFullPath(Program.Option(args, "--home") ?? Program.DefaultHome);
            string script = Path.GetFullPath(Program.Option(args, "--vpn-script"));
            string session = Program.Option(args, "--vpn-session");
            string state = "error", tunName = ""; bool held = false, ran = false;
            NativeJob job = null; VpnLease lease = null; Process parent = null, core = null; VpnProbe probe = null;
            using (var gate = new Mutex(false, VpnWatchdog.OwnerMutex)) {
                try {
                    try { held = gate.WaitOne(0); } catch (AbandonedMutexException) { held = true; }
                    if (!held) return 1;
                    if (!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator)) return 1;
                    parent = Process.GetProcessById(int.Parse(Program.Option(args, "--vpn-parent")));
                    var pinned = parent.Handle; // Pin the original process, never trust a reused PID.
                    if (parent.StartTime.ToUniversalTime().Ticks != long.Parse(Program.Option(args, "--vpn-parent-start"))) return 1;
                    if (Stopped(home, session, parent)) { state = "off"; return 1; }
                    Files.Atomic(Path.Combine(home, "state/vpn-host.json"), Json.Encode(new { pid = Process.GetCurrentProcess().Id, startedTicks = Process.GetCurrentProcess().StartTime.ToUniversalTime().Ticks.ToString(System.Globalization.CultureInfo.InvariantCulture), session }));
                    job = new NativeJob();
                    string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
                    // Re-inventory conflicts and transport AFTER UAC, before creating any TUN.
                    using (var prepare = job.StartRedirected(powershell, new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Home", home, "-Worker", "-Session", session }, Path.GetDirectoryName(script), null)) {
                        var budget = Stopwatch.StartNew();
                        while (!prepare.HasExited) {
                            if (Stopped(home, session, parent) || budget.ElapsedMilliseconds > 30000) throw new IOException();
                            Thread.Sleep(VpnWatchdog.PollMs);
                        }
                        if (prepare.ExitCode != 0) { state = Json.Str(Read(home, "status/vpn.json"), "state"); if (VpnWatchdog.FailureSummary(state).Length == 0) state = "error"; return 1; }
                    }
                    var plan = Read(home, "state/vpn-plan.json");
                    if (Json.Str(plan, "session") != session || Stopped(home, session, parent)) throw new IOException();
                    string tag = Json.Str(plan, "tag"), network = Json.Str(plan, "network"), revision = Json.Str(plan, "revision");
                    tunName = Json.Str(plan, "interfaceName");
                    string physical = Json.Str(plan, "physical");
                    string fingerprint = PhysicalFingerprint(physical);
                    if (fingerprint.Length == 0 || !VpnWatchdog.TransportReady(Read(home, "status/transport.json"), DateTime.UtcNow, tag)) { state = "no-path"; return 1; }
                    IPAddress target = IPAddress.Parse(Json.Str(plan, "checkAddress"));
                    var url = new Uri(Json.Str(plan, "checkUrl"));
                    string config = Path.Combine(home, "state/vpn-sing-box.json");
                    // No elevated process is ever assigned to an unprivileged launcher's Job.
                    lease = new VpnLease(job.Dispose);
                    core = job.Start(Json.Str(plan, "exe"), new[] { "run", "-c", config }, Path.GetDirectoryName(script)); ran = true;
                    Files.Atomic(Path.Combine(home, "state/vpn-owner.json"), Json.Encode(new { pid = core.Id, exe = Json.Str(plan, "exe"), config, startedAt = core.StartTime.ToUniversalTime().ToString("o") }));
                    Write(home, "starting", "Включается…", true);
                    var clock = Stopwatch.StartNew(); long next = 0, began = 0; bool transportOk = false; int tunIndex = 0;
                    DateTime previous = DateTime.UtcNow; var policy = new VpnWatchdog();
                    while (true) {
                        if (lease.Expired) { state = "watchdog-stalled"; break; }
                        lease.Pulse();
                        DateTime now = DateTime.UtcNow;
                        if ((now - previous).TotalMilliseconds > 3000 || now < previous) { state = "resumed"; break; }
                        previous = now;
                        if (Stopped(home, session, parent)) { state = "off"; break; }
                        if (core.HasExited) { state = "core-exited"; break; }
                        if (probe == null && clock.ElapsedMilliseconds >= next) {
                            if (PhysicalFingerprint(physical) != fingerprint) { state = "network-changed"; break; }
                            var transport = Read(home, "status/transport.json");
                            if (Json.Str(transport, "active") != tag || Json.Str(transport, "network") != network || Json.Str(transport, "configRevision") != revision) { state = "network-changed"; break; }
                            transportOk = VpnWatchdog.TransportReady(transport, now, tag);
                            var adapter = NetworkInterface.GetAllNetworkInterfaces().FirstOrDefault(n => n.Name == Json.Str(plan, "interfaceName") && n.OperationalStatus == OperationalStatus.Up);
                            if (adapter != null) {
                                tunIndex = adapter.GetIPProperties().GetIPv4Properties().Index;
                                Files.Atomic(Path.Combine(home, "state/vpn-interface.json"), Json.Encode(new { session, guid = adapter.Id.Trim('{', '}'), name = adapter.Name }));
                            }
                            began = clock.ElapsedMilliseconds; next = began + VpnWatchdog.IntervalMs;
                            probe = new VpnProbe(url, target, tunIndex);
                        }
                        if (probe != null && (probe.Result.IsCompleted || clock.ElapsedMilliseconds - began >= VpnWatchdog.ProbeTimeoutMs)) {
                            bool ok = probe.Result.IsCompleted && probe.Result.GetAwaiter().GetResult(); probe.Dispose(); probe = null;
                            transportOk &= VpnWatchdog.TransportReady(Read(home, "status/transport.json"), DateTime.UtcNow, tag);
                            if (transportOk && ok) lease.Confirmed();
                            if (policy.Sample(transportOk, ok)) { state = "server-unreachable"; break; }
                            Write(home, policy.Failures == 0 ? "on" : "checking", policy.Failures == 0 ? "Защита включена" : "Проверяем связь с сервером…", true);
                        }
                        Thread.Sleep(VpnWatchdog.PollMs);
                    }
                    return 0;
                } catch { state = "error"; return 1; }
                finally {
                    // Restore the network FIRST. No config mutex, PowerShell or disk journal can delay Job closure.
                    if (job != null) job.Dispose();
                    if (lease != null) lease.Dispose();
                    if (probe != null) probe.Dispose();
                    if (core != null) { try { core.WaitForExit(1000); } catch { } core.Dispose(); }
                    if (parent != null) parent.Dispose();
                    if (ran && tunName.Length > 0) {
                        try {
                            var adapter = NetworkInterface.GetAllNetworkInterfaces().FirstOrDefault(n => n.Name == tunName);
                            if (adapter != null) {
                                Files.Atomic(Path.Combine(home, "state/vpn-interface.json"), Json.Encode(new { session, guid = adapter.Id.Trim('{', '}'), name = adapter.Name }));
                                // A rare driver residue is removed by exact receipt, in a bounded
                                // disposable Job. Normal shutdown relies on Wintun handle lifetime.
                                using (var cleanup = new NativeJob())
                                using (var process = cleanup.StartRedirected("powershell.exe", new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Home", home, "-Rollback", "-Session", session }, Path.GetDirectoryName(script), null))
                                    if (!process.WaitForExit(2500) || process.ExitCode != 0) state = "rollback-error";
                                if (NetworkInterface.GetAllNetworkInterfaces().Any(n => n.Name == tunName)) state = "rollback-error";
                            }
                            if (state != "rollback-error") foreach (string name in new[] { "vpn-owner.json", "vpn-interface.json", "vpn-plan.json" }) File.Delete(Path.Combine(home, "state", name));
                        } catch { state = "rollback-error"; }
                    }
                    if (held) {
                        try { Write(home, state, state == "off" ? "VPN выключен" : VpnWatchdog.FailureSummary(state), false); } catch { }
                        // Wintun routes and the temporary adapter belong to the core's handle.
                        // Receipts are evidence for the next confirmed legacy cleanup if Windows misbehaves.
                        if (!ran) try { File.Delete(Path.Combine(home, "state/vpn-plan.json")); } catch { }
                        gate.ReleaseMutex();
                    }
                }
            }
        }
        static Dictionary<string, object> Read(string home, string relative)
        { try { return Json.Read(Path.Combine(home, relative)); } catch { return Json.Map(null); } }
        static bool Stopped(string home, string session, Process parent)
        { return parent.HasExited || File.Exists(Path.Combine(home, "stop")) || File.Exists(Path.Combine(home, "state/vpn.stop")) || Json.Str(Read(home, "state/vpn-session.json"), "session") != session; }
        static string PhysicalFingerprint(string name)
        {
            var net = NetworkInterface.GetAllNetworkInterfaces().FirstOrDefault(n => n.Name == name && n.OperationalStatus == OperationalStatus.Up);
            if (net == null) return "";
            var ip = net.GetIPProperties();
            return net.Id + ":" + string.Join(",", ip.UnicastAddresses.Select(a => a.Address.ToString()).OrderBy(s => s)) + ":" + string.Join(",", ip.GatewayAddresses.Select(a => a.Address.ToString()).OrderBy(s => s));
        }
        static void Write(string home, string state, string summary, bool enabled)
        {
            Files.Atomic(Path.Combine(home, "status/vpn.json"), Json.Encode(new { ok = state == "on", enabled, state, summary, updatedAt = DateTime.UtcNow.ToString("o") }));
            // Fixed categories only; no target, URL, key or process argument logging.
            string log = Path.Combine(home, "logs/vpn.log"); Directory.CreateDirectory(Path.GetDirectoryName(log));
            if (File.Exists(log) && new FileInfo(log).Length > 1024 * 1024) File.Delete(log);
            File.AppendAllText(log, DateTime.UtcNow.ToString("o") + " " + state + "\n");
        }
    }
}
