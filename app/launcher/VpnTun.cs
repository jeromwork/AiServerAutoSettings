using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace RemoteAgents.Launcher
{
    // Own code is lifetime/policy glue; sing-box owns routing, DNS and the TUN stack.
    internal sealed class VpnTun
    {
        internal const string InterfaceName = "RemoteAgents-VPN";
        internal int SocksPort;
        internal string[] Address = { "172.31.255.1/30", "fdfe:7261::1/126" }, ExcludeCidrs = new string[0];
        internal string[] DirectDomains = { ".ru", ".su", ".xn--p1ai", "yandex.net", "yastatic.net", "yandex.com", "ya.ru", "vk.com", "userapi.com", "vk-cdn.net", "mycdn.me", "dzen.ru", "mail.ru", "ok.ru" };
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
            if (value.ContainsKey("directDomains")) o.DirectDomains = Strings(value, "directDomains");
            o.DnsServer = Json.Text(value, "dnsServer", o.DnsServer); o.CheckUrl = Json.Text(value, "checkUrl", o.CheckUrl); o.ProbeAddress = Json.Text(value, "probeAddress", o.ProbeAddress);
            Uri uri; IPAddress ip;
            if (Json.Get(value, "socksPort") is string || Json.Get(value, "socksPort") is bool || o.SocksPort < 1 || o.SocksPort > 65535 || o.Address.Length == 0 || o.Address.Length > 4 || o.ExcludeCidrs.Length > 256) throw new InvalidDataException("Неверные параметры VPN");
            foreach (var cidr in o.Address.Concat(o.ExcludeCidrs)) Cidr(cidr);
            if (o.DirectDomains.Length > 64 || o.DirectDomains.Any(d => d.Length == 0 || d.Length > 253 || !Regex.IsMatch(d, "^[a-z0-9.-]+$", RegexOptions.CultureInvariant))) throw new InvalidDataException("Неверный список прямых доменов VPN");
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
        { return D("cmd", "vpn.on", "socksPort", SocksPort, "address", Address, "excludeCidrs", ExcludeCidrs, "directDomains", DirectDomains, "dnsServer", DnsServer, "checkUrl", CheckUrl, "probeAddress", ProbeAddress); }
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
        // Имена конфликтующих VPN через запятую; правила — VpnConflict (VpnConflictScan.cs).
        internal static string Conflict(Dictionary<string, object> snapshot)
        { return MainScreenModel.CleanSecrets(VpnConflict.Evaluate(snapshot).Names); }
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
        internal static string PathState(Dictionary<string, object> transport, DateTime now = default(DateTime), Func<int, DateTime, bool> processAlive = null)
        { return !VpnWatchdog.TransportReady(transport, processAlive) ? "no-path" : !Json.Bool(Json.Map(Json.Get(transport, "helper")), "udp") ? "no-udp" : ""; }
        internal object Config(string user, string password, IEnumerable<string> endpoints, IEnumerable<string> lanSubnets, Dictionary<string, object> snapshot, Dictionary<string, object> dnsPolicy, int? socksPort = null)
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
            // Уровень info: строка готовности ядра («sing-box started») пишется на info; ниже уровнем её не видно.
            return D("log", D("level", "info", "timestamp", true),
                "inbounds", new[] { D("type", "tun", "tag", "vpn-tun", "interface_name", InterfaceName, "address", Address, "stack", "system", "auto_route", true, "strict_route", Json.Bool(dnsPolicy, "strictRoute"), "route_exclude_address", excluded) },
                "outbounds", new[] { D("type", "socks", "tag", "vpn-active", "server", "127.0.0.1", "server_port", socksPort ?? SocksPort, "version", "5", "username", user, "password", password), D("type", "direct", "tag", "vpn-direct", "domain_resolver", D("server", "vpn-local", "strategy", "ipv4_only")) },
                "route", D("auto_detect_interface", true, "final", "vpn-active", "default_domain_resolver", D("server", "vpn-local"), "rules", new[] {
                    D("inbound", new[] { "vpn-tun" }, "network", "tcp", "ip_cidr", new[] { ProbeAddress + "/32" }, "port", new[] { check.Port }, "action", "route-options", "override_address", check.DnsSafeHost, "override_port", check.Port),
                    D("inbound", new[] { "vpn-tun" }, "domain", new[] { check.DnsSafeHost }, "action", "resolve", "server", "vpn-dns", "disable_cache", true, "disable_optimistic_cache", true, "timeout", "3000ms"),
                    D("inbound", new[] { "vpn-tun" }, "domain", new[] { check.DnsSafeHost }, "action", "route", "outbound", "vpn-active"),
                    // IPv6 под VPN: адрес TUN fdfe:7261::1/126 остаётся, но v6-трафик отклоняется, AAAA-ответы пустые (без ошибки) — приложения сразу идут по IPv4.
                    // DNS-запросы по IPv6 сначала перехватываются (hijack-dns), иначе reject съест их раньше правил DNS.
                    D("inbound", new[] { "vpn-tun" }, "ip_version", 6, "port", new[] { 53 }, "action", "hijack-dns"),
                    D("ip_version", 6, "action", "reject"),
                    D("process_name", new[] { "powershell.exe", "python.exe", "pythonw.exe", "ssh.exe", "sing-box.exe", "syncthing.exe", "SyncthingTray.exe" }, "action", "route", "outbound", "vpn-direct"),
                    D("inbound", new[] { "vpn-tun" }, "action", "sniff"), D("protocol", "dns", "action", "hijack-dns"),
                    D("domain_suffix", DirectDomains, "action", "route", "outbound", "vpn-direct"),
                    D("ip_cidr", excluded, "action", "route", "outbound", "vpn-direct"), D("port", new[] { 53 }, "action", "hijack-dns") }),
                "dns", D("servers", new[] { D("type", "https", "tag", "vpn-dns", "server", DnsServer, "path", "/dns-query", "tls", D("enabled", true), "detour", "vpn-active"), D("type", "local", "tag", "vpn-local") },
                    "rules", new[] { D("query_type", new[] { "AAAA" }, "action", "predefined", "rcode", "NOERROR"), D("domain_suffix", DirectDomains, "action", "route", "server", "vpn-local") }, "final", "vpn-dns"));
        }

        static readonly string[] SecretKeys = { "password", "uuid", "private_key", "secret", "token" };
        // Копия конфигурации с замаскированными секретами (значения ключей password|uuid|private_key|secret|token → ***).
        internal static object MaskSecrets(object node)
        {
            var map = node as Dictionary<string, object>;
            if (map != null) {
                var copy = new Dictionary<string, object>();
                foreach (var pair in map) copy[pair.Key] = Array.IndexOf(SecretKeys, pair.Key) >= 0 ? (object)"***" : MaskSecrets(pair.Value);
                return copy;
            }
            var list = node as System.Collections.IEnumerable;
            if (list != null && !(node is string)) { var items = new List<object>(); foreach (var item in list) items.Add(MaskSecrets(item)); return items.ToArray(); }
            return node;
        }
        // Поля события vpn.config: что именно ушло в ядро, без секретов. Сам конфиг — отдельные события vpn.config.json (ConfigJsonParts).
        internal string[] ConfigFacts(object config, string text)
        {
            var root = config as Dictionary<string, object> ?? new Dictionary<string, object>();
            var inbound = Json.Array(Json.Get(root, "inbounds")).Select(Json.Map).FirstOrDefault() ?? new Dictionary<string, object>();
            var excluded = Json.Strings(Json.Get(inbound, "route_exclude_address"));
            Func<string, IPAddress, bool> covers = (c, ip) => { try { return Contains(c, ip); } catch { return false; } };
            var wide = excluded.Where(c => { int bits; var parts = c.Split('/'); return parts.Length == 2 && int.TryParse(parts[1], out bits) && bits < 9; }).Take(20).ToArray();
            var inv = System.Globalization.CultureInfo.InvariantCulture;
            string hash; using (var sha = System.Security.Cryptography.SHA256.Create()) hash = BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(text ?? ""))).Replace("-", "").ToLowerInvariant();
            return new[] { "sha256", hash, "bytes", Encoding.UTF8.GetByteCount(text ?? "").ToString(inv),
                "level", Json.Str(Json.Map(Json.Get(root, "log")), "level"), "strict", Json.Bool(inbound, "strict_route") ? "1" : "0",
                "excl4", excluded.Count(c => c.IndexOf(':') < 0).ToString(inv), "excl6", excluded.Count(c => c.IndexOf(':') >= 0).ToString(inv),
                "excl_wide", string.Join(",", wide), "covers1111", excluded.Any(c => covers(c, IPAddress.Parse("1.1.1.1"))) ? "1" : "0",
                "covers_probe", excluded.Any(c => covers(c, IPAddress.Parse(ProbeAddress))) ? "1" : "0", "direct_domains", DirectDomains.Length.ToString(inv),
                "json_parts", ConfigJsonParts(config).Length.ToString(inv) };
        }
        // Конфиг без секретов кусками: строка журнала ≤ RaLog.MaxLine, поэтому каждый кусок ограничен по длине С УЧЁТОМ экранирования
        // кавычек и обратной косой (maxPart). Всего не больше maxTotal знаков; если обрезано — truncated=1 в каждом куске.
        // Поля куска: part=i/n, truncated, json.
        internal static string[][] ConfigJsonParts(object config, int maxTotal = 16000, int maxPart = 3000)
        {
            // Секреты уже заменены MaskSecrets; RaLog.Format ещё раз чистит каждое значение, поэтому режем после запятой:
            // пара "ключ":значение не разрывается и повторная чистка не портит JSON на границе кусков.
            string json = Json.Encode(MaskSecrets(config));
            bool cut = json.Length > maxTotal; if (cut) json = json.Substring(0, maxTotal);
            maxPart = Math.Max(2, maxPart); var pieces = new List<string>(); int start = 0, escaped = 0, lastComma = -1;
            for (int i = 0; i < json.Length; i++) {
                char c = json[i]; int cost = c == '"' || c == '\\' ? 2 : 1;
                if (escaped + cost > maxPart) {
                    int end = lastComma >= start ? lastComma + 1 : i;
                    pieces.Add(json.Substring(start, end - start));
                    start = end; i = end - 1; escaped = 0; lastComma = -1; continue;
                }
                escaped += cost; if (c == ',') lastComma = i;
            }
            if (start < json.Length || pieces.Count == 0) pieces.Add(json.Substring(start));
            var inv = System.Globalization.CultureInfo.InvariantCulture;
            return pieces.Select((x, i) => new[] { "part", (i + 1).ToString(inv) + "/" + pieces.Count.ToString(inv), "truncated", cut ? "1" : "0", "json", x }).ToArray();
        }
        // Поля события vpn.check (чистая функция): код, результат, хвост вывода без секретов. Пароль помощника маскируется явно.
        internal static string[] CheckFields(Exception error, string code, string output, string password)
        {
            string shown = LogMask.Clean(output ?? "", string.IsNullOrEmpty(password) ? null : new[] { password }).Trim();
            if (shown.Length > 2000) shown = shown.Substring(shown.Length - 2000);
            return new[] { "code", error == null ? "0" : code, "result", error == null ? "ok" : "fail", "err", error == null ? "" : error.GetType().Name, "out", shown };
        }
        internal static LogLevel CheckLevel(Exception error) { return error == null ? LogLevel.Info : LogLevel.Warn; }
        // Маршруты на TUN из снимка сети: sing-tun ставит не 0/0 и не 0/1+128/1, а набор дополнений — считаем и показываем начало.
        internal static string[] TunRoutes(Dictionary<string, object> snapshot, string interfaceName)
        {
            var inv = System.Globalization.CultureInfo.InvariantCulture;
            string index = Json.Array(Json.Get(snapshot, "Adapters")).Select(Json.Map).Where(a => Json.Str(a, "Name") == interfaceName).Select(a => Json.Str(a, "ifIndex")).FirstOrDefault();
            var prefixes = index == null ? new string[0] : Json.Array(Json.Get(snapshot, "Routes")).Select(Json.Map).Where(r => Json.Str(r, "InterfaceIndex") == index).Select(r => Json.Str(r, "DestinationPrefix")).ToArray();
            return new[] { "tunroutes4", prefixes.Count(x => x.IndexOf(':') < 0).ToString(inv), "tunroutes6", prefixes.Count(x => x.IndexOf(':') >= 0).ToString(inv), "tunsample", string.Join(",", prefixes.Take(5)) };
        }
    }

    // Immutable evidence kept with the config actually launched, not merely the
    // latest transport status. DNS ordering/duplicates cannot cause a restart.
    internal sealed class VpnTunBinding
    {
        internal readonly int Port;
        internal readonly string[] Ips;
        internal readonly string Revision, Hosts;
        internal VpnTunBinding(int port, IEnumerable<string> ips, string revision, string hosts)
        { Port = port; Ips = ips.Select(ip => IPAddress.Parse(ip).ToString()).Distinct().OrderBy(ip => ip, StringComparer.Ordinal).ToArray(); Revision = revision; Hosts = hosts; }
        internal static int PortOf(Dictionary<string, object> transport)
        { int port = Json.Int(Json.Map(Json.Get(transport, "helper")), "vpnInPort", 0); return port > 0 && port <= 65535 ? port : 0; }
        internal static string HostsOf(Dictionary<string, object> transport)
        { return string.Join("\n", Json.Strings(Json.Get(transport, "endpoints")).Distinct().OrderBy(host => host, StringComparer.Ordinal)); }
        internal static string Key(Dictionary<string, object> transport)
        { return PortOf(transport) + "\n" + Json.Str(transport, "configRevision") + "\n" + HostsOf(transport); }
        internal bool Same(VpnTunBinding other) { return Port == other.Port && Ips.SequenceEqual(other.Ips); }
        internal static VpnTunBinding Resolve(Dictionary<string, object> transport, Func<string, IEnumerable<string>> resolve, int fallbackPort = 0)
        {
            var hosts = Json.Strings(Json.Get(transport, "endpoints"));
            if (hosts.Length == 0 || hosts.Length > 256) throw new InvalidDataException("Нет списка узлов канала");
            var ips = new List<string>();
            foreach (string host in hosts.Distinct()) {
                IPAddress ip;
                var addresses = IPAddress.TryParse(host, out ip) ? new[] { ip.ToString() } : resolve(host).ToArray();
                if (addresses.Length == 0) throw new InvalidDataException("Нет адресов узла канала");
                ips.AddRange(addresses);
            }
            int port = PortOf(transport);
            return new VpnTunBinding(port == 0 ? fallbackPort : port, ips, Json.Str(transport, "configRevision"), HostsOf(transport));
        }
    }

    // Only the owner thread consumes results or changes the running binding.
    // Resolution, config construction, file I/O and sing-box check run off-loop.
    internal sealed class VpnTunRebind
    {
        internal const int IntervalMs = 5000, RetryMs = 10000;
        sealed class Result { internal VpnTunBinding Binding; internal string Config, Key; }
        sealed class Work { internal Task<Result> Task; internal volatile bool Changed; }
        readonly Func<Dictionary<string, object>, VpnTunBinding> resolve;
        readonly Func<VpnTunBinding, Dictionary<string, object>, string, string> build;
        readonly Func<string, bool> activate;
        Work pending;
        Result prepared;
        long nextScan, nextRestart, nextBuild, retryAfter;
        string lastRequest;
        internal VpnTunBinding Binding { get; private set; }
        internal string Config { get; private set; }
        internal bool Failed { get; private set; }
        internal bool Preparing { get { return pending != null; } }
        internal VpnTunRebind(long now, VpnTunBinding binding, string config,
            Func<Dictionary<string, object>, VpnTunBinding> resolve,
            Func<VpnTunBinding, Dictionary<string, object>, string, string> build, Func<string, bool> activate)
        {
            Binding = binding; Config = config; this.resolve = resolve; this.build = build; this.activate = activate;
            nextScan = now + IntervalMs; lastRequest = binding.Port + "\n" + binding.Revision + "\n" + binding.Hosts;
        }
        static bool Ready(Dictionary<string, object> transport, Func<int, DateTime, bool> processAlive)
        { return VpnWatchdog.TransportReady(transport, processAlive) && VpnTunBinding.PortOf(transport) != 0 && Json.Str(transport, "configRevision").Length > 0 && VpnTunBinding.HostsOf(transport).Length > 0; }
        internal bool Searching(Dictionary<string, object> transport)
        {
            int port = VpnTunBinding.PortOf(transport);
            string hosts = VpnTunBinding.HostsOf(transport);
            return port != 0 && port != Binding.Port || hosts.Length > 0 && hosts != Binding.Hosts || Failed || prepared != null || pending != null && pending.Changed;
        }
        internal void Tick(long now, DateTime utcNow, Dictionary<string, object> transport, Func<int, DateTime, bool> processAlive = null)
        {
            bool ready = Ready(transport, processAlive); string key = VpnTunBinding.Key(transport);
            if (pending != null && pending.Task.IsCompleted) {
                try {
                    var result = pending.Task.GetAwaiter().GetResult();
                    // A discarded build also counts against the construction limit.
                    if (!Binding.Same(result.Binding)) nextBuild = now + IntervalMs;
                    if (ready && result.Key == key) {
                        Failed = false;
                        if (Binding.Same(result.Binding)) { Binding = result.Binding; nextScan = now + IntervalMs; }
                        else prepared = result;
                    } else nextScan = now;
                } catch { Failed = true; retryAfter = nextScan = now + RetryMs; }
                pending = null;
            }
            if (prepared != null && (!ready || prepared.Key != key)) { prepared = null; nextScan = now; }
            if (pending == null && prepared == null && ready && now >= retryAfter && now >= nextRestart && now >= nextBuild && (now >= nextScan || key != lastRequest)) {
                // Freeze publisher-owned dictionaries before handing them to a worker.
                var evidence = Json.Map(Json.Parse(Json.Encode(transport)));
                var running = Binding; string config = Config;
                var work = new Work(); lastRequest = key; nextScan = nextBuild = now + IntervalMs;
                work.Task = Task.Run(() => {
                    var binding = resolve(evidence); work.Changed = !running.Same(binding);
                    return new Result { Binding = binding, Key = key, Config = work.Changed ? build(binding, evidence, config) : config };
                });
                pending = work;
            }
        }
        // Called after publishing searching, so even an immediate successful launch
        // cannot publish on using the previous process's coreAlive observation.
        internal bool Apply(long now)
        {
            if (prepared == null || now < nextRestart) return false;
            var result = prepared; prepared = null; nextRestart = now + IntervalMs;
            bool started = false;
            try { started = activate(result.Config); } catch { }
            if (started) { Binding = result.Binding; Config = result.Config; Failed = false; nextScan = now + IntervalMs; }
            else { Failed = true; retryAfter = nextScan = now + RetryMs; }
            return true;
        }
    }

    // The same step drives the running session and portable lifecycle tests. Only a
    // stalled owner loop may call stop; transport/conflict evidence changes status.
    internal sealed class VpnTunMonitor
    {
        readonly Action<Dictionary<string, object>> publish;
        readonly Action<string> stop;
        readonly Action restart;
        readonly VpnTunRebind rebind;
        readonly Func<int, DateTime, bool> processAlive;
        readonly Dictionary<string, object> policy;
        long pulse, nextRestart, changedUntil;
        string revision, network, reasonCode = "", since = "";
        internal VpnTunMonitor(long now, Dictionary<string, object> transport, Dictionary<string, object> policy,
            Action<Dictionary<string, object>> publish, Action<string> stop, Action restart, VpnTunRebind rebind = null, Func<int, DateTime, bool> processAlive = null)
        {
            pulse = now; revision = Json.Str(transport, "configRevision"); network = Json.Str(transport, "network");
            this.policy = policy; this.publish = publish; this.stop = stop; this.restart = restart; this.rebind = rebind; this.processAlive = processAlive;
        }
        internal bool Step(long now, DateTime utcNow, bool coreAlive, Dictionary<string, object> transport, string conflict, bool inventoryFailed = false)
        {
            if (now - pulse > VpnLease.DeadlineMs) { stop("watchdog-stalled"); return false; }
            pulse = now;
            string state = "on", code = "ok", text = "";
            string path = VpnTun.PathState(transport, utcNow, processAlive);
            if (rebind != null) rebind.Tick(now, utcNow, transport, processAlive);
            if (VpnWatchdog.TransportReady(transport, processAlive)) {
                if (revision != Json.Str(transport, "configRevision") || network != Json.Str(transport, "network")) changedUntil = now + 500;
                revision = Json.Str(transport, "configRevision"); network = Json.Str(transport, "network");
            }
            if (rebind != null && rebind.Searching(transport)) { state = "searching"; code = "vpn-rebind"; text = rebind.Failed ? "Не удалось обновить настройки VPN, повторяю" : "Обновляю VPN под новые настройки связи"; }
            else if (!coreAlive) { state = "searching"; code = "path-process-exited"; text = "Сбой канала, перезапускаю"; }
            else if (conflict.Length > 0) { state = "conflict"; code = "vpn-conflict"; text = VpnWatchdog.FailureSummary("conflict", conflict); }
            else if (inventoryFailed) { state = "searching"; code = "conflict-check-failed"; text = "Не удалось проверить другие VPN"; }
            else if (path.Length > 0 || Json.Str(transport, "phase") == "searching" || Json.Str(transport, "localNet") == "down" || now < changedUntil) {
                state = "searching"; code = path.Length > 0 ? path : now < changedUntil ? "path-changed" : "no-path";
                text = code == "no-udp" ? "Текущий путь не передаёт UDP" : code == "path-changed" ? "Сменился путь канала" : "Нет живого пути к серверу";
                var reason = Json.Map(Json.Get(transport, "reason"));
                if (code != "no-udp" && code != "path-changed" && Json.Str(reason, "code").Length > 0 && Json.Str(reason, "code") != "ok" && Json.Str(reason, "text").Length > 0) {
                    code = MainScreenModel.CleanSecrets(Json.Str(reason, "code"));
                    text = MainScreenModel.CleanSecrets(Json.Str(reason, "text"));
                }
                if (Json.Str(transport, "localNet") == "down") { code = "local-network-down"; text = "Нет интернета у вас (сеть), жду"; }
            }
            if (code != reasonCode) { reasonCode = code; since = utcNow.ToString("o"); }
            publish(VpnTun.D("owner", "net-helper", "ok", state == "on", "enabled", true, "state", state, "stage", "monitor",
                "summary", state == "on" ? "VPN включён" : state == "conflict" ? text : VpnWatchdog.FailureSummary("searching") + ": " + text,
                "reason", VpnTun.D("code", code, "text", text, "since", since), "localNet", Json.Text(transport, "localNet", "unknown"),
                "conflictName", conflict, "dnsPolicy", policy, "updatedAt", utcNow.ToString("o")));
            // Restart a dead process inside the existing Job, never toggle VPN off/on.
            // Repeated immediate exits are bounded to one launch per second.
            bool rebound = rebind != null && rebind.Apply(now);
            if (!coreAlive && !rebound && now >= nextRestart) { nextRestart = now + 1000; restart(); }
            return true;
        }
    }

    // Slow PowerShell inventory must not block the owner-loop lease. At most one
    // fixed snapshot is in flight; results are consumed by the owner thread only.
    internal sealed class VpnTunConflictScan
    {
        internal const int IntervalMs = 5000;
        readonly Func<Dictionary<string, object>> snapshot;
        readonly Action<Dictionary<string, object>, VpnConflictResult> observe;
        readonly string ownDirectory;
        Task<Dictionary<string, object>> pending;
        long next;
        internal string Conflict { get; private set; }
        internal string Suspects { get; private set; }
        internal bool Failed { get; private set; }
        internal VpnTunConflictScan(long now, Func<Dictionary<string, object>> snapshot, Action<Dictionary<string, object>, VpnConflictResult> observe = null, string ownDirectory = null)
        { next = now + IntervalMs; this.snapshot = snapshot; this.observe = observe; this.ownDirectory = ownDirectory; Conflict = ""; Suspects = ""; }
        internal void Tick(long now)
        {
            if (pending != null && pending.IsCompleted) {
                try {
                    var taken = pending.GetAwaiter().GetResult();
                    var result = VpnConflict.Evaluate(taken, ownDirectory);
                    Conflict = MainScreenModel.CleanSecrets(result.Names); Suspects = MainScreenModel.CleanSecrets(result.SuspectNames); Failed = false;
                    if (observe != null) try { observe(taken, result); } catch { }
                }
                catch { Failed = true; }
                pending = null; next = now + IntervalMs;
            }
            if (pending == null && now >= next) { next = now + IntervalMs; pending = Task.Run(snapshot); }
        }
    }

    // Наблюдатель передаёт снимки; часы монотонные и подменяются в микро-тестах.
    internal sealed class VpnPathWait
    {
        // Предохранитель (конституция 4а): изменение transport.json недоступно, если демон не подтвердил путь; при срабатывании — no-path, успех не объявляет.
        internal const int VpnPathWaitFuseMs = 25000; // timer-ok: C — после перезапуска демон обычно подтверждает путь за 10–20 с; оставляем время exclusions/check/ready/routes в клиентских 70 с, при срабатывании — no-path.
        readonly long fuseAt;
        readonly Func<int, DateTime, bool> processAlive;
        internal Dictionary<string, object> Transport { get; private set; }
        internal string State { get; private set; }
        internal bool Complete { get; private set; }
        internal VpnPathWait(long now, Func<int, DateTime, bool> processAlive = null)
        { fuseAt = now + VpnPathWaitFuseMs; this.processAlive = processAlive; State = "no-path"; Transport = Json.Map(null); }
        internal void Changed(Dictionary<string, object> transport)
        {
            if (Complete) return;
            Transport = transport; State = VpnTun.PathState(transport, processAlive: processAlive);
            Complete = State != "no-path";
        }
        internal int Remaining(long now) { return (int)Math.Max(0, Math.Min(VpnPathWaitFuseMs, fuseAt - now)); }
        internal void CheckFuse(long now) { if (!Complete && Remaining(now) == 0) { State = "no-path"; Complete = true; } }
    }

    // Runtime has no WinForms or user-supplied executable/config paths. Each VPN owns its own Jobs.
    internal sealed class VpnTunSession : IDisposable
    {
        readonly string home, directory, executable;
        readonly Action<Action> asOwner;
        readonly Action<string, int> log;
        readonly object gate = new object(), preparationGate = new object();
        readonly ManualResetEvent wake = new ManualResetEvent(false);
        readonly Thread thread;
        readonly Stopwatch clock = Stopwatch.StartNew();
        Dictionary<string, object> status = VpnTun.D("enabled", false, "ok", false, "state", "off", "summary", "VPN выключен");
        NativeJob coreJob, preparationJob;
        Process core;
        // Журнал помощника (helper-events) и перенос вывода ядра; задаются службой, в тестах могут быть null.
        internal HelperEventLog Events;
        internal CoreLogPump CorePump;
        internal volatile CoreOutputReader CoreReader;
        // Шина службы (шаг B3): сюда публикуются vpn.state/vpn.step/singbox.fatal по выходу ядра (singbox.started и строки ядра — читатель вывода V1 через HelperBus); в тестах может быть null.
        internal EventBus Bus;
        void PublishBus(string evt, string[] kv)
        {
            var bus = Bus; if (bus == null) return;
            string topic = evt == "core.exit" ? BusTopics.SingboxFatal : evt == "vpn.on.step" || evt == "vpn.off.step" ? BusTopics.VpnStep : null;
            if (topic == null) return;
            var all = new List<string>(kv ?? new string[0]);
            if (topic == BusTopics.VpnStep) { all.Add("phase"); all.Add(evt == "vpn.on.step" ? "on" : "off"); }
            else { all.Add("core"); all.Add("vpn"); }
            bus.Publish(topic, topic == BusTopics.VpnStep ? BusTopics.Sources.Helper : BusTopics.Sources.VpnCore, all.ToArray());
        }
        void Ev(LogLevel level, string evt, params string[] kv)
        {
            try { PublishBus(evt, kv); } catch { }
            try { var events = Events; if (events != null) events.Write(level, evt.StartsWith("core.") ? "core" : evt.StartsWith("conflict.") ? "conflict" : "vpn", evt, kv); } catch { }
        }
        static string Ms(Stopwatch watch) { return watch.ElapsedMilliseconds.ToString(System.Globalization.CultureInfo.InvariantCulture); }
        Process StartCore(NativeJob job, string config)
        {
            var pump = CorePump;
            if (pump != null) pump.RotateIfLarge();
            Process process;
            if (pump != null) {
                var previous = CoreReader; if (previous != null) { previous.Drain(Events); previous.WriteStats(Events); }
                Microsoft.Win32.SafeHandles.SafeFileHandle readEnd;
                process = job.StartPiped(executable, new[] { "run", "-c", config }, directory, out readEnd);
                // Вывод ядра читается событийно из pipe (singbox.started / singbox.fatal / singbox.line в шину), а не опросом файла.
                var reader = new CoreOutputReader(new FileStream(readEnd, FileAccess.Read, 4096, false), pump.FilePath, "vpn", HelperBus.Publish);
                CoreReader = reader; pump.Reader = reader; reader.Start();
            } else process = job.Start(executable, new[] { "run", "-c", config }, directory);
            string cfg = Path.GetFileNameWithoutExtension(config).EndsWith("-b") ? "b" : "a";
            try { Ev(LogLevel.Info, "core.start", "pid", process.Id.ToString(System.Globalization.CultureInfo.InvariantCulture), "cfg", cfg); } catch { }
            return process;
        }
        DateTime coreStarted;
        string suspects = "";
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
                generation++; requested = options; pending = true; Set("starting", "prepare");
            }
            wake.Set();
        }
        internal void Disable()
        {
            var off = Stopwatch.StartNew();
            lock (gate) { CloseJobs(); generation++; pending = false; requested = null; Set("off", "button"); }
            Ev(LogLevel.Info, "vpn.off.step", "step", "close-jobs", "ms", Ms(off), "result", "ok");
            { var offBus = Bus; if (offBus != null) { try { offBus.Publish(BusTopics.VpnOff, BusTopics.Sources.Helper, "reason", "button"); } catch { } } } // ворота готовности ждут vpn.off
            wake.Set();
        }
        void CloseJobs()
        { lock (gate) { if (coreJob != null) { coreJob.Dispose(); coreJob = null; } if (preparationJob != null) { preparationJob.Dispose(); preparationJob = null; } } }
        void Set(string state, string stage, string name = "", Dictionary<string, object> policy = null)
        {
            var bus = Bus;
            if (bus != null) bus.Publish(BusTopics.VpnState, BusTopics.Sources.Helper, "state", state, "reason", stage, "enabled", state == "on" || state == "starting" ? "true" : "false", "ok", state == "on" ? "true" : "false", "name", name);
            lock (gate) status = VpnTun.D("ok", state == "on", "enabled", state == "on" || state == "starting", "state", state, "stage", stage,
                "summary", state == "on" ? "VPN включён" : state == "off" ? "VPN выключен" : state == "starting" ? "Включается…" : VpnWatchdog.FailureSummary(state, name.Length > 0 ? name : stage), "dnsPolicy", policy, "conflictName", state == "conflict" ? name : "", "suspects", suspects, "updatedAt", DateTime.UtcNow.ToString("o"));
        }
        Dictionary<string, object> Read(string relative)
        { Dictionary<string, object> result = null; asOwner(() => result = Json.Read(Path.Combine(home, relative))); return result; }
        Dictionary<string, object> Transport() { try { return Read("status/transport.json"); } catch { return Json.Map(null); } }
        Dictionary<string, object> AwaitTransport(int epoch)
        {
            var waiting = new VpnPathWait(clock.ElapsedMilliseconds);
            waiting.Changed(Transport());
            if (waiting.Complete) return waiting.Transport;
            lock (gate) if (epoch == generation) Set("starting", "path");
            FileSystemWatcher watcher = null;
            using (var changed = new AutoResetEvent(false)) {
                Exception watchError = null;
                try {
                    // Подписка и EnableRaisingEvents под тем же олицетворением, что и чтение.
                    asOwner(() => {
                        watcher = new FileSystemWatcher(Path.Combine(home, "status"), "transport.json");
                        watcher.NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size;
                        FileSystemEventHandler notify = (sender, args) => { try { changed.Set(); } catch (ObjectDisposedException) { } };
                        watcher.Changed += notify; watcher.Created += notify; watcher.Deleted += notify;
                        watcher.Renamed += (sender, args) => notify(sender, args); // Atomic replace / rename.
                        watcher.Error += (sender, args) => { Interlocked.Exchange(ref watchError, args.GetException() ?? new IOException("Transport watcher failed")); try { changed.Set(); } catch (ObjectDisposedException) { } };
                        watcher.EnableRaisingEvents = true;
                    });
                    // Повторное чтение ПОСЛЕ подписки закрывает гонку read/subscribe.
                    while (true) {
                        lock (gate) { if (disposed || epoch != generation) throw new OperationCanceledException(); wake.Reset(); }
                        var error = Interlocked.CompareExchange(ref watchError, null, null);
                        if (error != null) throw error;
                        waiting.CheckFuse(clock.ElapsedMilliseconds);
                        if (waiting.Complete) {
                            Ev(LogLevel.Warn, "vpn.path.wait", "result", "fuse", "reason", "no-path", "problem", VpnWatchdog.TransportProblem(waiting.Transport));
                            return Json.Map(null); // Предохранитель завершает отказом даже при позднем восстановлении процесса.
                        }
                        waiting.Changed(Transport());
                        if (waiting.Complete) return waiting.Transport;
                        WaitHandle.WaitAny(new WaitHandle[] { changed, wake }, waiting.Remaining(clock.ElapsedMilliseconds)); // timer-ok: C — нет события готовности пути; предохранитель возвращает no-path, успех не объявляет.
                    }
                } catch (OperationCanceledException) { throw; }
                catch (Exception error) {
                    Ev(LogLevel.Warn, "vpn.path.watch", "result", "failed", "err", error.GetType().Name, "msg", Msg(error.Message), "reason", "no-path", "problem", VpnWatchdog.TransportProblem(waiting.Transport));
                    return Json.Map(null); // Честный отказ без запасного опроса.
                } finally { if (watcher != null) watcher.Dispose(); }
            }
        }
        // Фиксированный снимок сети. Вывод PowerShell при перенаправлении идёт в OEM-кодировке, поэтому
        // все символы вне ASCII экранируются \uXXXX: файл не зависит от кодовой страницы.
        const string InventoryHead = @"$ErrorActionPreference='Stop';[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false);$e=New-Object Collections.ArrayList;function T($n,[scriptblock]$b){try{& $b}catch{[void]$e.Add($n)}};$k='(?i)(^|[^a-z])(happd?|happservice|xray|v2rayn?|sing-box|clash[a-z]*|mihomo|hiddify|nekoray|nekobox|outline|amnezia[a-z]*|wireguard|openvpn[a-z]*|tap-windows|proton(vpn)?|nordvpn|expressvpn|windscribe|tailscaled?|zerotier(one)?|radmin)([^a-z]|$)';";
        const string InventoryCore = @"Adapters=@(Get-NetAdapter -IncludeHidden|Select-Object Name,InterfaceDescription,ifIndex,Status,HardwareInterface,Virtual);Routes=@(Get-NetRoute -PolicyStore ActiveStore|Select-Object InterfaceIndex,DestinationPrefix,NextHop,RouteMetric);";
        const string InventoryDns = @"DnsServers=@(Get-DnsClientServerAddress|Select-Object InterfaceIndex,ServerAddresses);DnsClients=@(Get-DnsClient|Select-Object InterfaceIndex,ConnectionSpecificSuffix,ConnectionSpecificSuffixSearchList);Nrpt=@(Get-DnsClientNrptPolicy -Effective|Select-Object Namespace,NameServers,DirectAccessDnsServers);";
        const string InventoryExtra = @"IpInterfaces=@(T 'ipif' {Get-NetIPInterface -ConnectionState Connected|Select-Object InterfaceIndex,InterfaceAlias,AddressFamily,InterfaceMetric});Procs=@(T 'procs' {Get-Process -ErrorAction SilentlyContinue|Where-Object{$_.Name -match $k}|Select-Object Name,Path});Services=@(T 'services' {Get-Service -ErrorAction SilentlyContinue|Where-Object{$_.Status -eq 'Running' -and ($_.Name -match $k -or $_.DisplayName -match $k)}|Select-Object Name,DisplayName});";
        const string InventoryTail = @"$r.errors=@($e);$j=$r|ConvertTo-Json -Depth 10 -Compress;[regex]::Replace($j,'[^\x00-\x7F]',{param($m)('\u{0:x4}' -f [int][char]$m.Value)})";
        internal static string InventoryScript(bool adaptersOnly)
        { return InventoryHead + "$r=@{" + InventoryCore + (adaptersOnly ? "" : InventoryDns) + InventoryExtra + "};" + InventoryTail; }
        Dictionary<string, object> Snapshot(int epoch, bool adaptersOnly = false)
        {
            // Fixed inventory only. Never execute a script from the owner's writable home as SYSTEM.
            string script = InventoryScript(adaptersOnly);
            string file = Path.Combine(directory, adaptersOnly ? "vpn-adapters.json" : "vpn-inventory.json");
            RunPreparation(Files.Executable("powershell.exe"), new[] { "-NoProfile", "-NonInteractive", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(script)) }, file, epoch);
            if (new FileInfo(file).Length > 4 * 1024 * 1024) throw new InvalidDataException("Снимок сети слишком велик");
            // Старый вывод мог быть в OEM: строгий UTF-8, иначе OEM (как External.ReadPowerShellOutput).
            return Json.Map(Json.Parse(External.ReadPowerShellOutput(file)));
        }
        string lastPreparationCode = "-1"; // код выхода последней подготовки; "timeout"/"cancel" — не чужой код предыдущей
        static string Msg(string text) { text = LogMask.Clean(text ?? "").Replace("\r", " ").Replace("\n", " "); return text.Length > 500 ? text.Substring(0, 500) : text; }
        void RunPreparation(string exe, string[] args, string output, int epoch, bool merge = false)
        {
            // Conflict inventory and rebind validation share the cancellable slot.
            // Both callers are background workers once the owner lease is active.
            lock (preparationGate) RunPreparationLocked(exe, args, output, epoch, merge);
        }
        void RunPreparationLocked(string exe, string[] args, string output, int epoch, bool merge)
        {
            lastPreparationCode = "-1";
            var job = new NativeJob();
            lock (gate) { if (disposed || generation != epoch) { job.Dispose(); lastPreparationCode = "cancel"; throw new OperationCanceledException(); } preparationJob = job; }
            try {
                using (var process = merge ? job.StartLogged(exe, args, directory, output) : job.StartRedirected(exe, args, directory, output)) {
                    var elapsed = Stopwatch.StartNew();
                    while (!process.WaitForExit(50)) { lock (gate) if (disposed || generation != epoch) throw new OperationCanceledException(); if (elapsed.ElapsedMilliseconds > 15000) throw new TimeoutException(); }
                    lastPreparationCode = process.ExitCode.ToString(System.Globalization.CultureInfo.InvariantCulture);
                    if (process.ExitCode != 0) throw new InvalidDataException("Подготовка VPN отклонена");
                }
            } catch (TimeoutException) { lastPreparationCode = "timeout"; throw;
            } catch (OperationCanceledException) { lastPreparationCode = "cancel"; throw;
            } finally { job.Dispose(); lock (gate) if (preparationJob == job) preparationJob = null; }
        }
        void Stop(string reason, string stage, int epoch, string name = "")
        {
            CloseJobs(); // Must precede state and log I/O.
            lock (gate) {
                if (generation != epoch) return;
                Set(reason, stage, name);
            }
            log("vpn-" + reason + "-" + stage, 1);
            Ev(LogLevel.Warn, "vpn.stop", "reason", reason, "stage", stage, "name", name);
        }
        VpnTunBinding ResolveBinding(Dictionary<string, object> transport, int epoch, int fallbackPort)
        {
            var elapsed = Stopwatch.StartNew();
            return VpnTunBinding.Resolve(transport, host => {
                lock (gate) if (disposed || epoch != generation) throw new OperationCanceledException();
                if (elapsed.ElapsedMilliseconds > 15000) throw new TimeoutException();
                var lookup = Dns.GetHostAddressesAsync(host);
                if (!lookup.Wait(3000)) throw new TimeoutException();
                return lookup.GetAwaiter().GetResult().Select(ip => ip.ToString());
            }, fallbackPort);
        }
        // Run sessions are serialized on the owner thread. Reuse two slots across
        // enables, and only write the slot that is not used by the running core.
        internal static string ConfigPath(string directory, string current = null)
        {
            string first = Path.Combine(directory, "vpn-tun-a.json");
            return current == first ? Path.Combine(directory, "vpn-tun-b.json") : first;
        }
        string PrepareConfig(VpnTun options, VpnTunBinding binding, Dictionary<string, object> transport,
            Dictionary<string, object> snapshot, Dictionary<string, object> policy, int epoch, string config)
        {
            lock (gate) if (disposed || epoch != generation) throw new OperationCanceledException();
            var credential = Read("state/helper-socks.json");
            byte[] password = Convert.FromBase64String(Json.Str(credential, "password"));
            if (Json.Str(credential, "user") != "ra-helper" || password.Length != 32) throw new InvalidDataException("Нет учётных данных помощника");
            var lan = Json.Map(Json.Get(transport, "lan"));
            var built = options.Config("ra-helper", Json.Str(credential, "password"), binding.Ips, Json.Strings(Json.Get(lan, "subnets")), snapshot, policy, binding.Port);
            string text = Json.Encode(built);
            Files.Atomic(config, text);
            // Журнал пишется сразу после записи файла, до sing-box check и независимо от его исхода: итоговый конфиг (без секретов), затем vpn.check.
            try { Ev(LogLevel.Info, "vpn.config", options.ConfigFacts(built, text)); } catch (Exception e) { Ev(LogLevel.Warn, "vpn.config", "err", e.GetType().Name); }
            try { foreach (var part in VpnTun.ConfigJsonParts(built)) Ev(LogLevel.Info, "vpn.config.json", part); } catch (Exception e) { Ev(LogLevel.Warn, "vpn.config.json", "err", e.GetType().Name); }
            string outFile = Path.Combine(directory, "vpn-check.out");
            try { File.Delete(outFile); } catch { }
            Exception checkError = null;
            try { RunPreparation(executable, new[] { "check", "-c", config }, outFile, epoch, true); } catch (Exception e) { checkError = e; }
            string output = "";
            try { using (var s = new FileStream(outFile, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) { if (s.Length > 4096) s.Seek(-4096, SeekOrigin.End); using (var r = new StreamReader(s, new UTF8Encoding(false), true)) output = r.ReadToEnd(); } } catch { }
            Ev(VpnTun.CheckLevel(checkError), "vpn.check", VpnTun.CheckFields(checkError, lastPreparationCode, output, Json.Str(credential, "password")));
            if (checkError != null) throw checkError;
            return config;
        }
        void Run(VpnTun options, int epoch)
        {
            string stage = "inventory";
            VpnLease lease = null;
            VpnReadyGate readyGate = null; // подписка на шину службы: готовность ядра, fatal, vpn.off, win.route/iface (V3)
            var step = Stopwatch.StartNew();
            try {
                Ev(LogLevel.Info, "vpn.on.step", "step", "preflight", "ms", "0", "result", "begin");
                var snapshot = Snapshot(epoch);
                var found = VpnConflict.Evaluate(snapshot, directory);
                string conflict = MainScreenModel.CleanSecrets(found.Names);
                Ev(LogLevel.Info, "vpn.inventory", new[] { "phase", "before" }.Concat(VpnConflict.Describe(snapshot)).ToArray());
                suspects = MainScreenModel.CleanSecrets(found.SuspectNames);
                LogConflicts(found);
                Ev(conflict.Length > 0 ? LogLevel.Warn : LogLevel.Info, "vpn.on.step", "step", "inventory", "ms", Ms(step), "result", conflict.Length > 0 ? "conflict" : "ok", "reason", conflict.Length > 0 ? "conflict" : "", "conflict", conflict);
                if (conflict.Length > 0) { lock (gate) if (epoch == generation) Set("conflict", "conflicts", conflict); return; }
                var policy = VpnTun.DnsPolicy(snapshot);
                stage = "path"; step.Restart();
                var transport = AwaitTransport(epoch); string pathState = VpnTun.PathState(transport);
                if (pathState.Length > 0) { Ev(LogLevel.Warn, "vpn.on.step", "step", "path", "ms", Ms(step), "result", "fail", "reason", pathState, "problem", VpnWatchdog.TransportProblem(transport)); lock (gate) if (epoch == generation) Set(pathState, "path", TrayMenuModel.ActiveTitle(transport)); return; }
                stage = "exclusions"; step.Restart();
                // The same resolver/builder is used again while VPN stays enabled.
                var binding = ResolveBinding(transport, epoch, options.SocksPort);
                Ev(LogLevel.Info, "vpn.on.step", "step", "exclusions", "ms", Ms(step), "result", "ok", "endpoints", binding.Ips.Length.ToString(System.Globalization.CultureInfo.InvariantCulture), "port", binding.Port.ToString(System.Globalization.CultureInfo.InvariantCulture));
                stage = "config-check"; step.Restart();
                string config = PrepareConfig(options, binding, transport, snapshot, policy, epoch, ConfigPath(directory));
                Ev(LogLevel.Info, "vpn.on.step", "step", "config-check", "ms", Ms(step), "result", "ok");
                // Recheck channel/process facts immediately before creating the TUN.
                transport = Transport(); pathState = VpnTun.PathState(transport);
                if (pathState.Length > 0) { Ev(LogLevel.Warn, "vpn.on.step", "step", "path", "result", "fail", "reason", pathState, "problem", VpnWatchdog.TransportProblem(transport)); lock (gate) if (epoch == generation) Set(pathState, "path", TrayMenuModel.ActiveTitle(transport)); return; }
                if (binding.Revision != Json.Str(transport, "configRevision") || VpnTunBinding.PortOf(transport) != 0 && VpnTunBinding.PortOf(transport) != binding.Port || binding.Hosts != VpnTunBinding.HostsOf(transport)) { lock (gate) if (epoch == generation) Set("no-path", "path-changed"); return; }
                stage = "core-start"; step.Restart();
                var launchJob = new NativeJob();
                lock (gate) {
                    if (disposed || epoch != generation) { launchJob.Dispose(); return; }
                    coreJob = launchJob;
                }
                lease = new VpnLease(() => {
                    CloseJobs(); // No network/file/log I/O in the independent cutoff.
                    lock (gate) if (epoch == generation) Set("watchdog-stalled", "lease-expired");
                });
                // Подписка на шину — ДО запуска ядра, чтобы singbox.started не потерялось.
                var gateBus = Bus; if (gateBus != null) readyGate = new VpnReadyGate(gateBus);
                // Never hold the status/command lock across CreateProcess.
                core = StartCore(launchJob, config); coreStarted = DateTime.UtcNow;
                Ev(LogLevel.Info, "vpn.on.step", "step", "core-start", "ms", Ms(step), "result", "ok");
                // Ворота (V3): пока нет готовности ядра и маршрута на TUN, vpn.state on не объявляется (monitor создаётся только после них).
                if (readyGate != null) { stage = "ready"; if (!AwaitReadyAndRoute(readyGate, options, epoch, lease)) return; stage = "monitor"; }
                var rebind = new VpnTunRebind(clock.ElapsedMilliseconds, binding, config,
                    evidence => ResolveBinding(evidence, epoch, options.SocksPort),
                    (updated, evidence, current) => PrepareConfig(options, updated, evidence, snapshot, policy, epoch, ConfigPath(directory, current)),
                    candidate => {
                        lock (gate) if (disposed || epoch != generation || lease.Expired) return false;
                        try {
                            if (core != null) {
                                if (!core.WaitForExit(0)) core.Kill();
                                if (!core.WaitForExit(1000)) return false;
                                core.Dispose(); core = null;
                            }
                            Ev(LogLevel.Info, "core.restart", "why", "rebind");
                            core = StartCore(launchJob, candidate); coreStarted = DateTime.UtcNow;
                            return true;
                        } catch { log("vpn-core-rebind-failed", 1); Ev(LogLevel.Warn, "vpn.on.step", "step", "rebind", "result", "failed", "reason", "core-rebind-failed"); return false; }
                    });
                string lastMonitor = ""; bool coreExitLogged = false;
                var monitor = new VpnTunMonitor(clock.ElapsedMilliseconds, transport, policy,
                    value => {
                        value["suspects"] = suspects;
                        lock (gate) if (epoch == generation && !lease.Expired) status = value;
                        string key = Json.Str(value, "state") + "/" + Json.Str(Json.Map(Json.Get(value, "reason")), "code");
                        if (key != lastMonitor) { lastMonitor = key; var monitorBus = Bus; if (monitorBus != null) monitorBus.Publish(BusTopics.VpnState, BusTopics.Sources.Helper, "state", Json.Str(value, "state"), "reason", Json.Str(Json.Map(Json.Get(value, "reason")), "code"), "enabled", "true", "ok", Json.Str(value, "state") == "on" ? "true" : "false", "name", ""); Ev(Json.Str(value, "state") == "on" ? LogLevel.Info : LogLevel.Warn, "vpn.monitor", "state", Json.Str(value, "state"), "reason", Json.Str(Json.Map(Json.Get(value, "reason")), "code"), "text", Json.Str(Json.Map(Json.Get(value, "reason")), "text")); }
                    },
                    reason => Stop(reason, "owner-loop", epoch),
                    () => {
                        lock (gate) if (disposed || epoch != generation || lease.Expired) return;
                        if (core != null) { core.Dispose(); core = null; }
                        try { Ev(LogLevel.Warn, "core.restart", "why", "exited"); core = StartCore(launchJob, rebind.Config); coreStarted = DateTime.UtcNow; coreExitLogged = false; }
                        catch { log("vpn-core-restart-failed", 1); Ev(LogLevel.Warn, "vpn.on.step", "step", "restart", "result", "failed", "reason", "core-restart-failed"); }
                    }, rebind);
                string lastConflictKey = found.Key; bool afterLogged = false;
                var scan = new VpnTunConflictScan(clock.ElapsedMilliseconds, () => Snapshot(epoch, true), (taken, result) => {
                    suspects = MainScreenModel.CleanSecrets(result.SuspectNames);
                    if (!afterLogged) { afterLogged = true; Ev(LogLevel.Info, "vpn.inventory", new[] { "phase", "after" }.Concat(VpnTun.TunRoutes(taken, VpnTun.InterfaceName)).Concat(VpnConflict.Describe(taken)).ToArray()); }
                    if (result.Key != lastConflictKey) { lastConflictKey = result.Key; LogConflicts(result); }
                }, directory);
                long nextRead = 0;
                stage = "monitor"; step.Restart();
                while (true) {
                    lock (gate) if (disposed || epoch != generation) return;
                    if (lease.Expired) return;
                    long now = clock.ElapsedMilliseconds;
                    if (now >= nextRead) { transport = Transport(); nextRead = now + 500; } // timer-ok: B — перечитывание, решение по фактам; замена на наблюдатель в W2
                    scan.Tick(now);
                    if (core != null && core.WaitForExit(0) && !coreExitLogged) { coreExitLogged = true; LogCoreExit(core); }
                    { var reader = CoreReader; if (reader != null) reader.Drain(Events); } // очередь строк ядра на каждом проходе (не таймер)
                    if (!monitor.Step(clock.ElapsedMilliseconds, DateTime.UtcNow, core != null && !core.WaitForExit(0), transport, scan.Conflict, scan.Failed)) return;
                    if (lease.Expired) return;
                    lease.Pulse();
                    wake.WaitOne(VpnWatchdog.PollMs); wake.Reset();
                }
            } catch (OperationCanceledException) { }
            catch (Exception failure) {
                Ev(LogLevel.Error, "vpn.on.step", "step", stage, "ms", Ms(step), "result", "error", "err", failure.GetType().Name, "msg", Msg(failure.Message), "code", TickFailureLog.ErrorCode(failure).ToString(System.Globalization.CultureInfo.InvariantCulture));
                Stop(lease != null && lease.Expired ? "watchdog-stalled" : "error", stage, epoch);
            }
            finally {
                // Invalidate a queued inventory before closing its Job: it must not
                // start another PowerShell after this session has ended.
                lock (gate) if (epoch == generation) generation++;
                CloseJobs();
                { var reader = CoreReader; if (reader != null) { reader.Drain(Events); reader.WriteStats(Events); } }
                if (readyGate != null) readyGate.Dispose();
                if (lease != null) lease.Dispose();
                if (core != null) { core.Dispose(); core = null; }
            }
        }
        // Шаги 1.3 и 1.4 (V3). true — можно создавать monitor; false — состояние уже выставлено (Stop) или это обычное выключение.
        // Каждый шаг пишется в журнал сразу (vpn.on.step -> и в шину как vpn.step).
        bool AwaitReadyAndRoute(VpnReadyGate ready, VpnTun options, int epoch, VpnLease lease)
        {
            var watch = Stopwatch.StartNew();
            Func<bool> cancelled = () => { lock (gate) return disposed || epoch != generation || lease.Expired; };
            Func<bool> exited = () => { var c = core; try { return c == null || c.WaitForExit(0); } catch { return true; } };
            lock (gate) if (epoch == generation) Set("starting", "wait-core");
            // Предохранитель (конституция 4а): singbox.started недоступно, если ядро зависло внутри Start; при срабатывании — остановить ядро, error/core-not-ready, успех не объявляет.
            var coreOutcome = ready.AwaitCore(exited, cancelled, lease.Pulse, VpnReadyGate.FuseAfter(VpnReadyGate.CoreReadyFuseMs));
            string ms = Ms(watch);
            if (coreOutcome == VpnGateOutcome.Off) { Ev(LogLevel.Info, "vpn.on.step", "step", "ready", "ms", ms, "result", "cancel", "reason", "off"); return false; }
            if (coreOutcome == VpnGateOutcome.Ready) Ev(LogLevel.Info, "vpn.on.step", "step", "ready", "ms", ms, "result", "ok", "line", ready.ReadyLine);
            else {
                string code = "?"; try { var c = core; if (c != null && c.WaitForExit(0)) code = c.ExitCode.ToString(System.Globalization.CultureInfo.InvariantCulture); } catch { }
                string fatalLine = ready.FatalLine; if (fatalLine.Length > 500) fatalLine = fatalLine.Substring(0, 500);
                string reason = coreOutcome == VpnGateOutcome.Fuse ? "core-not-ready" : "core-exited";
                Ev(LogLevel.Warn, "vpn.on.step", "step", "ready", "ms", ms, "result", "fail", "reason", reason, "code", code, "fatal", fatalLine);
                if (coreOutcome == VpnGateOutcome.Fuse) Stop("error", "core-not-ready", epoch); else Stop("core-exited", "ready", epoch);
                return false;
            }
            watch.Restart();
            lock (gate) if (epoch == generation) Set("starting", "wait-routes");
            System.Net.IPAddress probeAddress = System.Net.IPAddress.Parse(options.ProbeAddress);
            VpnRouteResult route;
            // Предохранитель (конституция 4а): win.route/iface.changed недоступны, если маршрут на TUN так и не подтверждён; при срабатывании — остановить ядро, error/routes-not-ours, успех не объявляет.
            var routeOutcome = ready.AwaitRoute(() => VpnReadyGate.ProbeRoute(NetRoute.BestInterface, NetRoute.IndexByName, NetRoute.NameOf, probeAddress, VpnTun.InterfaceName),
                cancelled, lease.Pulse, VpnReadyGate.FuseAfter(VpnReadyGate.RouteFuseMs), out route);
            ms = Ms(watch);
            if (routeOutcome == VpnGateOutcome.Off) { Ev(LogLevel.Info, "vpn.on.step", "step", "routes", "ms", ms, "result", "cancel", "reason", "off"); return false; }
            var fields = new List<string> { "step", "routes", "ms", ms, "result", routeOutcome == VpnGateOutcome.RoutesOk ? "ok" : "fail" };
            if (routeOutcome != VpnGateOutcome.RoutesOk) { fields.Add("reason"); fields.Add("routes-not-ours"); }
            if (route != null) fields.AddRange(route.Fields());
            Ev(routeOutcome == VpnGateOutcome.RoutesOk ? LogLevel.Info : LogLevel.Warn, "vpn.on.step", fields.ToArray());
            if (routeOutcome == VpnGateOutcome.RoutesOk) return true;
            Stop("error", "routes-not-ours", epoch);
            return false;
        }
        void LogConflicts(VpnConflictResult result)
        {
            foreach (var c in result.Conflicts)
                Ev(LogLevel.Warn, "conflict.detected", "name", c.Name, "iface", c.Iface, "ifIndex", c.IfIndex.ToString(System.Globalization.CultureInfo.InvariantCulture), "route", c.Route, "metric", c.Metric.ToString(System.Globalization.CultureInfo.InvariantCulture), "why", c.Why);
            foreach (var x in result.Suspects) Ev(LogLevel.Info, "conflict.suspect", "name", x.Name, "kind", x.Kind);
            if (result.Conflicts.Count == 0 && result.Suspects.Count == 0) Ev(LogLevel.Info, "conflict.clear");
        }
        void LogCoreExit(Process exited)
        {
            try {
                var pump = CorePump; var reader = CoreReader;
                if (reader != null) reader.Drain(Events);
                string code = "?"; try { code = exited.ExitCode.ToString(System.Globalization.CultureInfo.InvariantCulture); } catch { }
                long alive = (long)Math.Max(0, (DateTime.UtcNow - coreStarted).TotalMilliseconds);
                Ev(LogLevel.Warn, "core.exit", "code", code, "ms_alive", alive.ToString(System.Globalization.CultureInfo.InvariantCulture), "tail", reader != null ? reader.Tail(15) : pump == null ? "" : pump.Tail(15));
                if (reader != null) reader.WriteStats(Events);
            } catch { }
        }
        void Loop()
        {
            while (true) {
                VpnTun options; int epoch;
                lock (gate) { if (disposed) return; options = pending ? requested : null; pending = false; epoch = generation; }
                if (options != null) Run(options, epoch);
                else { wake.WaitOne(250); wake.Reset(); }
            }
        }
        public void Dispose()
        {
            lock (gate) { CloseJobs(); disposed = true; generation++; pending = false; }
            wake.Set(); // Do not wait for potentially stalled I/O on the SCM shutdown thread.
        }
    }
}
