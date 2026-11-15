using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace RemoteAgents.Launcher
{
    internal static class VpnServiceNames
    {
        public const string ServiceName = "RemoteAgentsTun", PipeName = "RemoteAgentsTun", ExeName = "RemoteAgentsTun.exe", SingBoxName = "sing-box.exe";
        public const int Protocol = 1, RollbackSeconds = 300;
        public static string InstallDirectory(string programFiles) { return Path.Combine(programFiles, "RemoteAgents", "vpn"); }
        public static string RunDirectory(string installDir) { return Path.Combine(installDir, "run"); }
        public static string OwnerFile(string installDir) { return Path.Combine(installDir, "owner.json"); }
    }
    internal sealed class VpnPolicyException : Exception
    {
        public readonly string Code;
        public VpnPolicyException(string code) : base(code) { Code = code; }
    }
    internal sealed class VpnRequest { public string Command; public int WatchPid; public string Session; public object Config; }
    internal sealed class VpnTunPlan { public Dictionary<string, object> Config; public string InterfaceName, DefaultInterface, Selected; }
    internal static class VpnServicePolicy
    {
        public const int MaxRequestBytes = 1048576;
        const string HostPattern = @"\A(?=.{1,253}\z)[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\z";
        internal static VpnPolicyException Bad(string path) { return new VpnPolicyException("bad-value:" + path); }
        internal static Dictionary<string, object> Map(object value, string path, params string[] keys)
        {
            var source = value as IDictionary; if (source == null) throw Bad(path);
            var result = new Dictionary<string, object>(StringComparer.Ordinal);
            foreach (DictionaryEntry entry in source) {
                var key = entry.Key as string;
                if (key == null || !keys.Contains(key)) throw new VpnPolicyException("unknown-field:" + (path.Length == 0 ? "" : path + ".") + SafeKey(key));
                result.Add(key, entry.Value);
            }
            return result;
        }
        // Do not echo arbitrary attacker-controlled text in diagnostics.
        static string SafeKey(string key) { return Regex.IsMatch(key ?? "", @"\A[A-Za-z_][A-Za-z0-9_]{0,95}\z") ? key : "field"; }
        internal static object Need(Dictionary<string, object> map, string key, string path) { object v; if (!map.TryGetValue(key, out v)) throw Bad(path); return v; }
        internal static string Str(object value, string path) { var s = value as string; if (s == null) throw Bad(path); return s; }
        static string Match(object value, string path, string pattern) { string s = Str(value, path); if (!Regex.IsMatch(s, pattern, RegexOptions.CultureInvariant)) throw Bad(path); return s; }
        static string Choice(object value, string path, params string[] choices) { string s = Str(value, path); if (!choices.Contains(s)) throw Bad(path); return s; }
        internal static int Number(object value, string path, int min, int max)
        {
            if (!(value is int || value is long || value is decimal || value is double)) throw Bad(path);
            decimal d; try { d = Convert.ToDecimal(value, CultureInfo.InvariantCulture); } catch { throw Bad(path); }
            if (d != decimal.Truncate(d) || d < min || d > max || (value is double && (double)value != Math.Truncate((double)value))) throw Bad(path);
            return (int)d;
        }
        static bool Bool(object value, string path) { if (!(value is bool)) throw Bad(path); return (bool)value; }
        static object Exact(object value, object expected, string path) { if (!expected.Equals(value)) throw Bad(path); return expected; }
        internal static object[] List(object value, string path, int min, int max, bool singleton = false)
        {
            object[] a;
            if (singleton && value is string) a = new[] { value };
            else if (value is IEnumerable && !(value is string) && !(value is IDictionary)) a = ((IEnumerable)value).Cast<object>().ToArray();
            else throw Bad(path);
            if (a.Length < min || a.Length > max) throw Bad(path); return a;
        }
        static string Ip(object value, string path) { IPAddress ip; if (!IPAddress.TryParse(Str(value, path), out ip)) throw Bad(path); return ip.ToString(); }
        static string Host(object value, string path) { string s = Str(value, path); IPAddress ip; return IPAddress.TryParse(s, out ip) ? ip.ToString() : Match(s, path, HostPattern); }
        static string Cidr(object value, string path, bool probe = false)
        {
            string s = Str(value, path); string[] parts = s.Split('/'); IPAddress ip; int bits;
            if (parts.Length != 2 || !IPAddress.TryParse(parts[0], out ip) || !Regex.IsMatch(parts[1], @"\A[0-9]{1,3}\z") || !int.TryParse(parts[1], out bits) || bits > (ip.AddressFamily == AddressFamily.InterNetwork ? 32 : 128)) throw Bad(path);
            if (probe && (ip.AddressFamily != AddressFamily.InterNetwork || bits != 32)) throw Bad(path);
            return ip + "/" + bits.ToString(CultureInfo.InvariantCulture);
        }
        static string Secret(object value, string path) { string s = Str(value, path); if (s.Length < 1 || s.Length > 512 || s.Any(char.IsControl)) throw Bad(path); return s; }
        static string Uuid(object value, string path) { return Match(value, path, @"\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z"); }
        internal static Dictionary<string, object> Obj(params object[] pairs) { var d = new Dictionary<string, object>(); for (int i = 0; i < pairs.Length; i += 2) d.Add((string)pairs[i], pairs[i + 1]); return d; }
        public static VpnRequest ParseRequest(object parsedJson)
        {
            var root = parsedJson as IDictionary; if (root == null) throw Bad("request");
            try { if (!root.Contains("protocol") || Number(root["protocol"], "protocol", 0, int.MaxValue) != 1) throw new VpnPolicyException("bad-protocol"); }
            catch (VpnPolicyException) { throw new VpnPolicyException("bad-protocol"); }
            string command = root["command"] as string;
            if (!new[] { "status", "start", "confirm", "stop" }.Contains(command)) throw new VpnPolicyException("bad-command");
            var m = Map(root, "", command == "start" ? new[] { "protocol", "command", "watchPid", "config" } : command == "confirm" || command == "stop" ? new[] { "protocol", "command", "session" } : new[] { "protocol", "command" });
            var r = new VpnRequest { Command = command };
            if (command == "start") { r.WatchPid = Number(Need(m, "watchPid", "watchPid"), "watchPid", 0, int.MaxValue); r.Config = Need(m, "config", "config"); if (!(r.Config is IDictionary)) throw Bad("config"); }
            if (command == "confirm" || m.ContainsKey("session")) r.Session = Match(Need(m, "session", "session"), "session", @"\A[0-9a-f]{32}\z");
            return r;
        }
        static Dictionary<string, object> Tls(object value, string p)
        {
            var m = Map(value, p, "enabled", "server_name", "insecure", "alpn", "utls", "reality");
            var d = Obj("enabled", Bool(Need(m, "enabled", p + ".enabled"), p + ".enabled"));
            if (m.ContainsKey("server_name")) d["server_name"] = Host(m["server_name"], p + ".server_name");
            if (m.ContainsKey("insecure")) d["insecure"] = Bool(m["insecure"], p + ".insecure");
            if (m.ContainsKey("alpn")) d["alpn"] = List(m["alpn"], p + ".alpn", 0, 3, true).Select(x => Choice(x, p + ".alpn", "h3", "h2", "http/1.1")).ToArray();
            if (m.ContainsKey("utls")) {
                string q = p + ".utls"; var u = Map(m["utls"], q, "enabled", "fingerprint");
                d["utls"] = Obj("enabled", Bool(Need(u, "enabled", q), q), "fingerprint", Choice(Need(u, "fingerprint", q), q, "chrome", "firefox", "edge", "safari", "360", "qq", "ios", "android", "random", "randomized"));
            }
            if (m.ContainsKey("reality")) {
                string q = p + ".reality"; var u = Map(m["reality"], q, "enabled", "public_key", "short_id");
                d["reality"] = Obj("enabled", Bool(Need(u, "enabled", q), q), "public_key", Match(Need(u, "public_key", q), q + ".public_key", @"\A[A-Za-z0-9_-]{40,64}\z"), "short_id", Match(Need(u, "short_id", q), q + ".short_id", @"\A([0-9a-fA-F]{2}){0,8}\z"));
            }
            return d;
        }
        static Dictionary<string, object> Transport(object value, string p)
        {
            var m = Map(value, p, "type", "path", "headers", "max_early_data", "early_data_header_name");
            var d = Obj("type", Exact(Need(m, "type", p), "ws", p + ".type"), "path", Match(Need(m, "path", p), p + ".path", @"\A/[\x21-\x7E]{0,255}\z"));
            if (m.ContainsKey("headers")) { var h = Map(m["headers"], p + ".headers", "Host"); d["headers"] = Obj("Host", Match(Need(h, "Host", p), p + ".headers.Host", HostPattern)); }
            if (m.ContainsKey("max_early_data")) d["max_early_data"] = Number(m["max_early_data"], p + ".max_early_data", 0, 65536);
            if (m.ContainsKey("early_data_header_name")) d["early_data_header_name"] = Exact(m["early_data_header_name"], "Sec-WebSocket-Protocol", p + ".early_data_header_name");
            return d;
        }
        static Dictionary<string, object> Outbound(object value, string p, string iface)
        {
            var raw = value as IDictionary; if (raw == null) throw Bad(p);
            string type = Choice(raw["type"], p + ".type", "vless", "trojan", "hysteria2", "tuic", "shadowtls", "shadowsocks");
            var keys = new List<string> { "type", "tag", "server", "server_port", "detour", "bind_interface", "domain_resolver" };
            if (type == "vless") keys.AddRange(new[] { "uuid", "flow", "packet_encoding", "tls", "transport" });
            if (type == "trojan") keys.AddRange(new[] { "password", "tls", "transport" });
            if (type == "hysteria2") keys.AddRange(new[] { "password", "obfs", "tls" });
            if (type == "tuic") keys.AddRange(new[] { "uuid", "password", "congestion_control", "tls" });
            if (type == "shadowtls") keys.AddRange(new[] { "version", "password", "tls" });
            if (type == "shadowsocks") keys.AddRange(new[] { "method", "password" });
            var m = Map(value, p, keys.ToArray());
            string tag = Match(Need(m, "tag", p), p + ".tag", @"\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,95}\z");
            if (new[] { "vpn-active", "vpn-tun", "bootstrap", "vpn-dns" }.Contains(tag)) throw Bad(p + ".tag");
            var d = Obj("type", type, "tag", tag);
            if (m.ContainsKey("detour")) d["detour"] = Match(m["detour"], p + ".detour", @"\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,95}\z");
            if (type == "shadowsocks" && m.ContainsKey("detour")) {
                if (m.ContainsKey("server") || m.ContainsKey("server_port")) throw Bad(p + ".server");
            } else { d["server"] = Host(Need(m, "server", p), p + ".server"); d["server_port"] = Number(Need(m, "server_port", p), p + ".server_port", 1, 65535); }
            if (m.ContainsKey("bind_interface")) Exact(m["bind_interface"], iface, p + ".bind_interface");
            if (m.ContainsKey("domain_resolver")) Exact(m["domain_resolver"], "bootstrap", p + ".domain_resolver");
            if (!m.ContainsKey("detour")) { d["bind_interface"] = iface; d["domain_resolver"] = "bootstrap"; }
            if (type == "vless" || type == "tuic") d["uuid"] = Uuid(Need(m, "uuid", p), p + ".uuid");
            if (type != "vless") d["password"] = Secret(Need(m, "password", p), p + ".password");
            if (m.ContainsKey("flow")) d["flow"] = Choice(m["flow"], p + ".flow", "", "xtls-rprx-vision");
            if (m.ContainsKey("packet_encoding")) d["packet_encoding"] = Choice(m["packet_encoding"], p + ".packet_encoding", "", "xudp", "packetaddr");
            if (type == "tuic") d["congestion_control"] = Choice(Need(m, "congestion_control", p), p + ".congestion_control", "cubic", "new_reno", "bbr");
            if (type == "shadowtls") d["version"] = Number(Need(m, "version", p), p + ".version", 1, 3);
            if (type == "shadowsocks") d["method"] = Choice(Need(m, "method", p), p + ".method", "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305", "aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305");
            if (m.ContainsKey("obfs")) { string q = p + ".obfs"; var o = Map(m["obfs"], q, "type", "password"); d["obfs"] = Obj("type", Exact(Need(o, "type", q), "salamander", q), "password", Secret(Need(o, "password", q), q + ".password")); }
            if (type == "tuic" || type == "hysteria2" || type == "shadowtls") Need(m, "tls", p + ".tls");
            if (m.ContainsKey("tls")) d["tls"] = Tls(m["tls"], p + ".tls");
            if (m.ContainsKey("transport")) d["transport"] = Transport(m["transport"], p + ".transport");
            return d;
        }
        public static VpnTunPlan BuildConfig(object clientConfig)
        {
            var root = Map(clientConfig, "", "log", "inbounds", "outbounds", "route", "dns");
            var log = Map(Need(root, "log", "log"), "log", "disabled"); Exact(Need(log, "disabled", "log.disabled"), true, "log.disabled");
            var inbound = List(Need(root, "inbounds", "inbounds"), "inbounds", 1, 1);
            var tun = Map(inbound[0], "inbounds[0]", "type", "tag", "interface_name", "address", "stack", "auto_route", "strict_route", "route_exclude_address");
            foreach (var pair in Obj("type", "tun", "tag", "vpn-tun", "stack", "system", "auto_route", true, "strict_route", false)) Exact(Need(tun, pair.Key, "inbounds[0]." + pair.Key), pair.Value, "inbounds[0]." + pair.Key);
            string name = Match(Need(tun, "interface_name", "inbounds[0].interface_name"), "inbounds[0].interface_name", @"\ARemoteAgents-[a-zA-Z0-9_-]{1,32}\z");
            var addresses = List(Need(tun, "address", "inbounds[0].address"), "inbounds[0].address", 1, 4, true).Select(x => Cidr(x, "inbounds[0].address")).ToArray();
            var excludes = List(Need(tun, "route_exclude_address", "inbounds[0].route_exclude_address"), "inbounds[0].route_exclude_address", 0, 4096, true).Select(x => Cidr(x, "inbounds[0].route_exclude_address")).ToArray();
            var route = Map(Need(root, "route", "route"), "route", "auto_detect_interface", "default_interface", "default_domain_resolver", "final", "rules");
            Exact(Need(route, "auto_detect_interface", "route"), true, "route.auto_detect_interface"); Exact(Need(route, "default_domain_resolver", "route"), "bootstrap", "route.default_domain_resolver"); Exact(Need(route, "final", "route"), "vpn-active", "route.final");
            string iface = Str(Need(route, "default_interface", "route"), "route.default_interface");
            if (iface.Length < 1 || iface.Length > 256 || iface.Any(c => char.IsControl(c) || c == '"' || c == '\\' || c == '/')) throw Bad("route.default_interface");
            var rules = List(Need(route, "rules", "route.rules"), "route.rules", 2, 2);
            string rp = "route.rules[0]";
            var probe = Map(rules[0], rp, "inbound", "network", "port", "ip_cidr", "action", "outbound", "override_address", "override_port");
            var ins = List(Need(probe, "inbound", rp), rp + ".inbound", 1, 1, true); Exact(ins[0], "vpn-tun", rp + ".inbound");
            foreach (var pair in Obj("network", "tcp", "action", "route", "outbound", "vpn-active")) Exact(Need(probe, pair.Key, rp), pair.Value, rp + "." + pair.Key);
            object portValue = Need(probe, "port", rp); var ports = (portValue is IEnumerable && !(portValue is string) ? List(portValue, rp + ".port", 1, 2) : new[] { portValue }).Select(x => Number(x, rp + ".port", 1, 65535)).ToArray();
            int port = Number(Need(probe, "override_port", rp), rp + ".override_port", 1, 65535); if (!ports.Contains(port) || !ports.Contains(22)) throw Bad(rp + ".port");
            string server = Host(Need(probe, "override_address", rp), rp + ".override_address");
            string cidr = Cidr(List(Need(probe, "ip_cidr", rp), rp + ".ip_cidr", 1, 1, true)[0], rp + ".ip_cidr", true);
            var hijack = Map(rules[1], "route.rules[1]", "protocol", "action"); Exact(Need(hijack, "protocol", "route.rules[1]"), "dns", "route.rules[1].protocol"); Exact(Need(hijack, "action", "route.rules[1]"), "hijack-dns", "route.rules[1].action");
            var dns = Map(Need(root, "dns", "dns"), "dns", "servers", "final"); Exact(Need(dns, "final", "dns"), "vpn-dns", "dns.final");
            var ds = List(Need(dns, "servers", "dns.servers"), "dns.servers", 2, 2);
            var boot = Map(ds[0], "dns.servers[0]", "type", "tag", "server", "bind_interface");
            var secure = Map(ds[1], "dns.servers[1]", "type", "tag", "server", "detour");
            foreach (var pair in Obj("type", "udp", "tag", "bootstrap", "bind_interface", iface)) Exact(Need(boot, pair.Key, "dns.servers[0]"), pair.Value, "dns.servers[0]." + pair.Key);
            foreach (var pair in Obj("type", "https", "tag", "vpn-dns", "detour", "vpn-active")) Exact(Need(secure, pair.Key, "dns.servers[1]"), pair.Value, "dns.servers[1]." + pair.Key);
            string dnsip = Ip(Need(boot, "server", "dns.servers[0]"), "dns.servers[0].server"); if (dnsip != Ip(Need(secure, "server", "dns.servers[1]"), "dns.servers[1].server")) throw Bad("dns.servers[1].server");
            var outs = List(Need(root, "outbounds", "outbounds"), "outbounds", 2, 9); var rebuilt = new List<object>(); var byTag = new Dictionary<string, Dictionary<string, object>>(StringComparer.Ordinal); string selected = null;
            for (int i = 0; i < outs.Length; i++) {
                string p = "outbounds[" + i + "]"; var raw = outs[i] as IDictionary; if (raw == null) throw Bad(p);
                if ((raw["type"] as string) == "selector") {
                    if (selected != null) throw Bad(p);
                    var s = Map(raw, p, "type", "tag", "outbounds", "default", "interrupt_exist_connections"); Exact(Need(s, "tag", p), "vpn-active", p + ".tag"); Exact(Need(s, "interrupt_exist_connections", p), false, p + ".interrupt_exist_connections");
                    selected = Str(List(Need(s, "outbounds", p), p + ".outbounds", 1, 1, true)[0], p + ".outbounds"); Exact(Need(s, "default", p), selected, p + ".default");
                } else { var d = Outbound(raw, p, iface); string tag = (string)d["tag"]; if (byTag.ContainsKey(tag)) throw Bad(p + ".tag"); byTag.Add(tag, d); rebuilt.Add(d); }
            }
            if (selected == null || byTag.Count > 8) throw Bad("outbounds");
            var seen = new HashSet<string>(StringComparer.Ordinal); string current = selected;
            while (current != null) { if (!byTag.ContainsKey(current) || !seen.Add(current) || seen.Count > 4) throw Bad("outbounds.detour"); var d = byTag[current]; current = d.ContainsKey("detour") ? (string)d["detour"] : null; }
            if (seen.Count != byTag.Count) throw Bad("outbounds.unreachable");
            rebuilt.Add(Obj("type", "selector", "tag", "vpn-active", "outbounds", new[] { selected }, "default", selected, "interrupt_exist_connections", false));
            return new VpnTunPlan { InterfaceName = name, DefaultInterface = iface, Selected = selected, Config = Obj(
                "log", Obj("disabled", true), "inbounds", new[] { Obj("type", "tun", "tag", "vpn-tun", "interface_name", name, "address", addresses, "stack", "system", "auto_route", true, "strict_route", false, "route_exclude_address", excludes) },
                "outbounds", rebuilt.ToArray(), "route", Obj("auto_detect_interface", true, "default_interface", iface, "default_domain_resolver", "bootstrap", "final", "vpn-active", "rules", new[] {
                    Obj("inbound", new[] { "vpn-tun" }, "network", "tcp", "port", ports, "ip_cidr", new[] { cidr }, "action", "route", "outbound", "vpn-active", "override_address", server, "override_port", port), Obj("protocol", "dns", "action", "hijack-dns") }),
                "dns", Obj("servers", new[] { Obj("type", "udp", "tag", "bootstrap", "server", dnsip, "bind_interface", iface), Obj("type", "https", "tag", "vpn-dns", "server", dnsip, "detour", "vpn-active") }, "final", "vpn-dns")) };
        }
    }
    internal sealed class VpnAce { public string Sid; public int Rights; public bool Allow; }
    internal static class VpnServiceAcl
    {
        public const string InstallDirectorySddl = "O:BAG:SYD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)";
        public const string RunDirectorySddl = "O:BAG:SYD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";
        public static void ValidateOwnerSid(string sid) { if (!Regex.IsMatch(sid ?? "", @"\A(?:S-1-5-21|S-1-12-1)-[0-9]+-[0-9]+-[0-9]+-[0-9]+\z")) throw new VpnPolicyException("owner-sid"); }
        public static string PipeSddl(string owner) { ValidateOwnerSid(owner); return "O:SYG:SYD:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x12019b;;;" + owner + ")"; }
        public static string ServiceSddl(string owner) { ValidateOwnerSid(owner); return "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)(A;;LCRP;;;" + owner + ")S:(AU;FA;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;WD)"; }
        public static bool IsProtectedAcl(IEnumerable<VpnAce> aces, out string reason)
        {
            const int writes = 0x2 | 0x4 | 0x10 | 0x40 | 0x100 | 0x10000 | 0x40000 | 0x80000 | 0x10000000 | 0x40000000;
            foreach (var ace in aces) if (ace.Allow && (ace.Rights & writes) != 0 && ace.Sid != "S-1-5-18" && ace.Sid != "S-1-5-32-544" && ace.Sid != "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464") { reason = "writable-acl"; return false; }
            reason = ""; return true;
        }
    }
    internal sealed class VpnOwnerInfo { public string OwnerSid, SingBoxSha256, ExeSha256; public int Protocol; }
    internal static class VpnServiceSetupPlan
    {
        public static string ServiceCommandLine(string installDir) { return "\"" + Path.Combine(installDir, VpnServiceNames.ExeName) + "\" --vpn-service"; }
        static string[] Configure(string verb, string dir) { return new[] { verb, VpnServiceNames.ServiceName, "binPath=", ServiceCommandLine(dir), "start=", "auto", "obj=", "LocalSystem", "DisplayName=", "RemoteAgents VPN (TUN)" }; }
        public static string[] CreateArguments(string dir) { return Configure("create", dir); }
        public static string[] ConfigArguments(string dir) { return Configure("config", dir); }
        public static string[] FailureArguments() { return new[] { "failure", VpnServiceNames.ServiceName, "reset=", "86400", "actions=", "restart/5000/restart/5000/restart/60000" }; }
        public static string[] SdsetArguments(string owner) { return new[] { "sdset", VpnServiceNames.ServiceName, VpnServiceAcl.ServiceSddl(owner) }; }
        public static string[] DescriptionArguments() { return new[] { "description", VpnServiceNames.ServiceName, "RemoteAgents VPN (TUN)" }; }
        public static string[] StopArguments() { return new[] { "stop", VpnServiceNames.ServiceName }; }
        public static string[] DeleteArguments() { return new[] { "delete", VpnServiceNames.ServiceName }; }
        internal static string HashValue(string value) { if (!Regex.IsMatch(value ?? "", @"\A[0-9a-fA-F]{64}\z")) throw new VpnPolicyException("bad-hash"); return value.ToLowerInvariant(); }
        internal static string Hash(byte[] bytes) { using (var sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant(); }
        public static string PinnedSingBoxSha256(string bundleBinariesJson)
        {
            var m = Json.Map(Json.Parse(bundleBinariesJson)); var matches = Json.Array(Json.Get(m, "binaries")).Select(Json.Map).Where(x => Json.Str(x, "target") == "transport/sing-box.exe").ToArray();
            if (matches.Length != 1) throw new VpnPolicyException("missing-binary"); return HashValue(Json.Str(matches[0], "memberSha256"));
        }
        public static byte[] ReadLimited(string path, long maxBytes)
        {
            long limit = Math.Min(maxBytes, 256L * 1024 * 1024); if (limit < 0) throw new VpnPolicyException("too-large");
            using (var f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) using (var output = new MemoryStream()) {
                if (f.Length > limit) throw new VpnPolicyException("too-large"); var buffer = new byte[65536]; int n;
                while ((n = f.Read(buffer, 0, buffer.Length)) != 0) { if (output.Length + n > limit) throw new VpnPolicyException("too-large"); output.Write(buffer, 0, n); } return output.ToArray();
            }
        }
        public static void CopyVerified(byte[] content, string expectedSha256, string targetDirectory, string fileName)
        {
            if (Hash(content) != HashValue(expectedSha256)) throw new VpnPolicyException("binary-mismatch");
            if (string.IsNullOrEmpty(fileName) || fileName == "." || fileName == ".." || fileName != Path.GetFileName(fileName) || fileName.IndexOfAny(new[] { '/', '\\', ':' }) >= 0) throw new VpnPolicyException("file-name");
            string temp = Path.Combine(targetDirectory, Guid.NewGuid().ToString("N") + ".tmp"), target = Path.Combine(targetDirectory, fileName);
            try { using (var f = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { f.Write(content, 0, content.Length); f.Flush(true); } if (File.Exists(target)) File.Replace(temp, target, null); else File.Move(temp, target); }
            finally { if (File.Exists(temp)) File.Delete(temp); }
        }
        public static string OwnerJson(string owner, string singBoxSha, string exeSha) { VpnServiceAcl.ValidateOwnerSid(owner); return Json.Encode(VpnServicePolicy.Obj("protocol", 1, "ownerSid", owner, "singBoxSha256", HashValue(singBoxSha), "exeSha256", HashValue(exeSha))); }
        public static VpnOwnerInfo ParseOwner(object json)
        {
            var m = VpnServicePolicy.Map(json, "owner", "protocol", "ownerSid", "singBoxSha256", "exeSha256");
            if (VpnServicePolicy.Number(VpnServicePolicy.Need(m, "protocol", "owner.protocol"), "owner.protocol", 0, int.MaxValue) != 1) throw new VpnPolicyException("bad-protocol");
            string sid = VpnServicePolicy.Str(VpnServicePolicy.Need(m, "ownerSid", "owner.ownerSid"), "owner.ownerSid"); VpnServiceAcl.ValidateOwnerSid(sid);
            return new VpnOwnerInfo { Protocol = 1, OwnerSid = sid, SingBoxSha256 = HashValue(Json.Str(m, "singBoxSha256")), ExeSha256 = HashValue(Json.Str(m, "exeSha256")) };
        }
    }
    internal interface IVpnProcessWatch : IDisposable { bool Alive { get; } }
    internal interface IVpnServiceHost
    {
        DateTime UtcNow { get; } string NewSession(); IVpnProcessWatch Watch(int pid); bool ProcessOwnedBy(int pid, string sid); bool InterfaceExists(string name); string InstalledSingBoxSha256();
        void CheckConfig(string configJson); void StartTun(string configJson); bool TunAlive { get; } bool StopTun(string interfaceName); void Log(string evt);
    }
    internal sealed class VpnServiceCore
    {
        readonly object gate = new object(); readonly IVpnServiceHost host; readonly VpnOwnerInfo owner; readonly string pinned;
        readonly List<IVpnProcessWatch> watches = new List<IVpnProcessWatch>(); string state = "off", session = "", iface = "", reason = ""; DateTime? deadline; bool shutdown;
        public VpnServiceCore(IVpnServiceHost host, VpnOwnerInfo owner, string pinnedSingBoxSha256) { this.host = host; this.owner = owner; pinned = VpnServiceSetupPlan.HashValue(pinnedSingBoxSha256); }
        string Error(string code) { return Json.Encode(VpnServicePolicy.Obj("ok", false, "protocol", 1, "error", code)); }
        string Status() { return Json.Encode(VpnServicePolicy.Obj("ok", true, "protocol", 1, "state", state, "session", session, "interface", iface, "deadlineSec", deadline.HasValue ? Math.Max(0, (int)Math.Ceiling((deadline.Value - host.UtcNow).TotalSeconds)) : 0, "reason", reason, "singBoxSha256", pinned)); }
        void Release() { foreach (var watch in watches) try { watch.Dispose(); } catch { } watches.Clear(); deadline = null; }
        bool Stop(string next, string why, bool clearSession = false)
        {
            bool clean = false; try { clean = host.StopTun(iface); } catch { }
            state = clean ? next : "cleanup-error"; reason = why; Release(); if (clearSession) session = "";
            try { host.Log(state + (why.Length > 0 ? "." + why : "")); } catch { } return clean;
        }
        public string Handle(string requestLine, int clientPid, string clientSid, bool clientIsAdmin)
        {
            lock (gate) {
                try {
                    if (clientSid != owner.OwnerSid && !clientIsAdmin) return Error("forbidden");
                    if (requestLine == null) return Error("bad-json");
                    if (Encoding.UTF8.GetByteCount(requestLine) > VpnServicePolicy.MaxRequestBytes) return Error("too-large");
                    object parsed; try { parsed = Json.Parse(requestLine); } catch { return Error("bad-json"); }
                    var r = VpnServicePolicy.ParseRequest(parsed);
                    if (r.Command == "status") return Status();
                    if (r.Command == "confirm") {
                        if (r.Session != session || session.Length == 0) return Error("session");
                        if (state != "starting" && state != "on") return Error("not-running");
                        state = "on"; deadline = null; return Status();
                    }
                    if (r.Command == "stop") { if (r.Session != null && r.Session != session) return Error("session"); Stop("off", "", true); return Status(); }
                    if (shutdown) return Error("not-running");
                    if (host.InstalledSingBoxSha256() != pinned) return Error("binary-mismatch");
                    var plan = VpnServicePolicy.BuildConfig(r.Config);
                    var pending = new List<IVpnProcessWatch>();
                    try {
                        var client = host.Watch(clientPid); if (client == null) return Error("watch-pid"); pending.Add(client);
                        if (r.WatchPid > 0) { var watch = host.Watch(r.WatchPid); if (watch == null) return Error("watch-pid"); pending.Add(watch); if (!host.ProcessOwnedBy(r.WatchPid, clientSid) || !watch.Alive) return Error("watch-pid"); }
                        if (!client.Alive) return Error("watch-pid");
                        if ((state == "starting" || state == "on" || state == "cleanup-error") && !Stop("off", "", true)) return Error("cleanup-error");
                        if (host.InterfaceExists(plan.InterfaceName)) return Error("interface-busy");
                        string json = Json.Encode(plan.Config);
                        try { host.CheckConfig(json); } catch { return Error("config-rejected"); }
                        iface = plan.InterfaceName;
                        try { host.StartTun(json); session = host.NewSession(); if (!Regex.IsMatch(session ?? "", @"\A[0-9a-f]{32}\z")) throw new VpnPolicyException("session"); }
                        catch { Stop("error", "start-failed", true); return Error("start-failed"); }
                        watches.AddRange(pending); pending.Clear(); state = "starting"; reason = ""; deadline = host.UtcNow.AddSeconds(VpnServiceNames.RollbackSeconds); return Status();
                    } finally { foreach (var w in pending) w.Dispose(); }
                } catch (VpnPolicyException ex) { return Error(ex.Code); } catch { return Error("internal-error"); }
            }
        }
        public void Tick()
        {
            lock (gate) {
                if (state != "starting" && state != "on") return;
                try { if (!host.TunAlive) Stop("error", "singbox-exited"); else if (watches.Any(w => !w.Alive)) Stop("off", "owner-exited"); else if (deadline.HasValue && host.UtcNow >= deadline.Value) Stop("rolled-back", "not-confirmed"); }
                catch { Stop("error", "host-error"); }
            }
        }
        public void Shutdown() { lock (gate) { shutdown = true; Stop("off", "shutdown", true); } }
    }
}
