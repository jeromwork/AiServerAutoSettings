using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace RemoteAgents.Launcher
{
    // Own code is lifetime/policy glue; sing-box owns routing, DNS and the TUN stack.
    internal sealed class VpnTun
    {
        internal const string InterfaceName = "RemoteAgents-VPN";
        internal const int HealthDeadlineMs = 10000, RecoveryMs = 10000;
        internal int SocksPort;
        internal string[] Address = { "172.31.255.1/30", "fdfe:7261::1/126" }, ExcludeCidrs = new string[0];
        internal string DnsServer = "1.1.1.1", CheckUrl = "https://example.com/", ProbeAddress = "198.18.0.1";
        internal static Dictionary<string, object> D(params object[] pairs)
        { var d = new Dictionary<string, object>(); for (int i = 0; i < pairs.Length; i += 2) d.Add((string)pairs[i], pairs[i + 1]); return d; }
        internal static void Cidr(string value)
        {
            IPAddress ip; int bits; var parts = value.Split('/');
            if (parts.Length != 2 || !IPAddress.TryParse(parts[0], out ip) || !int.TryParse(parts[1], out bits) || bits < 0 || bits > (ip.AddressFamily == AddressFamily.InterNetwork ? 32 : 128)) throw new InvalidDataException("Неверный CIDR VPN");
        }
        internal static VpnTun Read(Dictionary<string, object> value)
        {
            var o = new VpnTun(); o.SocksPort = Json.Int(value, "socksPort", 0);
            if (value.ContainsKey("address")) o.Address = Strings(value, "address");
            if (value.ContainsKey("excludeCidrs")) o.ExcludeCidrs = Strings(value, "excludeCidrs");
            o.DnsServer = Json.Text(value, "dnsServer", o.DnsServer); o.CheckUrl = Json.Text(value, "checkUrl", o.CheckUrl); o.ProbeAddress = Json.Text(value, "probeAddress", o.ProbeAddress);
            Uri uri; IPAddress ip;
            if (Json.Get(value, "socksPort") is string || Json.Get(value, "socksPort") is bool || o.SocksPort < 1 || o.SocksPort > 65535 || o.Address.Length == 0 || o.Address.Length > 4 || o.ExcludeCidrs.Length > 256) throw new InvalidDataException("Неверные параметры VPN");
            foreach (var cidr in o.Address.Concat(o.ExcludeCidrs)) Cidr(cidr);
            if (!Uri.TryCreate(o.CheckUrl, UriKind.Absolute, out uri) || uri.Scheme != "https" || uri.HostNameType != UriHostNameType.Dns || uri.UserInfo.Length > 0 || uri.Fragment.Length > 0) throw new InvalidDataException("Для проверки VPN нужен HTTPS URL с доменом");
            if (!IPAddress.TryParse(o.DnsServer, out ip) || !IPAddress.TryParse(o.ProbeAddress, out ip) || ip.AddressFamily != AddressFamily.InterNetwork) throw new InvalidDataException("Неверный IP VPN");
            // A probe inside an excluded prefix cannot prove that the default route works.
            if (o.ExcludeCidrs.Any(c => Contains(c, ip))) throw new InvalidDataException("Проба VPN попала в исключение");
            return o;
        }
        static string[] Strings(Dictionary<string, object> value, string key)
        {
            var raw = Json.Get(value, key); var items = Json.Array(raw);
            if (!(raw is System.Collections.IEnumerable) || raw is string || raw is System.Collections.IDictionary || items.Any(x => !(x is string))) throw new InvalidDataException("Нужен массив строк VPN");
            return items.Cast<string>().ToArray();
        }
        internal object Request()
        { return D("cmd", "vpn.on", "socksPort", SocksPort, "address", Address, "excludeCidrs", ExcludeCidrs, "dnsServer", DnsServer, "checkUrl", CheckUrl, "probeAddress", ProbeAddress); }
        internal static bool Contains(string cidr, IPAddress ip)
        {
            Cidr(cidr); var p = cidr.Split('/'); byte[] network = IPAddress.Parse(p[0]).GetAddressBytes(), bytes = ip.GetAddressBytes(); int bits = int.Parse(p[1]);
            if (bytes.Length != network.Length) return false;
            for (int i = 0; bits > 0; i++, bits -= 8) { int mask = 255 << (8 - Math.Min(bits, 8)); if ((network[i] & mask) != (bytes[i] & mask)) return false; }
            return true;
        }
        static bool Match(string text, string pattern) { return Regex.IsMatch(text, pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant); }
        static bool Own(Dictionary<string, object> a) { return Json.Str(a, "Name").StartsWith("RemoteAgents-", StringComparison.OrdinalIgnoreCase); }
        static bool Transition(Dictionary<string, object> a) { return Match(Json.Str(a, "Name") + " " + Json.Str(a, "InterfaceDescription"), "Teredo|ISATAP|6to4|IP-HTTPS"); }
        static bool Virtual(Dictionary<string, object> a)
        { return Json.Get(a, "HardwareInterface") is bool && !Json.Bool(a, "HardwareInterface") || Json.Bool(a, "Virtual") || Match(Json.Str(a, "Name") + " " + Json.Str(a, "InterfaceDescription"), "VPN|Tailscale|TUN|Wintun|WireGuard|TAP|virtual"); }
        static bool Up(Dictionary<string, object> a) { return Json.Str(a, "Status").Equals("Up", StringComparison.OrdinalIgnoreCase); }
        internal static string Conflict(Dictionary<string, object> snapshot)
        {
            var routes = Json.Array(Json.Get(snapshot, "Routes")).Select(Json.Map).ToArray();
            foreach (var a in Json.Array(Json.Get(snapshot, "Adapters")).Select(Json.Map)) {
                if (!Up(a) || Own(a) || Transition(a)) continue;
                string text = Json.Str(a, "Name") + " " + Json.Str(a, "InterfaceDescription");
                var prefixes = routes.Where(r => Json.Int(r, "InterfaceIndex", -1) == Json.Int(a, "ifIndex", -2)).Select(r => Json.Str(r, "DestinationPrefix")).ToArray();
                bool full = prefixes.Contains("0.0.0.0/0") || prefixes.Contains("::/0") || prefixes.Contains("0.0.0.0/1") && prefixes.Contains("128.0.0.0/1") || prefixes.Contains("::/1") && prefixes.Contains("8000::/1");
                bool partial = prefixes.Any(p => !new[] { "0.0.0.0/0", "::/0", "0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1" }.Contains(p));
                // A known routed partial WireGuard/OpenVPN is compatible. Unknown Up TUNs fail closed.
                if (Virtual(a) && full || Match(text, "TUN|Wintun|WireGuard|TAP") && !(partial && Match(text, "OpenVPN|WireGuard|Tailscale")) && !Match(text, "OpenVPN|Tailscale")) return Json.Text(a, "Name", "другой VPN");
            }
            return "";
        }
        static string[] Values(Dictionary<string, object> map, string key)
        { var value = Json.Get(map, key); return value is string ? (string.IsNullOrEmpty((string)value) ? new string[0] : new[] { (string)value }) : Json.Strings(value); }
        internal static Dictionary<string, object> DnsPolicy(Dictionary<string, object> snapshot)
        {
            foreach (string key in new[] { "Adapters", "Routes", "DnsServers", "DnsClients", "Nrpt" }) if (!snapshot.ContainsKey(key)) throw new InvalidDataException("Нет снимка DNS");
            var networks = new List<object>();
            var nrpt = Json.Array(Json.Get(snapshot, "Nrpt")).Select(Json.Map).Where(n => Values(n, "Namespace").Length > 0 || Values(n, "NameServers").Length > 0 || Values(n, "DirectAccessDnsServers").Length > 0)
                .Select(n => D("namespaces", Values(n, "Namespace"), "servers", Values(n, "NameServers").Concat(Values(n, "DirectAccessDnsServers")).ToArray())).ToArray();
            foreach (var a in Json.Array(Json.Get(snapshot, "Adapters")).Select(Json.Map)) {
                if (!Up(a) || Json.Str(a, "Name") == InterfaceName || !Virtual(a)) continue;
                int index = Json.Int(a, "ifIndex", -1);
                var servers = Json.Array(Json.Get(snapshot, "DnsServers")).Select(Json.Map).Where(n => Json.Int(n, "InterfaceIndex", -2) == index).SelectMany(n => Json.Strings(Json.Get(n, "ServerAddresses"))).Where(s => s.Length > 0).Distinct().ToArray();
                var suffixes = Json.Array(Json.Get(snapshot, "DnsClients")).Select(Json.Map).Where(n => Json.Int(n, "InterfaceIndex", -2) == index).SelectMany(n => new[] { Json.Str(n, "ConnectionSpecificSuffix") }.Concat(Json.Strings(Json.Get(n, "ConnectionSpecificSuffixSearchList")))).Where(s => s.Length > 0).Distinct().ToArray();
                if (servers.Length + suffixes.Length + nrpt.Length > 0) networks.Add(D("name", Json.Str(a, "Name"), "interfaceIndex", index, "servers", servers, "suffixes", suffixes, "nrpt", nrpt));
            }
            return D("strictRoute", networks.Count == 0, "networks", networks.ToArray());
        }
        internal static string PathState(Dictionary<string, object> transport, DateTime now)
        { return !VpnWatchdog.TransportReady(transport, now) ? "no-path" : !Json.Bool(Json.Map(Json.Get(transport, "helper")), "udp") ? "no-udp" : ""; }
        internal object Config(string user, string password, IEnumerable<string> endpoints, IEnumerable<string> lanSubnets, Dictionary<string, object> snapshot, Dictionary<string, object> dnsPolicy)
        {
            var exclusions = new List<string> { "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16", "224.0.0.0/4", "127.0.0.0/8", "::1/128", "fc00::/7", "fe80::/10", "ff00::/8" };
            exclusions.AddRange(ExcludeCidrs); exclusions.AddRange(lanSubnets);
            foreach (string endpoint in endpoints) { var ip = IPAddress.Parse(endpoint); exclusions.Add(ip + (ip.AddressFamily == AddressFamily.InterNetwork ? "/32" : "/128")); }
            var partial = Json.Array(Json.Get(snapshot, "Adapters")).Select(Json.Map).Where(a => Up(a) && Virtual(a) && !Own(a) && !Transition(a)).Select(a => Json.Int(a, "ifIndex", -1)).ToArray();
            exclusions.AddRange(Json.Array(Json.Get(snapshot, "Routes")).Select(Json.Map).Where(r => partial.Contains(Json.Int(r, "InterfaceIndex", -2))).Select(r => Json.Str(r, "DestinationPrefix")).Where(p => !new[] { "0.0.0.0/0", "::/0", "0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1" }.Contains(p)));
            foreach (var cidr in exclusions) Cidr(cidr);
            var probe = IPAddress.Parse(ProbeAddress);
            if (exclusions.Any(c => Contains(c, probe))) throw new InvalidDataException("Проба VPN исключена из TUN");
            var check = new Uri(CheckUrl); string[] excluded = exclusions.Distinct().ToArray();
            return D("log", D("disabled", true),
                "inbounds", new[] { D("type", "tun", "tag", "vpn-tun", "interface_name", InterfaceName, "address", Address, "stack", "system", "auto_route", true, "strict_route", Json.Bool(dnsPolicy, "strictRoute"), "route_exclude_address", excluded) },
                "outbounds", new[] { D("type", "socks", "tag", "vpn-active", "server", "127.0.0.1", "server_port", SocksPort, "version", "5", "username", user, "password", password), D("type", "direct", "tag", "vpn-direct") },
                "route", D("auto_detect_interface", true, "final", "vpn-active", "rules", new[] {
                    D("inbound", new[] { "vpn-tun" }, "network", "tcp", "ip_cidr", new[] { ProbeAddress + "/32" }, "port", new[] { check.Port }, "action", "route-options", "override_address", check.DnsSafeHost, "override_port", check.Port),
                    D("inbound", new[] { "vpn-tun" }, "domain", new[] { check.DnsSafeHost }, "action", "resolve", "server", "vpn-dns", "disable_cache", true, "disable_optimistic_cache", true, "timeout", "3000ms"),
                    D("inbound", new[] { "vpn-tun" }, "domain", new[] { check.DnsSafeHost }, "action", "route", "outbound", "vpn-active"),
                    D("process_name", new[] { "powershell.exe", "python.exe", "pythonw.exe", "ssh.exe", "sing-box.exe", "syncthing.exe", "SyncthingTray.exe" }, "action", "route", "outbound", "vpn-direct"),
                    D("ip_cidr", excluded, "action", "route", "outbound", "vpn-direct"), D("protocol", "dns", "action", "hijack-dns"), D("port", new[] { 53 }, "action", "hijack-dns") }),
                "dns", D("servers", new[] { D("type", "https", "tag", "vpn-dns", "server", DnsServer, "path", "/dns-query", "tls", D("enabled", true), "detour", "vpn-active") }, "final", "vpn-dns"));
        }
    }

    internal sealed class VpnTunRecovery
    {
        bool armed, spent; long healthySince = -1;
        internal void Reset() { armed = spent = false; healthySince = -1; }
        internal void Stopped(string reason) { armed = !spent && (reason == "server-unreachable" || reason == "no-path"); healthySince = -1; }
        internal bool Observe(long now, bool ready)
        {
            if (!armed || spent) return false;
            if (!ready) { healthySince = -1; return false; }
            if (healthySince < 0) healthySince = now;
            if (now - healthySince < VpnTun.RecoveryMs) return false;
            spent = true; armed = false; return true;
        }
    }

    // A pure monotonic-clock model also covers immediate core death and both independent cutoffs.
    internal sealed class VpnTunHealth
    {
        readonly VpnWatchdog failures = new VpnWatchdog();
        long pulse, confirmed;
        internal VpnTunHealth(long now) { pulse = confirmed = now; }
        internal void Pulse(long now) { pulse = now; }
        internal string Tick(long now, bool coreAlive)
        { return !coreAlive ? "core-exited" : now - pulse > VpnLease.DeadlineMs ? "watchdog-stalled" : now - confirmed > VpnTun.HealthDeadlineMs ? "server-unreachable" : ""; }
        internal bool Sample(long now, bool pathOk, bool probeOk)
        { if (pathOk && probeOk) confirmed = now; return failures.Sample(pathOk, probeOk); }
    }

    // Runtime has no WinForms or user-supplied executable/config paths. Each VPN owns its own Jobs.
    internal sealed class VpnTunSession : IDisposable
    {
        readonly string home, directory, executable;
        readonly Action<Action> asOwner;
        readonly Action<string, int> log;
        readonly object gate = new object();
        readonly ManualResetEvent wake = new ManualResetEvent(false);
        readonly Thread thread;
        readonly Stopwatch clock = Stopwatch.StartNew();
        readonly VpnTunRecovery recovery = new VpnTunRecovery();
        Dictionary<string, object> status = VpnTun.D("enabled", false, "ok", false, "state", "off", "summary", "VPN выключен");
        NativeJob coreJob, preparationJob;
        Process core;
        VpnTun requested;
        bool pending, disposed;
        int generation;
        internal VpnTunSession(string home, string directory, string executable, Action<Action> asOwner, Action<string, int> log)
        {
            this.home = home; this.directory = directory; this.executable = executable; this.asOwner = asOwner; this.log = log;
            thread = new Thread(Loop) { IsBackground = true, Name = "VPN TUN owner" }; thread.Start();
        }
        internal Dictionary<string, object> Status()
        {
            lock (gate) { var copy = new Dictionary<string, object>(status); copy["owner"] = "net-helper"; return copy; }
        }
        internal void Enable(VpnTun options)
        {
            lock (gate) {
                if (disposed) throw new ObjectDisposedException("VpnTunSession");
                if (coreJob != null || pending || Json.Str(status, "state") == "starting") return;
                generation++; requested = options; pending = true; recovery.Reset(); Set("starting", "prepare");
            }
            wake.Set();
        }
        internal void Disable()
        {
            lock (gate) { CloseJobs(); generation++; pending = false; requested = null; recovery.Reset(); Set("off", "button"); }
            wake.Set();
        }
        void CloseJobs()
        { lock (gate) { if (coreJob != null) { coreJob.Dispose(); coreJob = null; } if (preparationJob != null) { preparationJob.Dispose(); preparationJob = null; } } }
        void Set(string state, string stage, string name = "", Dictionary<string, object> policy = null)
        {
            lock (gate) status = VpnTun.D("ok", state == "on", "enabled", state == "on" || state == "starting", "state", state, "stage", stage,
                "summary", state == "on" ? "VPN включён" : state == "off" ? "VPN выключен" : state == "starting" ? "Включается…" : VpnWatchdog.FailureSummary(state, name.Length > 0 ? name : stage), "dnsPolicy", policy, "conflictName", state == "conflict" ? name : "", "updatedAt", DateTime.UtcNow.ToString("o"));
        }
        Dictionary<string, object> Read(string relative)
        { Dictionary<string, object> result = null; asOwner(() => result = Json.Read(Path.Combine(home, relative))); return result; }
        Dictionary<string, object> Transport() { try { return Read("status/transport.json"); } catch { return Json.Map(null); } }
        Dictionary<string, object> Snapshot(int epoch)
        {
            // Fixed inventory only. Never execute a script from the owner's writable home as SYSTEM.
            const string script = "$ErrorActionPreference='Stop';[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false);@{Adapters=@(Get-NetAdapter -IncludeHidden|Select-Object Name,InterfaceDescription,ifIndex,Status,HardwareInterface,Virtual);Routes=@(Get-NetRoute|Select-Object InterfaceIndex,DestinationPrefix);DnsServers=@(Get-DnsClientServerAddress|Select-Object InterfaceIndex,ServerAddresses);DnsClients=@(Get-DnsClient|Select-Object InterfaceIndex,ConnectionSpecificSuffix,ConnectionSpecificSuffixSearchList);Nrpt=@(Get-DnsClientNrptPolicy -Effective|Select-Object Namespace,NameServers,DirectAccessDnsServers)}|ConvertTo-Json -Depth 10 -Compress";
            string file = Path.Combine(directory, "vpn-inventory.json");
            RunPreparation(Files.Executable("powershell.exe"), new[] { "-NoProfile", "-NonInteractive", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(script)) }, file, epoch);
            if (new FileInfo(file).Length > 4 * 1024 * 1024) throw new InvalidDataException("Снимок сети слишком велик");
            return Json.Read(file);
        }
        void RunPreparation(string exe, string[] args, string output, int epoch)
        {
            var job = new NativeJob();
            lock (gate) { if (disposed || generation != epoch) { job.Dispose(); throw new OperationCanceledException(); } preparationJob = job; }
            try {
                using (var process = job.StartRedirected(exe, args, directory, output)) {
                    var elapsed = Stopwatch.StartNew();
                    while (!process.WaitForExit(50)) { lock (gate) if (disposed || generation != epoch) throw new OperationCanceledException(); if (elapsed.ElapsedMilliseconds > 15000) throw new TimeoutException(); }
                    if (process.ExitCode != 0) throw new InvalidDataException("Подготовка VPN отклонена");
                }
            } finally { job.Dispose(); lock (gate) if (preparationJob == job) preparationJob = null; }
        }
        void Stop(string reason, string stage, int epoch, string name = "")
        {
            CloseJobs(); // Must precede state, recovery and log I/O.
            lock (gate) {
                if (generation != epoch) return;
                recovery.Stopped(reason); Set(reason, stage, name);
            }
            log("vpn-" + reason + "-" + stage, 1);
        }
        static int TunIndex()
        {
            var adapter = NetworkInterface.GetAllNetworkInterfaces().FirstOrDefault(a => a.Name == VpnTun.InterfaceName && a.OperationalStatus == OperationalStatus.Up);
            return adapter == null ? 0 : adapter.GetIPProperties().GetIPv4Properties().Index;
        }
        void Run(VpnTun options, int epoch)
        {
            string stage = "inventory";
            VpnLease lease = null; VpnProbe probe = null;
            try {
                var snapshot = Snapshot(epoch);
                string conflict = VpnTun.Conflict(snapshot);
                if (conflict.Length > 0) { lock (gate) if (epoch == generation) Set("conflict", "conflicts", conflict); return; }
                var policy = VpnTun.DnsPolicy(snapshot);
                var transport = Transport(); string pathState = VpnTun.PathState(transport, DateTime.UtcNow);
                if (pathState.Length > 0) { lock (gate) if (epoch == generation) Set(pathState, "path", TrayMenuModel.ActiveTitle(transport)); return; }
                stage = "exclusions";
                // Only public endpoint names from the channel publisher; no channel credentials/configs.
                var hosts = Json.Strings(Json.Get(transport, "endpoints"));
                if (hosts.Length == 0 || hosts.Length > 256) throw new InvalidDataException("Нет списка узлов канала");
                string preparedRevision = Json.Str(transport, "configRevision");
                var ips = new List<string>(); var preparationClock = Stopwatch.StartNew();
                foreach (var host in hosts.Distinct()) {
                    lock (gate) if (disposed || epoch != generation) return;
                    if (preparationClock.ElapsedMilliseconds > 15000) throw new TimeoutException();
                    IPAddress ip;
                    if (IPAddress.TryParse(host, out ip)) ips.Add(ip.ToString());
                    else {
                        var lookup = Dns.GetHostAddressesAsync(host);
                        if (!lookup.Wait(3000)) throw new TimeoutException();
                        ips.AddRange(lookup.GetAwaiter().GetResult().Select(a => a.ToString()));
                    }
                }
                var lan = Json.Map(Json.Get(transport, "lan"));
                var credential = Read("state/helper-socks.json");
                byte[] password = Convert.FromBase64String(Json.Str(credential, "password"));
                if (Json.Str(credential, "user") != "ra-helper" || password.Length != 32) throw new InvalidDataException("Нет учётных данных помощника");
                if (Json.Int(Json.Map(Json.Get(transport, "helper")), "vpnInPort", 0) != options.SocksPort) throw new InvalidDataException("Изменился порт канала");
                stage = "config-check";
                string config = Path.Combine(directory, "vpn-tun.json");
                Files.Atomic(config, Json.Encode(options.Config("ra-helper", Json.Str(credential, "password"), ips, Json.Strings(Json.Get(lan, "subnets")), snapshot, policy)));
                RunPreparation(executable, new[] { "check", "-c", config }, null, epoch);
                // Recheck fresh channel evidence immediately before creating the TUN.
                transport = Transport(); pathState = VpnTun.PathState(transport, DateTime.UtcNow);
                if (pathState.Length > 0) { lock (gate) if (epoch == generation) Set(pathState, "path", TrayMenuModel.ActiveTitle(transport)); return; }
                if (preparedRevision != Json.Str(transport, "configRevision") || Json.Int(Json.Map(Json.Get(transport, "helper")), "vpnInPort", 0) != options.SocksPort) { lock (gate) if (epoch == generation) Set("no-path", "path-changed"); return; }
                stage = "core-start";
                var launchJob = new NativeJob();
                lock (gate) {
                    if (disposed || epoch != generation) { launchJob.Dispose(); return; }
                    coreJob = launchJob;
                }
                long progressAt = clock.ElapsedMilliseconds;
                string leaseFailure = null;
                lease = new VpnLease(() => {
                    CloseJobs(); // This callback does no file/network/log I/O.
                    string reason = clock.ElapsedMilliseconds - Interlocked.Read(ref progressAt) > VpnLease.DeadlineMs ? "watchdog-stalled" : "server-unreachable";
                    Interlocked.CompareExchange(ref leaseFailure, reason, null);
                    lock (gate) if (epoch == generation) Set(reason, "lease-expired");
                }, VpnLease.DeadlineMs, VpnTun.HealthDeadlineMs);
                // Never hold the status/command lock across CreateProcess. A slow VPN launch
                // must not stall the helper's pipe loop and expire the independent LAN lifetime.
                core = launchJob.Start(executable, new[] { "run", "-c", config }, directory);
                var health = new VpnTunHealth(clock.ElapsedMilliseconds);
                string revision = Json.Str(transport, "configRevision"), network = Json.Str(transport, "network");
                long nextSample = clock.ElapsedMilliseconds, nextRead = 0, probeStarted = 0, nextStatus = 0;
                bool pathOk = false; string failure = "server-unreachable";
                stage = "https-probe";
                while (true) {
                    lock (gate) if (disposed || epoch != generation) return;
                    long now = clock.ElapsedMilliseconds;
                    bool alive = core != null && !core.WaitForExit(0);
                    string cutoff = Interlocked.CompareExchange(ref leaseFailure, null, null) ?? (lease.Expired ? (now - Interlocked.Read(ref progressAt) > VpnLease.DeadlineMs ? "watchdog-stalled" : "server-unreachable") : health.Tick(now, alive));
                    if (cutoff.Length > 0 || lease.Expired) { Stop(cutoff.Length > 0 ? cutoff : "watchdog-stalled", stage, epoch); return; }
                    lease.Pulse(); Interlocked.Exchange(ref progressAt, now); health.Pulse(now);
                    if (now >= nextRead) {
                        transport = Transport(); nextRead = now + 500;
                        pathState = VpnTun.PathState(transport, DateTime.UtcNow);
                        if (pathState == "no-udp") { Stop("no-udp", "path", epoch, TrayMenuModel.ActiveTitle(transport)); return; }
                        if (revision != Json.Str(transport, "configRevision") && pathState.Length == 0 || network != Json.Str(transport, "network") && pathState.Length == 0) { Stop("no-path", "path-changed", epoch); return; }
                    }
                    if (probe == null && now >= nextSample) {
                        int index = TunIndex();
                        if (index == 0 && now - nextSample < VpnWatchdog.ProbeTimeoutMs) { wake.WaitOne(50); continue; }
                        pathOk = VpnTun.PathState(transport, DateTime.UtcNow).Length == 0;
                        failure = pathOk ? "server-unreachable" : "no-path";
                        probeStarted = now; probe = new VpnProbe(new Uri(options.CheckUrl), IPAddress.Parse(options.ProbeAddress), index);
                    }
                    if (probe != null && (probe.Result.IsCompleted || now - probeStarted >= VpnWatchdog.ProbeTimeoutMs)) {
                        bool ok = probe.Result.IsCompleted && probe.Result.GetAwaiter().GetResult(); probe.Dispose(); probe = null;
                        pathOk = pathOk && VpnTun.PathState(transport, DateTime.UtcNow).Length == 0;
                        if (!pathOk) failure = "no-path";
                        if (health.Sample(now, pathOk, ok)) { Stop(failure, pathOk ? "https-probe" : "path", epoch); return; }
                        if (pathOk && ok) { lease.Confirmed(); lock (gate) if (epoch == generation) Set("on", "healthy", policy: policy); }
                        nextSample = Math.Max(probeStarted + VpnWatchdog.IntervalMs, now + 1);
                    }
                    if (now >= nextStatus) { lock (gate) if (epoch == generation) status["updatedAt"] = DateTime.UtcNow.ToString("o"); nextStatus = now + 500; }
                    wake.WaitOne(VpnWatchdog.PollMs); wake.Reset();
                }
            } catch (OperationCanceledException) { }
            catch { Stop("error", stage, epoch); }
            finally {
                CloseJobs();
                if (probe != null) probe.Dispose(); if (lease != null) lease.Dispose();
                if (core != null) { core.Dispose(); core = null; }
            }
        }
        void Loop()
        {
            while (true) {
                VpnTun options; int epoch;
                lock (gate) { if (disposed) return; options = pending ? requested : null; pending = false; epoch = generation; }
                if (options != null) Run(options, epoch);
                else {
                    var transport = Transport();
                    lock (gate) {
                        if (disposed) return;
                        if (requested != null && recovery.Observe(clock.ElapsedMilliseconds, VpnTun.PathState(transport, DateTime.UtcNow).Length == 0)) { pending = true; Set("starting", "auto-retry"); }
                    }
                    wake.WaitOne(250); wake.Reset();
                }
            }
        }
        public void Dispose()
        {
            lock (gate) { CloseJobs(); disposed = true; generation++; pending = false; }
            wake.Set(); // Do not wait for potentially stalled I/O on the SCM shutdown thread.
        }
    }
}
