using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
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
            internal int Starts, Cleaned, Snapshots, Index = 7, Probes, TunnelChecks;
            internal bool Channel = true, Host = true, NrptOk = true, StartFails;
            internal LanDnsProbe Dns53 = LanDnsProbe.Open; internal int DnsProbes;
            internal object Config;
            internal Action BeforeStart;
            public LanTunSnapshot Snapshot() { Snapshots++; return SnapshotValue; }
            public Dictionary<string, object> Credentials() { return new Dictionary<string, object> { { "user", "fixture" }, { "password", "synthetic-only" } }; }
            public ILanTunCore Start(object config) { if (BeforeStart != null) BeforeStart(); Starts++; if (StartFails) throw new IOException(); Config = config; return Core = new Core(); }
            public void CleanAdapter() { Cleaned++; }
            public bool Nrpt(string command) { Commands.Add(command); return NrptOk; }
            public LanDnsProbe ProbeDns(string dnsServer) { DnsProbes++; return Dns53; }
            public int TunnelIndex() { TunnelChecks++; return Index; }
            public bool Probe(LanTunNetwork network, string[] subnets, int index) { Probes++; return Host && index == Index; }
            public bool ChannelReady() { return Channel; }
            public void Log(string stage, int code) { Stages.Add(stage); }
        }
        static byte[] ReadExactly(Stream stream, int length)
        {
            var bytes = new byte[length]; int offset = 0;
            while (offset < length) { int n = stream.Read(bytes, offset, length - offset); if (n == 0) throw new EndOfStreamException(); offset += n; }
            return bytes;
        }
        static bool Probe(int logicalPort, int timeoutMs, Action<NetworkStream> server, Action<long> elapsed = null)
        {
            var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
            try {
                var serve = Task.Run(() => { using (var c = listener.AcceptTcpClient()) { c.ReceiveTimeout = c.SendTimeout = 3000; try { server(c.GetStream()); } catch (IOException) { } } });
                using (var client = new TcpClient()) {
                    client.Connect(IPAddress.Loopback, ((IPEndPoint)listener.LocalEndpoint).Port);
                    var timer = Stopwatch.StartNew();
                    bool ok = LanProbe.Exchange(client.GetStream(), "portal.example.test", logicalPort, timeoutMs);
                    timer.Stop(); client.Close();
                    if (elapsed != null) elapsed(timer.ElapsedMilliseconds);
                    Check(serve.Wait(3000), "loopback server completed");
                    return ok;
                }
            } finally { listener.Stop(); }
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
                Check(MainScreenModel.LanTone(Rows(tun)) == Tone.Warning, "DNS warning is yellow despite IP connectivity");
                platform.NrptOk = true; now = 11000; tun.Tick();
                Check(Rows(tun).All(n => Json.Bool(n, "nrptOk") && Json.Str(n, "stage") == "") && MainScreenModel.LanTone(Rows(tun)) == Tone.Ok, "DNS recovery clears the last error and restores green");
            }
            now = 0; var retry = new LanTunRetry(() => now);
            foreach (int seconds in new[] { 1, 2, 5, 10, 30, 30, 30 }) { retry.Failed(); Check(!retry.Ready, "restart scheduled"); now += seconds * 1000 - 1; Check(!retry.Ready, "before retry deadline"); now++; Check(retry.Ready, "retry deadline"); }
            retry.Reset(); retry.Failed(); now += 1000; Check(retry.Ready, "reset retry sequence");
            platform = new Platform(); now = 0;
            using (var tun = new LanTun(platform, () => now)) {
                tun.Apply(request); platform.Core.Running = false; tun.Tick();
                Check(platform.Starts == 1 && platform.Stages.Contains("lan-core-exited"), "dead core waits before restart");
                now = 999; tun.Tick(); Check(platform.Starts == 1, "no early restart"); now++; tun.Tick(); Check(platform.Starts == 2 && platform.Snapshots == 2, "restart after 1 second with fresh route check");
                now = 2000; tun.Tick(); Check(platform.Stages.Contains("lan-adapter-ready") && Rows(tun).All(n => Json.Str(n, "stage") == ""), "adapter seen clears core-exited error");
                platform.Index = 0; now = 12000; tun.Tick(); Check(platform.Stages.Contains("lan-adapter-down") && Rows(tun).All(n => Json.Str(n, "state") == "failed"), "lost adapter after resume restarts core and is a fresh failure");
            }
            platform = new Platform { StartFails = true }; now = 0;
            using (var tun = new LanTun(platform, () => now)) {
                tun.Apply(request); Check(Rows(tun).All(n => Json.Str(n, "stage") == "lan-start"), "start error reported");
                now = 1000; tun.Tick(); now = 2999; tun.Tick(); Check(platform.Starts == 2, "second failure waits two seconds"); now++; tun.Tick(); Check(platform.Starts == 3, "second retry");
            }
            // Slow adapter: no failure inside the 30 s window, 1 s polling, start time counted after the real start.
            platform = new Platform { Index = 0 }; now = 0;
            platform.BeforeStart = () => now += 8000; // cleanup + config check took 8 s
            using (var tun = new LanTun(platform, () => now)) {
                tun.Apply(request);
                Check(Rows(tun).All(n => Json.Str(n, "state") == "starting"), "apply shows starting, not a failure");
                for (now = 9000; now <= 37000; now += 1000) tun.Tick();
                Check(!platform.Stages.Contains("lan-adapter-timeout") && !platform.Stages.Contains("lan-adapter-down") && platform.Starts == 1, "adapter wait counts from the real start");
                Check(platform.TunnelChecks == 29, "missing adapter is polled each second");
                Check(Rows(tun).All(n => Json.Str(n, "state") == "starting") && MainScreenModel.LanTone(Rows(tun)) == Tone.Warning, "starting is yellow");
                platform.Index = 7; now = 38000; tun.Tick();
                Check(Rows(tun).All(n => Json.Str(n, "state") == "ok" && Json.Str(n, "stage") == "") && MainScreenModel.LanTone(Rows(tun)) == Tone.Ok, "late adapter becomes ok without error");
            }
            // Adapter never appears: timeout, red, human text, automatic retry, and the error does not stick after success.
            platform = new Platform { Index = 0 }; now = 0;
            using (var tun = new LanTun(platform, () => now)) {
                tun.Apply(request);
                for (now = 1000; now < 30000; now += 1000) tun.Tick();
                Check(!platform.Stages.Contains("lan-adapter-timeout"), "no timeout before 30 s");
                now = 30000; tun.Tick();
                Check(platform.Stages.Contains("lan-adapter-timeout") && Rows(tun).All(n => Json.Str(n, "state") == "failed" && Json.Str(n, "reason").Contains("не появился")), "timeout after 30 s is a failure with plain text");
                Check(MainScreenModel.LanTone(Rows(tun)) == Tone.Error, "fresh failure is red");
                var card = MainScreenModel.Build(new MainScreenFacts { Lan = Decode(tun.Status()) });
                Check(card.Lan.Detail.Contains("не появился за 30 секунд") && !card.Lan.Detail.Contains("lan-adapter") && !card.Lan.State.Contains("failed"), "details show text, not codes");
                now = 31000; tun.Tick();
                Check(platform.Starts == 2 && Rows(tun).All(n => Json.Str(n, "state") == "starting" && Json.Str(n, "reason").Contains("повторное подключение")), "retry after 1 s is shown as starting");
                platform.Index = 7; now = 32000; tun.Tick();
                Check(Rows(tun).All(n => Json.Str(n, "state") == "ok" && Json.Str(n, "stage") == ""), "success clears the last error");
                var healed = MainScreenModel.Build(new MainScreenFacts { Lan = Decode(tun.Status()) });
                Check(healed.Lan.Tone == Tone.Ok && healed.Lan.Detail.Contains("Последняя ошибка: нет"), "healthy card is green with no stale error");
            }
            // Host that never answered is shown as starting during the grace period, then red host-down.
            platform = new Platform { Host = false }; now = 0;
            using (var tun = new LanTun(platform, () => now)) {
                tun.Apply(request); now = 1000; tun.Tick();
                Check(Rows(tun).All(n => Json.Str(n, "state") == "starting"), "no false host-down right after start");
                now = 16000; tun.Tick();
                Check(Rows(tun).All(n => Json.Str(n, "state") == "host-down" && Json.Str(n, "reason").Contains("не отвечает")) && MainScreenModel.LanTone(Rows(tun)) == Tone.Error, "host-down after grace is red");
            }
            DnsMode(request);
            HostsWithTun(request);
            ParseHosts(request);
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
            Check(view.Lan.Visible && view.Lan.Title == "Локальные сети" && view.Lan.State.Contains("office: работает") && !view.Lan.State.Contains(": ok") && view.Lan.State.Contains("помощник не установлен") && view.Lan.Detail.Contains("10.23.0.53") && view.Lan.Detail.Contains("не удалось запустить") && !view.Lan.Detail.Contains("lan-start"), "automatic multi-network card and details");
            foreach (string state in new[] { "starting", "channel-down", "busy", "no-helper" }) {
                var waiting = Decode(new { state = state, stage = "" });
                Check(MainScreenModel.LanTone(new[] { waiting }) == Tone.Warning, state + " is yellow");
                var failed = Decode(new { state = "failed", stage = "lan-start" });
                Check(MainScreenModel.LanTone(new[] { waiting, failed }) == Tone.Error, "fresh failure takes priority over " + state);
            }
            Check(MainScreenModel.LanTone(new Dictionary<string, object>[0]) == Tone.Warning, "empty LAN state is yellow");
            var probes = Stopwatch.StartNew();
            foreach (int port in new[] { 443, 465, 636, 993, 995, 5986, 8443 }) {
                Check(Probe(port, 1000, stream => {
                    var header = ReadExactly(stream, 5);
                    Check(header[0] == 0x16, "TLS ClientHello sent");
                    ReadExactly(stream, header[3] * 256 + header[4]);
                    var alert = new byte[] { 0x15, 3, 3, 0, 2, 2, 0x28 }; stream.Write(alert, 0, alert.Length);
                }), "ответ TLS подтверждает хост: " + port);
            }
            Check(!Probe(443, 1000, stream => { }), "закрытие без байтов = хост недоступен (как сбой dial на сервере)");
            Check(!Probe(443, 300, stream => Thread.Sleep(1500), ms => Check(ms < 1200, "молчание укладывается в бюджет")), "молчащий TLS не подтверждает хост");
            Check(Probe(53, 1000, stream => {
                var prefix = ReadExactly(stream, 2); int length = prefix[0] * 256 + prefix[1];
                Check(length == 17, "DNS TCP length 17");
                var query = ReadExactly(stream, length);
                Check(query[0] == 0x52 && query[1] == 0x41 && query[5] == 1 && query[12] == 0 && query[14] == 2 && query[16] == 1, "DNS root NS IN question");
                stream.Write(new byte[] { 0, 17 }, 0, 2);
            }), "ответ DNS по TCP подтверждает хост");
            foreach (int port in new[] { 80, 8080 }) {
                Check(Probe(port, 1000, stream => {
                    var requestText = new StringBuilder();
                    while (!requestText.ToString().EndsWith("\r\n\r\n", StringComparison.Ordinal) && requestText.Length < 4096) {
                        int b = stream.ReadByte(); if (b < 0) throw new EndOfStreamException(); requestText.Append((char)b);
                    }
                    Check(requestText.ToString().StartsWith("HEAD / HTTP/1.0\r\nHost: portal.example.test\r\n\r\n", StringComparison.Ordinal), "HTTP HEAD request");
                    var response = Encoding.ASCII.GetBytes("HTTP/1.0 200 OK\r\n\r\n"); stream.Write(response, 0, response.Length);
                }), "ответ HTTP подтверждает хост: " + port);
            }
            Check(Probe(22, 1000, stream => { var banner = Encoding.ASCII.GetBytes("SSH-2.0-x\r\n"); stream.Write(banner, 0, banner.Length); }), "баннер SSH подтверждает хост");
            Check(!Probe(22, 300, stream => { stream.ReadByte(); }, ms => Check(ms < 1200, "баннер укладывается в бюджет")), "молчащий SSH не подтверждает хост");
            Check(!LanProbe.Exchange(Stream.Null, "portal.example.test", 443, 0), "исчерпанный бюджет не запускает пробу");
            Check(probes.ElapsedMilliseconds < 5000, "protocol probes under 5 seconds");
            SingBoxCheck(config);
            Check(timer.ElapsedMilliseconds < 10000, "LAN tests under 10 seconds");
            Console.WriteLine("PASS: LanTun " + count + " checks, " + timer.ElapsedMilliseconds + " ms");
        }
        static bool Adds(Platform p) { return p.Commands.Any(c => c.Contains("Add-DnsClientNrptRule")); }
        // Port 53 blocked by another VPN client: NRPT is removed and stays away; it returns when the port opens.
        static void DnsMode(Dictionary<string, object> request)
        {
            long now = 0; var platform = new Platform { Dns53 = LanDnsProbe.Denied };
            using (var tun = new LanTun(platform, () => now)) {
                tun.Apply(request); Check(Adds(platform), "NRPT is installed before the first probe (default mode)");
                now = 1000; tun.Tick();
                Check(platform.DnsProbes == 1 && platform.Commands.Last() == LanTun.RemoveNrpt, "denied port 53 removes our NRPT");
                Check(Rows(tun).All(n => Json.Str(n, "dns") == "hosts" && Json.Bool(n, "nrptOk") && Json.Str(n, "state") == "ok" && !Json.Str(n, "reason").Contains("не настроены")), "hosts mode is reported and counts as configured names");
                platform.Commands.Clear(); now = 11000; tun.Tick(); now = 21000; tun.Tick();
                Check(!Adds(platform) && platform.DnsProbes == 1, "no NRPT and no extra probe within 60 s");
                platform.Dns53 = LanDnsProbe.Unknown; now = 61000; tun.Tick();
                Check(platform.DnsProbes == 2 && !Adds(platform) && Rows(tun).All(n => Json.Str(n, "dns") == "hosts"), "unknown probe result keeps the mode");
                platform.Dns53 = LanDnsProbe.Open; now = 121000; tun.Tick();
                Check(platform.DnsProbes == 3 && Adds(platform) && Rows(tun).All(n => Json.Str(n, "dns") == "nrpt" && Json.Bool(n, "nrptOk")), "open port 53 restores NRPT");
                platform.Channel = false; platform.Dns53 = LanDnsProbe.Denied; now = 181000; tun.Tick();
                Check(platform.DnsProbes == 3, "no probe while the channel is down");
            }
        }
        // The service owns the hosts block: written while the channel is up, kept through a blip, removed on stop.
        static void HostsWithTun(Dictionary<string, object> request)
        {
            var named = Json.Map(Json.Parse(Json.Encode(request)));
            Json.Map(Json.Array(named["networks"])[0])["hosts"] = new[] { "portal.office.test" };
            var fake = new FakeHosts { Dns = { { "portal.office.test", new[] { "10.23.0.80" } } } };
            fake.Text = "127.0.0.1 localhost\r\n";
            long now = 0; var platform = new Platform();
            using (var tun = new LanTun(platform, () => now, new LanHosts(fake, a => a()))) {
                Check(Json.Bool(Decode(tun.Apply(named)), "ok"), "apply with hosts");
                now = 1000; tun.Tick();
                Check(fake.Text.Contains("10.23.0.80 portal.office.test # RemoteAgents:office") && fake.Writes == 1, "block written after the channel is ready");
                Check(Rows(tun).Single(n => Json.Str(n, "name") == "office")["hostsNames"].Equals(1) && Json.Str(Rows(tun)[0], "hostsUpdated").Length > 0, "status shows names and update time");
                platform.Channel = false; now = 11000; tun.Tick(); now = 21000; tun.Tick();
                Check(fake.Text.Contains("portal.office.test") && fake.Writes == 1, "channel blip leaves the block");
                platform.Channel = true; now = 31000; tun.Tick();
                var again = Json.Map(Json.Parse(Json.Encode(request)));
                tun.Apply(again); Check(!fake.Text.Contains("RemoteAgents:lan"), "lan.apply without names removes the block");
                tun.Apply(named); now = 40000; tun.Tick(); Check(fake.Text.Contains("portal.office.test"), "names back");
                tun.Stop(); Check(fake.Text == "127.0.0.1 localhost\r\n", "stop removes the block");
            }
        }
        static void ParseHosts(Dictionary<string, object> request)
        {
            var six = LanTunNetwork.Parse(request);
            Check(six.All(n => n.Hosts.Length == 0), "six keys parse with no names (older tray)");
            var seven = Json.Map(Json.Parse(Json.Encode(request)));
            Json.Map(Json.Array(seven["networks"])[0])["hosts"] = new[] { "portal.office.test", "a.b.office.test" };
            var parsed = LanTunNetwork.Parse(seven);
            Check(parsed[0].Hosts.SequenceEqual(new[] { "portal.office.test", "a.b.office.test" }) && parsed[1].Hosts.Length == 0, "seven keys carry the names");
            Func<Action<Dictionary<string, object>>, bool> rejected = edit => {
                var r = Json.Map(Json.Parse(Json.Encode(request))); edit(Json.Map(Json.Array(r["networks"])[0]));
                try { LanTunNetwork.Parse(r); return false; } catch (InvalidDataException) { return true; }
            };
            Check(rejected(m => m["hosts"] = new[] { "*.office.test" }) && rejected(m => m["hosts"] = new[] { "x.example.org" }) && rejected(m => m["hosts"] = new[] { "A.office.test" })
                && rejected(m => m["hosts"] = new[] { "a.office.test", "a.office.test" }) && rejected(m => m["hosts"] = new object[] { 5 }) && rejected(m => m["hosts"] = "a.office.test")
                && rejected(m => m["hosts"] = Enumerable.Range(0, 101).Select(i => "h" + i + ".office.test").ToArray()) && rejected(m => m["extra"] = new string[0]),
                "bad names, duplicates, non-lists, more than 100 and unknown keys are refused");
            Check(!rejected(m => m["hosts"] = Enumerable.Range(0, 100).Select(i => "h" + i + ".office.test").ToArray()), "exactly 100 names allowed");
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
            if (args.Length == 1 && args[0] == "--lan-hosts") { LanHostsTests.Run(); return 0; }
            if (args.Length == 6 && args[0] == "--lan-hosts-resolve") return LanHostsTests.Resolve(args);
            // Focused UI/tick coverage without running unrelated disk/update suites.
            if (args.Length == 2 && args[0] == "--lan-ui") {
                MainScreenModelTests.Run(); LanTickTests.Run(args[1]); return 0;
            }
            if (args.Length == 0 || !args[0].StartsWith("--", StringComparison.Ordinal)) { Run(); LanHostsTests.Run(); }
            try { return (int)typeof(NetHelperTests).GetMethod("Main", BindingFlags.Static | BindingFlags.NonPublic).Invoke(null, new object[] { args }); }
            catch (TargetInvocationException ex) { ExceptionDispatchInfo.Capture(ex.InnerException).Throw(); throw; }
        }
    }
}
