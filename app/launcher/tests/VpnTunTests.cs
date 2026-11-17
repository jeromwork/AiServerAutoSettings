using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;

namespace RemoteAgents.Launcher
{
    internal static class VpnTunTests
    {
        static int count;
        static void Check(bool value, string name) { if (!value) throw new Exception("VpnTun: " + name); count++; }
        static Dictionary<string, object> D(params object[] values) { return VpnTun.D(values); }
        static Dictionary<string, object> Snapshot(string name, string description, params string[] routes)
        {
            return D("Adapters", new[] { D("Name", name, "InterfaceDescription", description, "ifIndex", 7, "Status", "Up", "Virtual", true) },
                "Routes", routes.Select(r => D("InterfaceIndex", 7, "DestinationPrefix", r)).ToArray(), "DnsServers", new object[0], "DnsClients", new object[0], "Nrpt", new object[0]);
        }
        internal static void Run(string root)
        {
            var watch = Stopwatch.StartNew();
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
            var now = DateTime.UtcNow;
            var transport = D("ok", true, "active", "a", "updatedAt", now.ToString("o"), "helper", D("udp", false), "candidates", new[] { D("tag", "a", "state", "ok", "enabled", true) });
            Check(VpnTun.PathState(transport, now) == "no-udp", "TCP-only path refuses full VPN");
            Json.Map(transport["helper"])["udp"] = true;
            Check(VpnTun.PathState(transport, now) == "" && VpnTun.PathState(transport, now.AddSeconds(4)) == "no-path" && VpnTun.PathState(transport, now.AddSeconds(-1)) == "no-path", "only fresh checked path is accepted");
            var health = new VpnTunHealth(0);
            Check(!health.Sample(100, false, true) && health.Sample(200, true, false), "two mixed failures disable VPN");
            health = new VpnTunHealth(0);
            Check(!health.Sample(100, false, false) && !health.Sample(200, true, true) && !health.Sample(300, false, false) && health.Sample(400, false, false), "success resets failures");
            Check(health.Tick(400, false) == "core-exited", "core death disables immediately");
            health = new VpnTunHealth(0); Check(health.Tick(2501, true) == "watchdog-stalled", "lease expires without cycle progress");
            health.Pulse(10001); Check(health.Tick(10001, true) == "server-unreachable", "absolute health expires despite progress");
            var recovery = new VpnTunRecovery(); recovery.Stopped("server-unreachable");
            Check(!recovery.Observe(100, true) && !recovery.Observe(10099, true), "retry waits ten continuous seconds");
            Check(!recovery.Observe(10100, false) && !recovery.Observe(20000, true) && recovery.Observe(30000, true), "interruption restarts retry timer");
            recovery.Stopped("no-path"); Check(!recovery.Observe(50000, true) && !recovery.Observe(70000, true), "failed automatic attempt cannot rearm itself");
            foreach (string reason in new[] { "conflict", "no-udp", "core-exited", "off" }) { recovery.Reset(); recovery.Stopped(reason); Check(!recovery.Observe(0, true) && !recovery.Observe(20000, true), "no auto retry for " + reason); }
            recovery.Reset(); recovery.Stopped("no-path"); Check(!recovery.Observe(0, true) && recovery.Observe(10000, true), "explicit button restores one retry allowance");
            string command; Dictionary<string, object> request;
            Check(NetHelperProtocol.TryRequest(Json.Encode(settings.Request()) + "\r\n", out command, out request) && command == "vpn.on", "typed VPN command with CRLF");
            foreach (string invalid in new[] { "{\"cmd\":\"vpn.on\",\"socksPort\":17881,\"socksPort\":9}", "{\"cmd\":\"vpn.on\",\"socksPort\":17881,\"c\\u006dd\":\"vpn.off\"}", "{\"cmd\":\"vpn.on\",\"socksPort\":17881,\"path\":\"bad\"}", "{\"cmd\":\"vpn.on\",\"socksPort\":0}", "{\"cmd\":\"vpn.on\",\"socksPort\":17881,\"excludeCidrs\":[\"bad\"]}", "{\"cmd\":\"vpn.on\",\"socksPort\":17881,\"dnsServer\":{}}", "{\"cmd\":\"vpn.on\",\"socksPort\":17881,\"excludeCidrs\":{}}", "{\"cmd\":\"vpn.on\",\"socksPort\":\"17881\"}" })
                Check(!NetHelperProtocol.TryRequest(invalid, out command, out request), "reject malformed/duplicate/untyped privileged fields");
            var facts = new MainScreenFacts { VpnInstalled = true, Vpn = D("owner", "net-helper", "enabled", false, "state", "conflict", "conflictName", "Happ", "summary", VpnWatchdog.FailureSummary("conflict", "Happ")) };
            var view = MainScreenModel.Build(facts);
            Check(view.Vpn.Tone == Tone.Warning && view.Banner.Tone == Tone.Warning && view.Vpn.State.Contains("Happ") && view.Vpn.SwitchText == "Включить VPN", "yellow conflict card and tray facts name other VPN");
            string home = Path.Combine(root, "helper-vpn-status");
            Directory.CreateDirectory(Path.Combine(home, "status"));
            var serviceStatus = D("owner", "net-helper", "enabled", true, "ok", true, "state", "on", "updatedAt", DateTime.UtcNow.ToString("o"));
            Files.Atomic(Path.Combine(home, "status/vpn.json"), Json.Encode(serviceStatus));
            Check(Json.Str(VpnStatus.Read(home), "state") == "on", "helper status does not require a legacy host receipt");
            serviceStatus["updatedAt"] = DateTime.UtcNow.AddSeconds(-4).ToString("o");
            Files.Atomic(Path.Combine(home, "status/vpn.json"), Json.Encode(serviceStatus));
            Check(!Json.Bool(VpnStatus.Read(home), "enabled") && !File.Exists(Path.Combine(home, "state/vpn.stop")), "stale helper evidence is off without legacy stop side effects");
            string singbox = Environment.GetEnvironmentVariable("SINGBOX");
            if (!string.IsNullOrEmpty(singbox)) {
                Directory.CreateDirectory(root); string file = Path.Combine(root, "vpn-tun-check.json"); Files.Atomic(file, Json.Encode(config));
                using (var process = Process.Start(new ProcessStartInfo(singbox, Files.Arguments(new[] { "check", "-c", file })) { UseShellExecute = false })) {
                    Check(process.WaitForExit(3000), "sing-box check within budget"); Check(process.ExitCode == 0, "sing-box accepts generated config");
                }
            }
            Check(watch.ElapsedMilliseconds < 10000, "portable VPN tests within ten seconds");
            Console.WriteLine("PASS: VpnTun " + count + " checks (" + watch.ElapsedMilliseconds + " ms)");
        }
    }
}
