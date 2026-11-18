using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
#if !PORTABLE_TEST
using System.Runtime.InteropServices;
#endif

namespace RemoteAgents.Launcher
{
    // Human texts for helper stage codes. Codes stay in helper.log; the UI shows only these texts.
    internal static class LanStages
    {
        internal const int AdapterWaitSeconds = 30;
        internal static bool IsCore(string stage)
        { return stage == "lan-start" || stage == "lan-core-exited" || stage == "lan-adapter-timeout" || stage == "lan-adapter-down" || stage == "lan-watchdog"; }
        internal static string Text(string stage)
        {
            switch (stage ?? "") {
                case "": return "нет";
                case "lan-start": return "не удалось запустить подключение к локальным сетям";
                case "lan-core-exited": return "подключение к локальным сетям неожиданно остановилось";
                case "lan-adapter-timeout": return "сетевой адаптер RemoteAgents-LAN не появился за " + AdapterWaitSeconds + " секунд";
                case "lan-adapter-down": return "сетевой адаптер RemoteAgents-LAN пропал (например, после сна компьютера)";
                case "lan-watchdog": return "не удалось проверить сетевые маршруты компьютера";
                case "lan-nrpt": return "не удалось настроить имена сети (DNS)";
                case "lan-nrpt-remove": return "не удалось убрать прежние настройки имён сети (DNS)";
                default: return "внутренняя ошибка (" + stage + ")";
            }
        }
    }

    internal sealed class LanTunNetwork
    {
        internal string Name, TestHost;
        internal int TestPort;
        internal string[] Subnets, Domains, DnsServers;
        internal static LanTunNetwork[] Parse(Dictionary<string, object> request)
        {
            if (request.Count != 3 || !request.ContainsKey("cmd") || !request.ContainsKey("networks") || !request.ContainsKey("socksPort")) throw new InvalidDataException();
            int port = Json.Int(request, "socksPort", 0);
            if (Json.Get(request, "socksPort") is string || port < 1 || port > 65535) throw new InvalidDataException();
            var rows = Json.Get(request, "networks") as object[];
            if (rows == null || rows.Length > 64) throw new InvalidDataException();
            var names = new HashSet<string>(); var all = new List<string>(); var result = new List<LanTunNetwork>();
            foreach (var row in rows) {
                var map = Json.Map(row);
                string[] keys = { "name", "subnets", "domains", "dnsServers", "testHost", "testPort" };
                if (map.Count != keys.Length || keys.Any(k => !map.ContainsKey(k)) || !(map["name"] is string) || !(map["testHost"] is string)) throw new InvalidDataException();
                var n = new LanTunNetwork { Name = Json.Str(map, "name"), TestHost = Json.Str(map, "testHost"), TestPort = Json.Int(map, "testPort", 0), Subnets = Strings(map, "subnets"), Domains = Strings(map, "domains"), DnsServers = Strings(map, "dnsServers") };
                if (!Regex.IsMatch(n.Name, @"\A[a-z][a-z0-9]{0,6}\z") || !names.Add(n.Name) || n.Subnets.Length == 0 || n.Subnets.Length > 64 || n.Domains.Length > 64 || n.DnsServers.Length > 4 || map["testPort"] is string || n.TestPort < 1 || n.TestPort > 65535) throw new InvalidDataException();
                foreach (var subnet in n.Subnets) {
                    LanAccess.Cidr(subnet);
                    if (subnet != LanTun.IP(LanAccess.IPv4(subnet.Split('/')[0])) + "/" + int.Parse(subnet.Split('/')[1], CultureInfo.InvariantCulture)) throw new InvalidDataException();
                    if (all.Any(s => LanTun.Overlap(s, subnet))) throw new InvalidDataException();
                    all.Add(subnet);
                }
                foreach (string dns in n.DnsServers) if (!n.Subnets.Any(s => LanTun.Contains(s, LanAccess.IPv4(dns)))) throw new InvalidDataException();
                foreach (string domain in n.Domains) LanAccess.Domain(domain);
                if (n.Domains.Length > 0 && n.DnsServers.Length == 0) throw new InvalidDataException();
                IPAddress address;
                if (IPAddress.TryParse(n.TestHost, out address)) {
                    if (address.AddressFamily != AddressFamily.InterNetwork || !n.Subnets.Any(s => LanTun.Contains(s, LanAccess.IPv4(n.TestHost)))) throw new InvalidDataException();
                } else {
                    LanAccess.Domain(n.TestHost);
                    if (!n.Domains.Any(d => n.TestHost.Equals(d.TrimStart('*', '.'), StringComparison.OrdinalIgnoreCase) || n.TestHost.EndsWith("." + d.TrimStart('*', '.'), StringComparison.OrdinalIgnoreCase))) throw new InvalidDataException();
                }
                result.Add(n);
            }
            return result.ToArray();
        }
        static string[] Strings(Dictionary<string, object> map, string key)
        {
            var array = Json.Get(map, key) as object[];
            if (array == null || array.Any(v => !(v is string))) throw new InvalidDataException();
            return array.Cast<string>().ToArray();
        }
        internal static Dictionary<string, object> Request(Dictionary<string, object> profile, int port)
        {
            var networks = LanAccess.Read(profile).Networks.Where(n => Json.Bool(n, "enabled") && Json.Strings(Json.Get(n, "subnets")).Length > 0)
                .Select(n => (object)n.Where(p => p.Key != "enabled").ToDictionary(p => p.Key, p => p.Value)).ToArray();
            return networks.Length == 0 ? new Dictionary<string, object> { { "cmd", "lan.stop" } } : new Dictionary<string, object> { { "cmd", "lan.apply" }, { "networks", networks }, { "socksPort", port } };
        }
    }

