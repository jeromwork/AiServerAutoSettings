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
        internal readonly List<string> Subnets = new List<string>(), Domains = new List<string>();
        internal readonly List<Dictionary<string, object>> Forwards = new List<Dictionary<string, object>>();
        internal string ProbeHost = ""; internal int ProbePort;
        internal bool Enabled { get { return Subnets.Count + Domains.Count + Forwards.Count > 0; } }
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
        internal bool Allows(string host, int port)
        {
            if (Forwards.Any(f => Json.Str(f, "host").Equals(host, StringComparison.OrdinalIgnoreCase) && Json.Int(f, "port", 0) == port)) return true;
            if (Domains.Any(d => d.StartsWith("*.") ? host.EndsWith(d.Substring(1), StringComparison.OrdinalIgnoreCase) : host.Equals(d, StringComparison.OrdinalIgnoreCase))) return true;
            try { uint ip = IPv4(host); return Subnets.Any(s => { Cidr(s); var p = s.Split('/'); int bits = int.Parse(p[1]); return (ip & (uint.MaxValue << (32 - bits))) == IPv4(p[0]); }); } catch (InvalidDataException) { return false; }
        }
        internal static LanAccess Read(Dictionary<string, object> profile)
        {
            var result = new LanAccess();
            foreach (var lan in Json.Array(Json.Get(profile, "lan")).Select(Json.Map)) {
                var share = Json.Map(Json.Get(lan, "share"));
                var one = new LanAccess();
                foreach (string s in Json.Strings(Json.Get(share, "subnets"))) { Cidr(s); one.Subnets.Add(s); }
                foreach (string d in Json.Strings(Json.Get(share, "domains"))) one.Domains.Add(Domain(d));
                var names = new HashSet<string>();
                foreach (var f in Json.Array(Json.Get(share, "forwards")).Select(Json.Map)) {
                    if (!names.Add(Json.Str(f, "name"))) throw new InvalidDataException("share.forwards: имена повторяются");
                    string host = Json.Str(f, "host"); IPAddress ip;
                    if (IPAddress.TryParse(host, out ip)) { IPv4(host); Cidr(host + "/32"); }
                    else { Domain(host); if (host.StartsWith("*.")) throw new InvalidDataException("forward.host: нужен точный хост"); }
                    one.Forwards.Add(f);
                }
                if (!one.Enabled) continue;
                string probe = Json.Text(lan, "testHost", Json.Str(lan, "host"));
                int port = Json.Int(lan, "testPort", Json.Int(lan, "port", 22));
                if (probe.Length == 0 && one.Forwards.Count > 0) { probe = Json.Str(one.Forwards[0], "host"); port = Json.Int(one.Forwards[0], "port", 0); }
                if (probe.Length == 0 || port < 1 || port > 65535 || !Regex.IsMatch(probe, @"^[a-zA-Z0-9][a-zA-Z0-9.-]*$") || !one.Allows(probe, port)) throw new InvalidDataException("lan.share: задайте testHost/testPort, разрешённый через share (или первый forward)");
                if (result.ProbeHost.Length == 0) { result.ProbeHost = probe; result.ProbePort = port; }
                result.Subnets.AddRange(one.Subnets); result.Domains.AddRange(one.Domains); result.Forwards.AddRange(one.Forwards);
            }
            return result;
        }
        internal string Pac(int port)
        {
            if (port < 1 || port > 65535) throw new ArgumentOutOfRangeException("port");
            var conditions = new List<string>();
            // IPv4 literals only: PAC must never ask the computer's DNS for internal names.
            foreach (string s in Subnets.Distinct()) { var c = Cidr(s); conditions.Add("(v4 && isInNet(host," + Json.Encode(c[0]) + "," + Json.Encode(c[1]) + "))"); }
            foreach (string d in Domains.Distinct()) conditions.Add(d.StartsWith("*.") ? "shExpMatch(host," + Json.Encode(d) + ")" : "host===" + Json.Encode(d));
            // A forward grants only host:port, not the host's other browser ports.
            foreach (var f in Forwards) conditions.Add("(host===" + Json.Encode(Json.Str(f, "host").ToLowerInvariant()) + " && p===" + Json.Int(f, "port", 0) + ")");
            return "function FindProxyForURL(url,host){host=host.toLowerCase();var v4=/^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$/.test(host);" +
                "var m=/^[a-z]+:\\/\\/[^\\/]+:(\\d+)(?:\\/|$)/i.exec(url);var p=m?parseInt(m[1],10):(url.indexOf('https:')===0?443:80);" +
                "if(" + (conditions.Count == 0 ? "false" : string.Join(" || ", conditions)) + ")return 'PROXY 127.0.0.1:" + port + "';return 'DIRECT';}\n";
        }
    }
}
