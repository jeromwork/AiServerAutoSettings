using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Text.RegularExpressions;

namespace RemoteAgents.Launcher
{
    // Public share settings only; all networking and credentials remain in the existing channel.
    internal sealed class LanAccess
    {
        internal readonly List<string> Subnets = new List<string>(), Domains = new List<string>(), DnsServers = new List<string>();
        internal readonly List<Dictionary<string, object>> Networks = new List<Dictionary<string, object>>();
        internal readonly List<Dictionary<string, object>> Forwards = new List<Dictionary<string, object>>(); // Compatibility: always empty.
        internal string ProbeHost = ""; internal int ProbePort;
        internal bool Enabled { get { return Subnets.Count + Domains.Count > 0; } }
        internal static uint IPv4(string text)
        {
            if (!Regex.IsMatch(text, @"^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$")) throw new InvalidDataException("share: нужен IPv4");
            uint value = 0;
            foreach (string part in text.Split('.')) { uint n; if (!uint.TryParse(part, out n) || n > 255 || part.Length > 1 && part[0] == '0') throw new InvalidDataException("share: неверный IPv4"); value = (value << 8) | n; }
            return value;
        }
        internal static string[] Cidr(string text)
        {
            string[] parts = text.Split('/'); int bits;
            if (parts.Length != 2 || !int.TryParse(parts[1], out bits) || bits < 8 || bits > 32) throw new InvalidDataException("share.subnets: неверный CIDR");
            uint ip = IPv4(parts[0]), mask = uint.MaxValue << (32 - bits);
            bool priv = (ip >> 24) == 10 && bits >= 8 || (ip >> 20) == 0xac1 && bits >= 12 || (ip >> 16) == 0xc0a8 && bits >= 16;
            if (!priv || (ip & mask) != ip) throw new InvalidDataException("share.subnets: нужна каноническая подсеть RFC1918");
            string netmask = string.Join(".", new[]{mask >> 24, (mask >> 16) & 255, (mask >> 8) & 255, mask & 255});
            return new[]{parts[0], netmask};
        }
        internal static string Domain(string text)
        {
            string name = text.StartsWith("*.", StringComparison.Ordinal) ? text.Substring(2) : text;
            IPAddress ip;
            if (name.Length > 253 || name.IndexOf('.') < 0 || IPAddress.TryParse(name, out ip) || name.Split('.').Any(p => !Regex.IsMatch(p, @"^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$")))
                throw new InvalidDataException("share.domains: нужно DNS-имя или *.домен");
            return text.ToLowerInvariant();
        }
        internal const int MaxHosts = 100;
        // Explicit LAN host name for the hosts file: full name, no wildcard, under one of the network's domains.
        internal static string HostName(string text, IEnumerable<string> domains)
        {
            if (text.IndexOf('*') >= 0) throw new InvalidDataException("share.hosts: шаблоны с * не поддерживаются, укажите полные имена");
            string name = Domain(text);
            if (!domains.Any(d => { string root = d.TrimStart('*', '.').ToLowerInvariant(); return name == root || name.EndsWith("." + root, StringComparison.Ordinal); }))
                throw new InvalidDataException("share.hosts: имя " + text + " должно входить в share.domains этой сети");
            return name;
        }
        internal bool Allows(string host, int port)
        {
            if (Domains.Any(d => d.StartsWith("*.") ? host.EndsWith(d.Substring(1), StringComparison.OrdinalIgnoreCase) : host.Equals(d, StringComparison.OrdinalIgnoreCase))) return true;
            try { uint ip = IPv4(host); return Subnets.Any(s => { Cidr(s); var p = s.Split('/'); int bits = int.Parse(p[1]); return (ip & (uint.MaxValue << (32 - bits))) == IPv4(p[0]); }); } catch (InvalidDataException) { return false; }
        }
        static bool Contains(string subnet, uint ip)
        {
            Cidr(subnet); var p = subnet.Split('/'); int bits = int.Parse(p[1]);
            return (ip & (uint.MaxValue << (32 - bits))) == IPv4(p[0]);
        }
        internal static bool ClientOnly(Dictionary<string, object> lan)
        { return lan.ContainsKey("share") && !new[] { "ovpn", "auth", "password" }.Any(lan.ContainsKey); }
        internal static bool Active(Dictionary<string, object> lan)
        { var share = Json.Map(Json.Get(lan, "share")); return !ClientOnly(lan) || !share.ContainsKey("enabled") || Json.Bool(share, "enabled"); }
        internal static LanAccess Read(Dictionary<string, object> profile)
        {
            var result = new LanAccess();
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var lan in Json.Array(Json.Get(profile, "lan")).Select(Json.Map)) {
                if (!names.Add(Json.Str(lan, "name"))) throw new InvalidDataException("lan: имена сетей повторяются");
                var share = Json.Map(Json.Get(lan, "share"));
                var one = new LanAccess();
                foreach (string s in Json.Strings(Json.Get(share, "subnets"))) { Cidr(s); one.Subnets.Add(s); }
                foreach (string d in Json.Strings(Json.Get(share, "domains"))) one.Domains.Add(Domain(d));
                var dns = Json.Strings(Json.Get(share, "dnsServers"));
                if (dns.Length > 4) throw new InvalidDataException("share.dnsServers: не более 4 DNS-серверов");
                foreach (string server in dns) {
                    uint ip = IPv4(server);
                    if (!one.Subnets.Any(n => Contains(n, ip))) throw new InvalidDataException("share.dnsServers: DNS-сервер должен входить в share.subnets этой сети");
                    one.DnsServers.Add(server);
                }
                if (one.Domains.Count > 0 && one.DnsServers.Count == 0)
                    throw new InvalidDataException("Для доменов сети " + Json.Str(lan, "name") + " укажите share.dnsServers (DNS-серверы внутри ЛВС)");
                var hostsRaw = Json.Get(share, "hosts");
                if (hostsRaw != null && !(hostsRaw is System.Collections.IEnumerable) || hostsRaw is string) throw new InvalidDataException("share.hosts: нужен массив имён");
                var hostNames = Json.Strings(hostsRaw);
                if (hostNames.Length > MaxHosts) throw new InvalidDataException("share.hosts: не более " + MaxHosts + " имён");
                var hostList = new List<string>();
                foreach (string h in hostNames) {
                    string name = HostName(h, one.Domains);
                    if (hostList.Contains(name)) throw new InvalidDataException("share.hosts: имена повторяются");
                    hostList.Add(name);
                }
                if (hostList.Count > 0 && one.DnsServers.Count == 0) throw new InvalidDataException("Для share.hosts сети " + Json.Str(lan, "name") + " укажите share.dnsServers");
                if (!lan.ContainsKey("share")) continue;
                bool enabled = !share.ContainsKey("enabled") || Json.Bool(share, "enabled");
                if (share.ContainsKey("enabled") && !(share["enabled"] is bool)) throw new InvalidDataException("share.enabled: нужно true или false");
                string probe = Json.Text(lan, "testHost", Json.Str(lan, "host"));
                int port = Json.Int(lan, "testPort", Json.Int(lan, "port", 22));
                result.Networks.Add(new Dictionary<string, object> { { "name", Json.Str(lan, "name") }, { "subnets", one.Subnets.ToArray() },
                    { "domains", one.Domains.ToArray() }, { "dnsServers", one.DnsServers.ToArray() }, { "hosts", hostList.ToArray() }, { "testHost", probe }, { "testPort", port }, { "enabled", enabled } });
                // Deprecated forwards are deliberately not used as destinations or probes.
                if (!enabled) continue;
                if (!one.Enabled) continue;
                if (probe.Length == 0 || port < 1 || port > 65535 || !Regex.IsMatch(probe, @"^[a-zA-Z0-9][a-zA-Z0-9.-]*$") || !one.Allows(probe, port)) throw new InvalidDataException("lan.share: задайте testHost/testPort, разрешённый через share");
                if (result.ProbeHost.Length == 0) { result.ProbeHost = probe; result.ProbePort = port; }
                result.Subnets.AddRange(one.Subnets); result.Domains.AddRange(one.Domains); result.DnsServers.AddRange(one.DnsServers);
            }
            return result;
        }
    }
}