    internal sealed class LanTunRoute
    {
        internal string Subnet, Adapter;
        internal LanTunRoute(string subnet, string adapter) { Subnet = subnet; Adapter = adapter; }
    }
    internal sealed class LanTunSnapshot
    {
        internal readonly List<LanTunRoute> Routes = new List<LanTunRoute>(), Addresses = new List<LanTunRoute>();
        internal void ReadRoutePrint(string output, Dictionary<string, string> addresses)
        {
            int recognized = 0;
            foreach (string line in output.Replace("\r", "").Split('\n')) {
                var fields = Regex.Split(line.Trim(), @"\s+");
                if (fields.Length < 5) continue;
                try {
                    uint destination = LanAccess.IPv4(fields[0]), mask = LanAccess.IPv4(fields[1]);
                    string name;
                    if (!addresses.TryGetValue(fields[fields.Length - 2], out name)) continue;
                    int bits = Enumerable.Range(0, 33).First(b => LanTun.Mask(b) == mask);
                    if ((destination & mask) != destination) throw new IOException();
                    Routes.Add(new LanTunRoute(fields[0] + "/" + bits, name)); recognized++;
                } catch (InvalidDataException) { } catch (InvalidOperationException) { }
            }
            if (recognized == 0) throw new IOException("Нет таблицы маршрутов IPv4");
        }
        internal string Busy(string subnet)
        {
            var route = Routes.FirstOrDefault(r => r.Adapter != LanTun.InterfaceName && LanTun.Prefix(r.Subnet) > 1 && LanTun.Overlap(subnet, r.Subnet));
            if (route == null) route = Addresses.FirstOrDefault(r => r.Adapter != LanTun.InterfaceName && LanTun.Overlap(subnet, r.Subnet));
            return route == null ? "" : route.Adapter;
        }
    }
    internal interface ILanTunCore : IDisposable { bool Alive { get; } }
    internal interface ILanTunPlatform
    {
        LanTunSnapshot Snapshot();
        Dictionary<string, object> Credentials();
        ILanTunCore Start(object config);
        void CleanAdapter();
        bool Nrpt(string command);
        int TunnelIndex();
        bool Probe(LanTunNetwork network, string[] subnets, int index);
        bool ChannelReady();
        void Log(string stage, int code);
    }
    internal sealed class LanTunRetry
    {
        readonly Func<long> clock;
        int failures;
        long next;
        internal LanTunRetry(Func<long> clock) { this.clock = clock; }
        internal bool Ready { get { return clock() >= next; } }
        internal void Failed() { int[] seconds = { 1, 2, 5, 10, 30 }; next = clock() + seconds[Math.Min(failures++, seconds.Length - 1)] * 1000L; }
        internal void Reset() { failures = 0; next = 0; }
    }

