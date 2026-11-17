using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.ExceptionServices;

namespace RemoteAgents.Launcher
{
    internal static class LanTunTests
    {
        static int count;
        static void Check(bool condition, string name) { if (!condition) throw new Exception("LanTun: " + name); count++; }
        static Dictionary<string, object> Row(string name, string subnet, string dns, string domain, string host)
        { return new Dictionary<string, object> { { "name", name }, { "subnets", new[] { subnet } }, { "domains", new[] { domain } }, { "dnsServers", new[] { dns } }, { "testHost", host }, { "testPort", 443 } }; }
        static Dictionary<string, object> Request()
        { return Json.Map(Json.Parse(Json.Encode(new { cmd = "lan.apply", socksPort = 17880, networks = new[] { Row("office", "10.23.0.0/16", "10.23.0.53", "*.office.test", "10.23.0.2"), Row("lab", "192.168.45.0/24", "192.168.45.53", "lab.test", "pc.lab.test") } }))); }
        static Dictionary<string, object> Decode(object value) { return Json.Map(Json.Parse(Json.Encode(value))); }
        static Dictionary<string, object>[] Rows(LanTun tun) { return Json.Array(Json.Get(tun.Status(), "networks")).Select(Json.Map).ToArray(); }
        sealed class Core : ILanTunCore
        {
            internal bool Running = true;
            public bool Alive { get { return Running; } }
            public void Dispose() { Running = false; }
        }
        sealed class Platform : ILanTunPlatform
        {
            internal LanTunSnapshot SnapshotValue = new LanTunSnapshot();
            internal readonly List<string> Commands = new List<string>(), Stages = new List<string>();
            internal Core Core;
            internal int Starts, Cleaned, Snapshots, Index = 7, Probes;
            internal bool Channel = true, Host = true, NrptOk = true, StartFails;
            internal object Config;
            public LanTunSnapshot Snapshot() { Snapshots++; return SnapshotValue; }
            public Dictionary<string, object> Credentials() { return new Dictionary<string, object> { { "user", "fixture" }, { "password", "synthetic-only" } }; }
            public ILanTunCore Start(object config) { Starts++; if (StartFails) throw new IOException(); Config = config; return Core = new Core(); }
            public void CleanAdapter() { Cleaned++; }
            public bool Nrpt(string command) { Commands.Add(command); return NrptOk; }
            public int TunnelIndex() { return Index; }
            public bool Probe(LanTunNetwork network, string[] subnets, int index) { Probes++; return Host && index == Index; }
            public bool ChannelReady() { return Channel; }
            public void Log(string stage, int code) { Stages.Add(stage); }
        }
        internal static void Run()
        {
            var timer = Stopwatch.StartNew();
            var request = Request(); var networks = LanTunNetwork.Parse(request);
            var selected = networks.ToDictionary(n => n.Name, n => n.Subnets);
            var config = Decode(LanTun.Config(networks, selected, 17880, new Platform().Credentials(), "172.31.254.1/30", "/tmp/lan-fixture.log"));
            var inbound = Json.Map(Json.Array(Json.Get(config, "inbounds"))[0]);
            Check(Json.Str(inbound, "interface_name") == "RemoteAgents-LAN" && Json.Bool(inbound, "auto_route") && !Json.Bool(inbound, "strict_route") && Json.Str(inbound, "stack") == "system", "narrow system TUN");
            Check(Json.Strings(Json.Get(inbound, "route_address")).SequenceEqual(new[] { "10.23.0.0/16", "192.168.45.0/24" }) && !Json.Encode(config).Contains("0.0.0.0/0"), "two LANs and no default route");
            var socks = Json.Map(Json.Array(Json.Get(config, "outbounds"))[0]);
            Check(Json.Str(socks, "server") == "127.0.0.1" && Json.Int(socks, "server_port", 0) == 17880 && Json.Str(socks, "version") == "5" && Json.Str(socks, "username") == "fixture" && Json.Str(socks, "password") == "synthetic-only", "authenticated loopback SOCKS");
            var dns = Json.Map(Json.Get(config, "dns"));
            Check(Json.Array(Json.Get(dns, "servers")).Select(Json.Map).All(d => Json.Str(d, "type") == "tcp" && Json.Str(d, "detour") == "socks"), "TCP DNS through SOCKS");
            var route = Json.Map(Json.Get(config, "route")); var hijack = Json.Map(Json.Array(Json.Get(route, "rules"))[0]);
            Check(Json.Str(route, "final") == "socks" && Json.Str(hijack, "action") == "hijack-dns" && Json.Strings(Json.Get(hijack, "ip_cidr")).SequenceEqual(new[] { "10.23.0.53/32", "192.168.45.53/32" }) && Json.Array(Json.Get(hijack, "port")).Length == 1 && Json.Int(new Dictionary<string, object> { { "p", Json.Array(Json.Get(hijack, "port"))[0] } }, "p", 0) == 53, "hijack only LAN DNS port 53");
            var suffixRules = Json.Array(Json.Get(dns, "rules")).Select(Json.Map).ToArray();
            Check(suffixRules.Length == 2 && Json.Str(suffixRules[1], "server") == "lan-dns-1", "each LAN uses its own DNS");

            var snapshot = new LanTunSnapshot();
            snapshot.Routes.Add(new LanTunRoute("0.0.0.0/0", "Happ")); snapshot.Routes.Add(new LanTunRoute("0.0.0.0/1", "Happ")); snapshot.Routes.Add(new LanTunRoute("128.0.0.0/1", "Happ"));
            snapshot.Routes.Add(new LanTunRoute("10.23.0.0/16", LanTun.InterfaceName)); snapshot.Addresses.Add(new LanTunRoute("172.31.254.1/32", LanTun.InterfaceName));
            Check(snapshot.Busy("10.23.0.0/16") == "", "foreign full VPN and own TUN ignored");
            snapshot.Addresses.Add(new LanTunRoute("10.23.1.5/32", "Wi-Fi дома"));
            Check(snapshot.Busy("10.23.0.0/16") == "Wi-Fi дома", "physical address conflict without route");
            snapshot.Routes.Add(new LanTunRoute("192.168.0.0/16", "Corporate VPN"));
            Check(snapshot.Busy("192.168.45.0/24") == "Corporate VPN", "overlapping foreign supernet");
            snapshot.Routes.Add(new LanTunRoute("10.24.0.4/32", "Office"));
            Check(snapshot.Busy("10.24.0.0/24") == "Office", "foreign host route also conflicts");
            var parsedRoutes = new LanTunSnapshot();
            parsedRoutes.ReadRoutePrint("Активные маршруты:\r\n  0.0.0.0  0.0.0.0  192.168.1.1 192.168.1.3 25\r\n 10.23.0.0 255.255.0.0 В сети 192.168.1.3 5\r\n", new Dictionary<string, string> { { "192.168.1.3", "Wi-Fi" } });
            Check(parsedRoutes.Routes.Count == 2 && parsedRoutes.Busy("10.23.1.0/24") == "Wi-Fi", "localized route print and CRLF");
            bool noTable = false; try { new LanTunSnapshot().ReadRoutePrint("not a route table", new Dictionary<string, string>()); } catch (IOException) { noTable = true; }
            Check(noTable, "unreadable route table fails closed");
            snapshot.Addresses.Add(new LanTunRoute("172.31.254.1/32", "Ethernet"));
            Check(LanTun.Address(snapshot, new string[0]) == "172.31.254.5/30", "next free /30");

            var profile = new Dictionary<string, object> { { "lan", new object[] {
                new { name = "office", testHost = "10.23.0.2", testPort = 443, share = new { enabled = true, subnets = new[] { "10.23.0.0/16" }, domains = new[] { "office.test" }, dnsServers = new[] { "10.23.0.53" } } },
                new { name = "lab", testHost = "192.168.45.2", testPort = 443, share = new { enabled = false, subnets = new[] { "192.168.45.0/24" }, domains = new string[0], dnsServers = new string[0] } }
            } } };
            var wanted = LanTunNetwork.Request(Decode(profile), 17890);
            Check(Json.Array(Json.Get(wanted, "networks")).Length == 1 && LanTunNetwork.Parse(Decode(wanted)).Length == 1, "disabled network never sent");
            Check(Json.Str(LanTunNetwork.Request(Json.Map(null), 0), "cmd") == "lan.stop", "empty config stops LAN");

            long now = 100; var platform = new Platform();
            using (var tun = new LanTun(platform, () => now)) {
                Check(Json.Bool(Decode(tun.Apply(request)), "ok") && platform.Starts == 1 && platform.Cleaned == 1, "apply starts service-built core after cleanup");
                Check(platform.Commands[0] == LanTun.RemoveNrpt && platform.Commands.Any(c => c.Contains("-Namespace '.office.test'") && c.Contains("-Comment 'RemoteAgents:office'") && c.Contains("-NameServers '10.23.0.53'")), "NRPT normalized wildcard, scoped comment and DNS");
                Check(LanTun.RemoveNrpt.Contains("$_.Comment -like 'RemoteAgents:*'") && !LanTun.RemoveNrpt.Contains("Get-DnsClientNrptRule | Remove"), "remove only owned rules");
                now += 1000; tun.Tick();
                Check(Rows(tun).All(n => Json.Str(n, "state") == "ok" && Json.Bool(n, "nrptOk")), "healthy networks");
                platform.Host = false; now += 10000; tun.Tick();
                Check(Rows(tun).All(n => Json.Str(n, "state") == "host-down") && platform.Core.Alive && platform.Starts == 1, "host failure does not disable TUN");
                platform.Channel = false; now += 10000; tun.Tick();
                Check(Rows(tun).All(n => Json.Str(n, "state") == "channel-down" && !Json.Bool(n, "nrptOk")) && platform.Commands.Last() == LanTun.RemoveNrpt && platform.Core.Alive, "channel loss removes NRPT but keeps narrow routes");
                platform.Channel = platform.Host = true; now += 10000; tun.Tick();
                Check(Rows(tun).All(n => Json.Str(n, "state") == "ok" && Json.Bool(n, "nrptOk")), "channel recovery restores DNS names");
                platform.SnapshotValue.Addresses.Add(new LanTunRoute("10.23.0.9/32", "Wi-Fi")); now += 30000; tun.Tick();
                var office = Rows(tun).Single(n => Json.Str(n, "name") == "office");
                Check(Json.Str(office, "state") == "busy" && Json.Str(office, "reason").Contains("адреса заняты") && Json.Strings(Json.Get(office, "connectedSubnets")).Length == 0 && Json.Array(Json.Get(office, "excludedSubnets")).Length == 1, "periodic conflict excludes just affected subnet");
                Check(!Json.Encode(platform.Config).Contains("10.23.0.0/16") && Json.Encode(platform.Config).Contains("192.168.45.0/24"), "free LAN remains configured");
                var dead = platform.Core; tun.Stop(); Check(!dead.Alive && platform.Commands.Last() == LanTun.RemoveNrpt && !Json.Bool(tun.Status(), "enabled"), "stop closes core and NRPT");
            }
            var partial = Request(); Json.Map(Json.Array(partial["networks"])[0])["subnets"] = new[] { "10.23.0.0/16", "10.24.0.0/16" };
            platform = new Platform(); platform.SnapshotValue.Addresses.Add(new LanTunRoute("10.23.0.9/32", "Ethernet")); now = 0;
            using (var tun = new LanTun(platform, () => now)) {
                tun.Apply(partial); now = 1000; tun.Tick();
                var office = Rows(tun).Single(n => Json.Str(n, "name") == "office");
                Check(Json.Strings(Json.Get(office, "connectedSubnets")).SequenceEqual(new[] { "10.24.0.0/16" }) && Json.Str(office, "state") == "busy" && !Json.Str(office, "reason").Contains("адреса заняты"), "partial conflict keeps free subnet");
                Check(!Json.Bool(office, "nrptOk") && !Json.Encode(platform.Config).Contains("10.23.0.53"), "DNS on excluded subnet is not installed or hijacked");
                platform.SnapshotValue.Addresses.Clear(); now = 31000; tun.Tick(); now = 32000; tun.Tick();
                Check(Rows(tun).All(n => Json.Str(n, "state") == "ok") && platform.Starts == 2, "freed subnet automatically reconnects");
            }
            platform = new Platform { NrptOk = false }; now = 0;
            using (var tun = new LanTun(platform, () => now)) {
                tun.Apply(request); now = 1000; tun.Tick();
                Check(platform.Core.Alive && Rows(tun).All(n => Json.Str(n, "reason").Contains("не настроены") && Json.Str(n, "stage") == "lan-nrpt"), "NRPT failure preserves IP connectivity with error stage");
            }
            now = 0; var retry = new LanTunRetry(() => now);
            foreach (int seconds in new[] { 1, 2, 5, 10, 30, 30, 30 }) { retry.Failed(); Check(!retry.Ready, "restart scheduled"); now += seconds * 1000 - 1; Check(!retry.Ready, "before retry deadline"); now++; Check(retry.Ready, "retry deadline"); }
            retry.Reset(); retry.Failed(); now += 1000; Check(retry.Ready, "reset retry sequence");
            platform = new Platform(); now = 0;
            using (var tun = new LanTun(platform, () => now)) {
                tun.Apply(request); platform.Core.Running = false; tun.Tick();
                Check(platform.Starts == 1 && platform.Stages.Contains("lan-core-exited"), "dead core waits before restart");
                now = 999; tun.Tick(); Check(platform.Starts == 1, "no early restart"); now++; tun.Tick(); Check(platform.Starts == 2 && platform.Snapshots == 2, "restart after 1 second with fresh route check");
                platform.Index = 0; now = 12000; tun.Tick(); Check(platform.Stages.Contains("lan-adapter-down"), "missing adapter after resume restarts core");
            }
            platform = new Platform { StartFails = true }; now = 0;
            using (var tun = new LanTun(platform, () => now)) {
                tun.Apply(request); Check(Rows(tun).All(n => Json.Str(n, "stage") == "lan-start"), "start error reported");
                now = 1000; tun.Tick(); now = 2999; tun.Tick(); Check(platform.Starts == 2, "second failure waits two seconds"); now++; tun.Tick(); Check(platform.Starts == 3, "second retry");
            }
            int executed = 0;
            Func<string, Dictionary<string, object>, string> execute = (command, r) => { executed++; return Json.Encode(new { ok = true }); };
            string valid = Json.Encode(request);
            Check(Json.Bool(Json.Map(Json.Parse(NetHelperProtocol.Reply(valid + "\r\n", () => new string[0], execute))), "ok") && executed == 1, "wire apply with CRLF");
            Check(Json.Bool(Json.Map(Json.Parse(NetHelperProtocol.Reply("{\"cmd\":\"lan.stop\"}", () => new string[0], execute))), "ok"), "wire stop");
            foreach (var edit in new Action<Dictionary<string, object>>[] {
                r => r["socksPort"] = 0, r => r["socksPort"] = "17880", r => r["extra"] = "no", r => r["networks"] = "no",
                r => Json.Map(Json.Array(r["networks"])[0])["name"] = "office;", r => Json.Map(Json.Array(r["networks"])[0])["subnets"] = new[] { "8.8.8.0/24" },
                r => Json.Map(Json.Array(r["networks"])[0])["subnets"] = new[] { "10.23.0.1/16" }, r => Json.Map(Json.Array(r["networks"])[0])["subnets"] = new[] { "10.23.0.0/+16" },
                r => Json.Map(Json.Array(r["networks"])[0])["dnsServers"] = new[] { "10.24.0.53" }, r => Json.Map(Json.Array(r["networks"])[0])["testHost"] = "10.24.0.2",
                r => Json.Map(Json.Array(r["networks"])[0])["testHost"] = "::1", r => Json.Map(Json.Array(r["networks"])[0])["testHost"] = "external.test",
                r => Json.Map(Json.Array(r["networks"])[0])["domains"] = new[] { "x';whoami" }, r => Json.Map(Json.Array(r["networks"])[0])["testPort"] = 65536,
                r => Json.Map(Json.Array(r["networks"])[0])["subnets"] = new object[] { 1 }, r => Json.Map(Json.Array(r["networks"])[1])["name"] = "office"
            }) { var invalid = Request(); edit(invalid); int before = executed; Check(NetHelperProtocol.Reply(Json.Encode(invalid), () => new string[0], execute) == NetHelperProtocol.BadRequest && before == executed, "invalid input cannot execute"); }
            foreach (var invalid in new[] { valid.Replace("\"cmd\":", "\"cmd\":\"status\",\"cmd\":"), valid.Replace("\"name\":\"office\"", "\"name\":\"lab\",\"n\\u0061me\":\"office\""), valid.Replace("\"socksPort\":", "\"socksPort\":1,\"socksPort\":"), valid.Substring(0, valid.Length - 1) + ",}", "/*x*/" + valid, "{cmd:'lan.apply'}", "{\"cmd\":\"lan.apply\"}" })
                Check(NetHelperProtocol.Reply(invalid, () => new string[0], execute) == NetHelperProtocol.BadRequest, "strict JSON rejects duplicates and non-JSON syntax");

            var statuses = new Dictionary<string, object> { { "enabled", true }, { "networks", new object[] { new { name = "office", state = "ok", reason = "работает", connectedSubnets = new[] { "10.23.0.0/16" }, dnsServers = new[] { "10.23.0.53" }, nrptOk = true }, new { name = "lab", state = "no-helper", reason = "помощник не установлен", stage = "lan-start" } } } };
            statuses = Decode(statuses); // Same JSON boundary as the real helper response.
            Check(StatusView.Lan(statuses) == "Локальные сети: 1 из 2 работают", "tray aggregate");
            var view = MainScreenModel.Build(new MainScreenFacts { Lan = statuses });
            Check(view.Lan.Visible && view.Lan.Title == "Локальные сети" && view.Lan.State.Contains("office: ok") && view.Lan.State.Contains("помощник не установлен") && view.Lan.Detail.Contains("10.23.0.53") && view.Lan.Detail.Contains("lan-start"), "automatic multi-network card and details");
            SingBoxCheck(config);
            Check(timer.ElapsedMilliseconds < 10000, "LAN tests under 10 seconds");
            Console.WriteLine("PASS: LanTun " + count + " checks, " + timer.ElapsedMilliseconds + " ms");
        }
        static void SingBoxCheck(object config)
        {
            string binary = Environment.GetEnvironmentVariable("SINGBOX");
            if (string.IsNullOrEmpty(binary)) { Console.WriteLine("SKIP: LanTun sing-box check (SINGBOX absent)"); return; }
            string file = Path.Combine(Path.GetTempPath(), "lan-check-" + Guid.NewGuid().ToString("N") + ".json");
            try {
                File.WriteAllText(file, Json.Encode(config));
                using (var process = Process.Start(new ProcessStartInfo(binary, Files.Arguments(new[] { "check", "-c", file })) { UseShellExecute = false, RedirectStandardError = true, RedirectStandardOutput = true })) {
                    var stderr = process.StandardError.ReadToEndAsync(); var stdout = process.StandardOutput.ReadToEndAsync();
                    if (!process.WaitForExit(3000)) { process.Kill(); throw new Exception("LanTun: sing-box check timeout"); }
                    Check(process.ExitCode == 0, "real sing-box check: " + stderr.GetAwaiter().GetResult() + stdout.GetAwaiter().GetResult());
                }
            } finally { File.Delete(file); }
        }
        // Preserve all existing portable modes and suites. --lan-tun is a focused optional mode.
        static int Main(string[] args)
        {
            if (args.Length == 1 && args[0] == "--lan-tun") { Run(); return 0; }
            if (args.Length == 0 || !args[0].StartsWith("--", StringComparison.Ordinal)) Run();
            try { return (int)typeof(NetHelperTests).GetMethod("Main", BindingFlags.Static | BindingFlags.NonPublic).Invoke(null, new object[] { args }); }
            catch (TargetInvocationException ex) { ExceptionDispatchInfo.Capture(ex.InnerException).Throw(); throw; }
        }
    }
}