    // Own code is limited to Windows lifetime/policy; sing-box implements TUN, SOCKS and DNS.
    // All entry points serialize here; slow work is dispatched off the service's lease thread.
    internal sealed class LanTun : IDisposable
    {
        internal const string InterfaceName = "RemoteAgents-LAN";
        internal const long AdapterWaitMs = LanStages.AdapterWaitSeconds * 1000L, StartupGraceMs = 15000;
        internal const string RemoveNrpt = "$ErrorActionPreference='Stop'; Get-DnsClientNrptRule | Where-Object { $_.Comment -like 'RemoteAgents:*' } | Remove-DnsClientNrptRule -Force";
        readonly object gate = new object();
        readonly ILanTunPlatform platform;
        readonly Func<long> clock;
        readonly LanTunRetry retry;
        LanTunNetwork[] networks = new LanTunNetwork[0];
        readonly Dictionary<string, string[]> connected = new Dictionary<string, string[]>();
        readonly Dictionary<string, Dictionary<string, object>> states = new Dictionary<string, Dictionary<string, object>>();
        ILanTunCore core;
        int port;
        string signature = "", tunAddress = "";
        long nextRoutes, nextHealth, started;
        volatile bool disposed;
        bool nrptDirty;
        bool adapterSeen;
        readonly HashSet<string> reached = new HashSet<string>();
        volatile Dictionary<string, object> published = new Dictionary<string, object>();
        internal LanTun(ILanTunPlatform platform, Func<long> clock) { this.platform = platform; this.clock = clock; retry = new LanTunRetry(clock); }
        internal static int Prefix(string subnet) { return int.Parse(subnet.Split('/')[1], CultureInfo.InvariantCulture); }
        internal static uint Mask(int bits) { return bits == 0 ? 0 : uint.MaxValue << (32 - bits); }
        internal static bool Contains(string subnet, uint ip) { return (ip & Mask(Prefix(subnet))) == LanAccess.IPv4(subnet.Split('/')[0]); }
        internal static bool Overlap(string a, string b) { uint mask = Mask(Math.Min(Prefix(a), Prefix(b))); return (LanAccess.IPv4(a.Split('/')[0]) & mask) == (LanAccess.IPv4(b.Split('/')[0]) & mask); }
        internal static string IP(uint value) { return string.Join(".", new[] { value >> 24, (value >> 16) & 255, (value >> 8) & 255, value & 255 }); }
        internal static string Address(LanTunSnapshot snapshot, IEnumerable<string> subnets)
        {
            for (int offset = 0; offset < 256; offset += 4) {
                string cidr = "172.31.254." + offset + "/30";
                if (snapshot.Busy(cidr).Length == 0 && !subnets.Any(s => Overlap(s, cidr))) return "172.31.254." + (offset + 1) + "/30";
            }
            throw new IOException("Нет свободного адреса TUN");
        }
        internal static object Config(LanTunNetwork[] networks, Dictionary<string, string[]> connected, int socksPort, Dictionary<string, object> secret, string address, string log)
        {
            var active = networks.Where(n => connected[n.Name].Length > 0).ToArray();
            var dns = active.SelectMany(n => n.DnsServers.Where(d => connected[n.Name].Any(s => Contains(s, LanAccess.IPv4(d))))).Distinct().ToArray();
            var servers = dns.Select((d, i) => (object)new { type = "tcp", tag = "lan-dns-" + i, server = d, server_port = 53, detour = "socks" }).ToArray();
            // sing-box 1.14 uses typed DNS servers: type=tcp/server is the current tcp:// form.
            var dnsRules = active.Select(n => new { network = n, server = Array.FindIndex(dns, d => n.DnsServers.Contains(d)) }).Where(x => x.server >= 0 && x.network.Domains.Length > 0)
                .Select(x => (object)new { domain_suffix = x.network.Domains.Select(d => d.TrimStart('*', '.')).Distinct().ToArray(), server = "lan-dns-" + x.server }).ToArray();
            var config = new Dictionary<string, object> {
                { "log", new { level = "warn", output = log, timestamp = true } },
                { "inbounds", new object[] { new { type = "tun", tag = "lan-tun", interface_name = InterfaceName, address = new[] { address }, route_address = active.SelectMany(n => connected[n.Name]).Distinct().ToArray(), auto_route = true, strict_route = false, stack = "system" } } },
                { "outbounds", new object[] { new { type = "socks", tag = "socks", server = "127.0.0.1", server_port = socksPort, version = "5", username = Json.Str(secret, "user"), password = Json.Str(secret, "password") } } },
                { "route", new { rules = dns.Length == 0 ? new object[0] : new object[] { new { port = new[] { 53 }, ip_cidr = dns.Select(d => d + "/32").ToArray(), action = "hijack-dns" } }, final = "socks", auto_detect_interface = false } }
            };
            if (servers.Length > 0) config["dns"] = new { servers = servers, rules = dnsRules, final = "lan-dns-0", strategy = "ipv4_only" };
            return config;
        }
        internal static string AddNrpt(LanTunNetwork network, string[] dns)
        {
            // Every interpolated value has passed Parse: no quotes, whitespace or PS metacharacters.
            return "$ErrorActionPreference='Stop'; " + string.Join("; ", network.Domains.Select(d => "Add-DnsClientNrptRule -Namespace '." + d.TrimStart('*', '.') + "' -NameServers " + string.Join(",", dns.Select(s => "'" + s + "'")) + " -Comment 'RemoteAgents:" + network.Name + "' | Out-Null"));
        }
        internal object Apply(Dictionary<string, object> request)
        {
            LanTunNetwork[] wanted;
            try { wanted = LanTunNetwork.Parse(request); } catch { return new { ok = false, error = "bad-request" }; }
            lock (gate) {
                if (disposed) return new { ok = false, error = "stopped" };
                StopCore(); networks = wanted; port = Json.Int(request, "socksPort", 0); signature = ""; retry.Reset(); states.Clear(); connected.Clear();
                foreach (var n in networks) states[n.Name] = new Dictionary<string, object> { { "name", n.Name }, { "state", "starting" }, { "reason", "подключается…" }, { "stage", "" }, { "nrptOk", false }, { "domains", n.Domains }, { "dnsServers", n.DnsServers } };
                nextRoutes = nextHealth = 0;
                try { TickLocked(); } finally { Publish(); }
                return new { ok = true };
            }
        }
        internal object Stop()
        {
            lock (gate) { StopCore(); networks = new LanTunNetwork[0]; states.Clear(); connected.Clear(); signature = ""; retry.Reset(); Publish(); return new { ok = true }; }
        }
        void StopCore()
        {
            if (core != null) { try { core.Dispose(); } finally { core = null; } }
            nrptDirty = !platform.Nrpt(RemoveNrpt);
            if (nrptDirty) platform.Log("lan-nrpt-remove", 1);
            foreach (var state in states.Values) { state["nrptOk"] = false; if (nrptDirty) state["stage"] = "lan-nrpt-remove"; }
        }
        void Error(string stage)
        {
            platform.Log(stage, 1);
            foreach (var state in states.Values) {
                state["stage"] = stage;
                if (Json.Str(state, "state") == "busy") continue;
                state["state"] = "failed"; state["reason"] = LanStages.Text(stage) + "; повторим автоматически";
            }
        }
        internal void Tick() { lock (gate) { if (!disposed) { try { TickLocked(); } finally { Publish(); } } } }
        void TickLocked()
        {
            if (networks.Length == 0) { if (nrptDirty) StopCore(); return; }
            long now = clock();
            try {
                if (core != null && !core.Alive) { StopCore(); Error("lan-core-exited"); retry.Failed(); }
                if (now >= nextRoutes || (core == null && retry.Ready && connected.Values.Any(s => s.Length > 0))) {
                    nextRoutes = now + 30000;
                    var snapshot = platform.Snapshot();
                    foreach (var n in networks) {
                        var busy = n.Subnets.Select(s => new { subnet = s, adapter = snapshot.Busy(s) }).Where(x => x.adapter.Length > 0).ToArray();
                        connected[n.Name] = n.Subnets.Except(busy.Select(b => b.subnet)).ToArray();
                        states[n.Name]["connectedSubnets"] = connected[n.Name];
                        states[n.Name]["excludedSubnets"] = busy.Select(b => (object)new { subnet = b.subnet, adapter = b.adapter }).ToArray();
                        states[n.Name]["busyReason"] = string.Join("; ", busy.Select(b => "подсеть " + b.subnet + " занята сетью " + b.adapter));
                    }
                    string address = Address(snapshot, networks.SelectMany(n => n.Subnets));
                    string current = address + Json.Encode(connected);
                    if (signature != current) { StopCore(); signature = current; tunAddress = address; retry.Reset(); SetHealth(platform.ChannelReady(), new Dictionary<string, bool>()); }
                }
                if (!connected.Values.Any(s => s.Length > 0)) { SetHealth(false, new Dictionary<string, bool>()); return; }
                if (core == null && retry.Ready) {
                    try {
                        platform.CleanAdapter();
                        core = platform.Start(Config(networks, connected, port, platform.Credentials(), tunAddress, LogPath));
                        // Cleanup and config check can take seconds: count the adapter wait from the real start.
                        long launched = clock();
                        started = launched; nextHealth = launched + 1000; adapterSeen = false; reached.Clear();
                        MarkStarting();
                        if (platform.ChannelReady()) InstallNrpt();
                    } catch { StopCore(); Error("lan-start"); retry.Failed(); }
                }
                if (now >= nextHealth) {
                    int index = core == null ? 0 : platform.TunnelIndex();
                    long checkedAt = clock();
                    if (core != null && index > 0) {
                        if (!adapterSeen) { platform.Log("lan-adapter-ready", (int)Math.Min(int.MaxValue, Math.Max(0, (checkedAt - started) / 1000))); ClearCoreStage(); }
                        adapterSeen = true;
                    } else if (core != null && adapterSeen) {
                        // Recheck after resume too; a loopback SOCKS endpoint needs no Wi-Fi rebinding.
                        StopCore(); Error("lan-adapter-down"); retry.Failed();
                    } else if (core != null && checkedAt - started >= AdapterWaitMs) {
                        StopCore(); Error("lan-adapter-timeout"); retry.Failed();
                    }
                    // While waiting for the adapter poll every second, otherwise every 10 s.
                    nextHealth = checkedAt + (core != null && !adapterSeen ? 1000 : 10000);
                    bool channel = platform.ChannelReady();
                    if (!channel) {
                        if (!platform.Nrpt(RemoveNrpt)) platform.Log("lan-nrpt-remove", 1);
                        foreach (var state in states.Values) state["nrptOk"] = false;
                        nrptDirty = true;
                    } else if (nrptDirty && core != null) InstallNrpt();
                    var probes = networks.Where(n => connected[n.Name].Length > 0).Select(n => new { n.Name, task = Task.Run(() => index > 0 && core != null && channel && platform.Probe(n, connected[n.Name], index)) }).ToArray();
                    // Platform probes have one aggregate 2 s budget each; N networks run concurrently.
                    Task.WaitAll(probes.Select(p => p.task).ToArray());
                    SetHealth(channel, probes.ToDictionary(p => p.Name, p => p.task.Result));
                    if (core != null && core.Alive && now - started >= 30000) retry.Reset();
                }
            } catch { StopCore(); Error("lan-watchdog"); retry.Failed(); nextRoutes = now + 30000; }
        }
        void MarkStarting()
        {
            foreach (var n in networks) {
                var state = states[n.Name];
                if (connected[n.Name].Length == 0 || Json.Str(state, "busyReason").Length > 0) continue;
                state["state"] = "starting"; state["reason"] = StartingReason(Json.Str(state, "stage"));
            }
        }
        static string StartingReason(string stage)
        { return LanStages.IsCore(stage) ? "повторное подключение после сбоя: " + LanStages.Text(stage) : "подключается…"; }
        void ClearCoreStage()
        { foreach (var state in states.Values) if (LanStages.IsCore(Json.Str(state, "stage"))) state["stage"] = ""; }
        internal static string LogPath {
            get {
#if PORTABLE_TEST
                return "/tmp/lan-sing-box.log";
#else
                return Path.Combine(NetHelperInstall.DataDirectory, "lan-sing-box.log");
#endif
            }
        }
        void InstallNrpt()
        {
            bool removed = platform.Nrpt(RemoveNrpt);
            var eligible = networks.Select(n => new { network = n, dns = n.DnsServers.Where(d => connected[n.Name].Any(s => Contains(s, LanAccess.IPv4(d)))).ToArray() })
                .Where(x => x.network.Domains.Length > 0 && x.dns.Length > 0).ToArray();
            bool added = removed && (eligible.Length == 0 || platform.Nrpt(string.Join("; ", eligible.Select(x => AddNrpt(x.network, x.dns)))));
            nrptDirty = !removed || !added;
            foreach (var n in networks) {
                bool ok = n.Domains.Length == 0 || (added && eligible.Any(x => x.network == n));
                states[n.Name]["nrptOk"] = ok;
                if (ok && (Json.Str(states[n.Name], "stage") == "lan-nrpt" || Json.Str(states[n.Name], "stage") == "lan-nrpt-remove")) states[n.Name]["stage"] = "";
                if (!ok) { states[n.Name]["stage"] = "lan-nrpt"; platform.Log("lan-nrpt", 1); }
            }
        }
        void SetHealth(bool channel, Dictionary<string, bool> probes)
        {
            long t = clock();
            foreach (var n in networks) {
                var state = states[n.Name]; string busy = Json.Str(state, "busyReason"), stage = Json.Str(state, "stage");
                bool ok; probes.TryGetValue(n.Name, out ok);
                if (ok && core != null) reached.Add(n.Name);
                bool warming = core == null || !adapterSeen || (!reached.Contains(n.Name) && t - started < StartupGraceMs);
                string status, reason;
                if (connected[n.Name].Length == 0 || busy.Length > 0) { status = "busy"; reason = (connected[n.Name].Length == 0 ? "не подключена: адреса заняты; " : "") + busy; }
                else if (core == null && LanStages.IsCore(stage)) { status = "failed"; reason = LanStages.Text(stage) + "; повторим автоматически"; }
                else if (!channel) { status = "channel-down"; reason = "нет связи с сервером"; }
                else if (ok) { status = "ok"; reason = "работает"; }
                else if (warming) { status = "starting"; reason = StartingReason(stage); }
                else { status = "host-down"; reason = "сервер на связи, но проверочный адрес " + n.TestHost + ":" + n.TestPort + " не отвечает (сеть на сервере выключена или адрес недоступен)"; }
                if (!Json.Bool(state, "nrptOk") && n.Domains.Length > 0 && status != "failed" && status != "starting") reason += "; имена сети " + n.Name + " не настроены";
                if (status == "ok" && (Json.Bool(state, "nrptOk") || n.Domains.Length == 0)) state["stage"] = "";
                state["state"] = status; state["reason"] = reason;
            }
        }
        void Publish()
        { published = new Dictionary<string, object> { { "enabled", networks.Length > 0 }, { "networks", states.Values.Select(s => (object)new Dictionary<string, object>(s)).ToArray() } }; }
        // Immutable snapshots keep status/ping available during slow NRPT/route operations.
        internal Dictionary<string, object> Status() { return published; }
        public void Dispose() { disposed = true; lock (gate) StopCore(); }
    }

#if !PORTABLE_TEST
    internal sealed class WindowsLanTun : ILanTunPlatform
    {
        readonly string home;
        readonly Func<object, ILanTunCore> start;
        readonly Action<string, int> log;
        readonly Action<IDisposable> addJob, removeJob;
        internal WindowsLanTun(string home, Func<object, ILanTunCore> start, Action<string, int> log, Action<IDisposable> addJob, Action<IDisposable> removeJob)
        { this.home = home; this.start = start; this.log = log; this.addJob = addJob; this.removeJob = removeJob; }
        public void Log(string stage, int code) { log(stage, code); }
        public ILanTunCore Start(object config) { return start(config); }
        public Dictionary<string, object> Credentials()
        {
            string file = Path.Combine(home, "state", "helper-socks.json");
            NetHelperInstall.RejectReparse(Path.GetDirectoryName(file));
            if ((File.GetAttributes(file) & FileAttributes.ReparsePoint) != 0 || new FileInfo(file).Length > 4096) throw new IOException();
            var secret = Json.Read(file);
            if (Json.Str(secret, "user") != "ra-helper" || Convert.FromBase64String(Json.Str(secret, "password")).Length != 32) throw new IOException();
            return secret;
        }
        static NetworkInterface[] Interfaces() { return NetworkInterface.GetAllNetworkInterfaces(); }
        public LanTunSnapshot Snapshot()
        {
            var result = new LanTunSnapshot(); var addresses = new Dictionary<string, string>();
            foreach (var nic in Interfaces()) {
                foreach (var ip in nic.GetIPProperties().UnicastAddresses.Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork)) {
                    addresses[ip.Address.ToString()] = nic.Name;
                    // Check all foreign unicast addresses, including physical addresses without a route.
                    result.Addresses.Add(new LanTunRoute(ip.Address + "/32", nic.Name));
                }
            }
            // route.exe -4 print exposes numeric destination, mask and local interface IPv4 on
            // every Windows locale. Ignore headings, gateway labels and metrics. NI supplies
            // adapter names, avoiding localized route labels and unstable native struct layouts.
            // A failed/unknown snapshot fails closed instead of claiming a subnet is free.
            string output = Run("route.exe", new[] { "print", "-4" }, 10000);
            result.ReadRoutePrint(output, addresses);
            return result;
        }
        public int TunnelIndex()
        {
            var nic = Interfaces().FirstOrDefault(n => n.Name == LanTun.InterfaceName && n.OperationalStatus == OperationalStatus.Up);
            return nic == null ? 0 : nic.GetIPProperties().GetIPv4Properties().Index;
        }
        public void CleanAdapter()
        {
            // Match the exact connection name, then remove that device instance only.
            // pnputil is Windows' supported PnP removal API; never remove a Wintun driver.
            Run(@"WindowsPowerShell\v1.0\powershell.exe", new[] { "-NoProfile", "-NonInteractive", "-Command",
                "$ErrorActionPreference='Stop'; $adapters=@(Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.NetConnectionID -ceq 'RemoteAgents-LAN' }); foreach($a in $adapters) { if(-not $a.PNPDeviceID){throw 'missing device id'}; & ($env:windir+'\\System32\\pnputil.exe') /remove-device $a.PNPDeviceID | Out-Null; if($LASTEXITCODE -ne 0){throw 'remove failed'} }" }, 10000);
        }
        public bool Nrpt(string command)
        { try { Run(@"WindowsPowerShell\v1.0\powershell.exe", new[] { "-NoProfile", "-NonInteractive", "-Command", command }, 10000, command == LanTun.RemoveNrpt); return true; } catch { return false; } }
        public bool ChannelReady() { return Json.Bool(StatusView.Read(home, "transport", maxAgeSec: 15), "ok"); }
        public bool Probe(LanTunNetwork network, string[] subnets, int index)
        {
            // Includes DNS resolution in the 2 s budget. No connect starts after a DNS timeout.
            var budget = Stopwatch.StartNew();
            try {
                var resolve = Dns.GetHostAddressesAsync(network.TestHost);
                if (!resolve.Wait(2000)) return false;
                foreach (var address in resolve.Result.Where(a => a.AddressFamily == AddressFamily.InterNetwork && subnets.Any(s => LanTun.Contains(s, LanAccess.IPv4(a.ToString()))))) {
                    uint actual;
                    if (GetBestInterface(BitConverter.ToUInt32(address.GetAddressBytes(), 0), out actual) != 0 || actual != index) continue;
                    int remaining = 2000 - (int)budget.ElapsedMilliseconds;
                    if (remaining <= 0) return false;
                    using (var client = new TcpClient(AddressFamily.InterNetwork)) {
                        var connect = client.ConnectAsync(address, network.TestPort);
                        if (!connect.Wait(remaining)) return false;
                        if (client.Connected && GetBestInterface(BitConverter.ToUInt32(address.GetAddressBytes(), 0), out actual) == 0 && actual == index) return true;
                    }
                }
            } catch { }
            return false;
        }
        string Run(string name, string[] args, int timeout, bool cleanup = false)
        {
            string system = Environment.GetFolderPath(Environment.SpecialFolder.System);
            string output = Path.Combine(NetHelperInstall.DataDirectory, "lan-command-" + Guid.NewGuid().ToString("N") + ".txt");
            try {
                using (var job = new NativeJob()) {
                    // Closing the owner session also kills in-flight commands (and pnputil
                    // children). Only the fixed removal script may run after Jobs are closed.
                    if (!cleanup) addJob(job);
                    try {
                        using (var process = job.StartRedirected(Path.Combine(system, name), args, system, output)) {
                            if (!process.WaitForExit(timeout) || process.ExitCode != 0) throw new IOException();
                            return File.ReadAllText(output, System.Text.Encoding.GetEncoding(CultureInfo.CurrentCulture.TextInfo.OEMCodePage));
                        }
                    } finally { if (!cleanup) removeJob(job); }
                }
            } finally { try { File.Delete(output); } catch { } }
        }
        [DllImport("iphlpapi.dll")] static extern uint GetBestInterface(uint address, out uint index);

    }
    internal sealed class LanTunProcess : ILanTunCore
    {
        readonly Process process; readonly IDisposable job; readonly Action release;
        internal LanTunProcess(Process process, IDisposable job, Action release) { this.process = process; this.job = job; this.release = release; }
        public bool Alive { get { return !process.HasExited; } }
        public void Dispose() { try { job.Dispose(); process.WaitForExit(2000); } finally { process.Dispose(); release(); } }
    }
#endif
}
