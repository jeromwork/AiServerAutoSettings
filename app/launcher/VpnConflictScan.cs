using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace RemoteAgents.Launcher
{
    // Распознавание чужих VPN по снимку сети (адаптеры, маршруты, IP-интерфейсы, процессы, службы).
    // Правило: журналировать и показывать; чужое не отключаем; блокируем включение только при явном
    // чужом полном маршруте. Чистая логика, проверяется фикстурами tests/fixtures/logging/inventory-*.json.
    internal sealed class VpnConflictItem
    {
        internal string Name, Iface, Route, Why;
        internal int IfIndex, Metric;
    }
    internal sealed class VpnSuspectItem { internal string Name, Kind; }
    internal sealed class VpnConflictResult
    {
        internal readonly List<VpnConflictItem> Conflicts = new List<VpnConflictItem>();
        internal readonly List<VpnSuspectItem> Suspects = new List<VpnSuspectItem>();
        internal string Names { get { return string.Join(", ", Conflicts.Select(c => c.Name).Distinct()); } }
        internal string SuspectNames { get { return string.Join(", ", Suspects.Select(s => s.Name + ":" + s.Kind)); } }
        // Стабильный ключ набора — для записи в журнал только изменений.
        internal string Key { get { return string.Join("|", Conflicts.Select(c => "c:" + c.Name + "@" + c.Iface).Concat(Suspects.Select(s => "s:" + s.Name + ":" + s.Kind)).OrderBy(x => x, StringComparer.Ordinal)); } }
    }

    internal static class VpnConflict
    {
        static readonly string[] FullPrefixes = { "0.0.0.0/0", "::/0", "0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1" };
        // Метка и шаблон имени (процесс, служба, адаптер). Границы по буквам: «Happier» не равно «Happ».
        static readonly KeyValuePair<string, string>[] Known = {
            P("Happ", "happ|happd|happservice"), P("Xray", "xray"), P("V2Ray", "v2rayn?"), P("sing-box", "sing-box"), P("Clash", "clash[a-z]*"),
            P("Mihomo", "mihomo"), P("Hiddify", "hiddify"), P("NekoBox", "nekoray|nekobox"), P("Outline", "outline"), P("AmneziaVPN", "amnezia[a-z]*"),
            P("WireGuard", "wireguard"), P("OpenVPN", "openvpn[a-z]*"), P("TAP-Windows", "tap-windows"), P("ProtonVPN", "proton(?:vpn)?"),
            P("NordVPN", "nordvpn"), P("ExpressVPN", "expressvpn"), P("Windscribe", "windscribe"), P("Tailscale", "tailscaled?"),
            P("ZeroTier", "zerotier(?:one)?"), P("Radmin VPN", "radmin")
        };
        static KeyValuePair<string, string> P(string label, string pattern)
        { return new KeyValuePair<string, string>(label, "(?<![a-z])(?:" + pattern + ")(?![a-z])"); }
        static string Label(string text)
        {
            string lower = (text ?? "").ToLowerInvariant();
            foreach (var known in Known) if (Regex.IsMatch(lower, known.Value)) return known.Key;
            return null;
        }
        internal static string KnownLabel(string name) { return Label(name); }
        static bool Match(string text, string pattern) { return Regex.IsMatch(text ?? "", pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant); }
        static bool Own(string name) { return (name ?? "").StartsWith("RemoteAgents-", StringComparison.OrdinalIgnoreCase); }
        static bool Transition(string text) { return Match(text, "Teredo|ISATAP|6to4|IP-HTTPS"); }
        static bool Loopback(string text) { return Match(text, "Loopback"); }
        static bool VirtualAdapter(Dictionary<string, object> a)
        {
            string text = Json.Str(a, "Name") + " " + Json.Str(a, "InterfaceDescription");
            return Json.Get(a, "HardwareInterface") is bool && !Json.Bool(a, "HardwareInterface") || Json.Bool(a, "Virtual") || Match(text, "VPN|Tailscale|TUN|Wintun|WireGuard|TAP|virtual");
        }
        static string NameOf(object item) { var map = item as Dictionary<string, object>; return map == null ? Convert.ToString(item) : Json.Str(map, "Name"); }
        static string DisplayOf(object item) { var map = item as Dictionary<string, object>; return map == null ? "" : Json.Str(map, "DisplayName"); }
        static string PathOf(object item) { var map = item as Dictionary<string, object>; return map == null ? "" : Json.Str(map, "Path"); }
        // «happ-xray» (технический вид) -> «Happ»; «Happ TUN» (уже человеческое имя) остаётся как есть.
        static string Friendly(string label, string name)
        {
            if (label == null) return string.IsNullOrEmpty(name) ? "другой VPN" : name;
            bool technical = name == null || name.Length == 0 || (name == name.ToLowerInvariant() && name.IndexOf(' ') < 0);
            return technical ? label : name;
        }

        internal static VpnConflictResult Evaluate(Dictionary<string, object> snapshot, string ownDirectory = null)
        {
            var result = new VpnConflictResult();
            var adapters = Json.Array(Json.Get(snapshot, "Adapters")).Select(Json.Map).ToArray();
            var routes = Json.Array(Json.Get(snapshot, "Routes")).Select(Json.Map).ToArray();
            var ipOnly = Json.Array(Json.Get(snapshot, "IpInterfaces")).Select(Json.Map)
                .Where(i => !adapters.Any(a => Json.Int(a, "ifIndex", -1) == Json.Int(i, "InterfaceIndex", -2))).ToArray();
            var runningLabels = new List<KeyValuePair<string, string>>();
            foreach (var proc in Json.Array(Json.Get(snapshot, "Procs"))) {
                string name = NameOf(proc), label = Label(name);
                // Наше собственное ядро sing-box не считается чужим.
                if (label == null || (label == "sing-box" && ownDirectory != null && PathOf(proc).StartsWith(ownDirectory, StringComparison.OrdinalIgnoreCase))) continue;
                runningLabels.Add(new KeyValuePair<string, string>(label, "proc"));
            }
            foreach (var service in Json.Array(Json.Get(snapshot, "Services"))) {
                string label = Label(NameOf(service)) ?? Label(DisplayOf(service));
                if (label != null) runningLabels.Add(new KeyValuePair<string, string>(label, "service"));
            }
            var interfaces = new List<Dictionary<string, object>>();
            foreach (var a in adapters) {
                string name = Json.Str(a, "Name"), text = name + " " + Json.Str(a, "InterfaceDescription");
                if (!Json.Str(a, "Status").Equals("Up", StringComparison.OrdinalIgnoreCase) || Own(name) || Transition(text)) continue;
                interfaces.Add(new Dictionary<string, object> { { "name", name }, { "text", text }, { "ifIndex", Json.Int(a, "ifIndex", -1) }, { "virtual", VirtualAdapter(a) }, { "ipOnly", false } });
            }
            foreach (var i in ipOnly) {
                string name = Json.Str(i, "InterfaceAlias");
                if (Own(name) || Transition(name) || Loopback(name)) continue;
                interfaces.Add(new Dictionary<string, object> { { "name", name }, { "text", name }, { "ifIndex", Json.Int(i, "InterfaceIndex", -1) }, { "virtual", false }, { "ipOnly", true } });
            }
            var named = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var f in interfaces) {
                string name = (string)f["name"], text = (string)f["text"]; int index = (int)f["ifIndex"];
                bool virt = (bool)f["virtual"], only = (bool)f["ipOnly"];
                var mine = routes.Where(r => Json.Int(r, "InterfaceIndex", -1) == index).ToArray();
                var prefixes = mine.Select(r => Json.Str(r, "DestinationPrefix")).ToArray();
                bool v4pair = prefixes.Contains("0.0.0.0/1") && prefixes.Contains("128.0.0.0/1"), v6pair = prefixes.Contains("::/1") && prefixes.Contains("8000::/1");
                string route = prefixes.Contains("0.0.0.0/0") ? "0.0.0.0/0" : prefixes.Contains("::/0") ? "::/0" : v4pair ? "0.0.0.0/1+128.0.0.0/1" : v6pair ? "::/1+8000::/1" : "";
                bool full = route.Length > 0;
                bool partial = prefixes.Any(p => !FullPrefixes.Contains(p));
                var routeRow = mine.FirstOrDefault(r => FullPrefixes.Contains(Json.Str(r, "DestinationPrefix")));
                int metric = routeRow == null ? 0 : Json.Int(routeRow, "RouteMetric", 0);
                bool gateway = mine.Any(r => (Json.Str(r, "DestinationPrefix") == "0.0.0.0/0" || Json.Str(r, "DestinationPrefix") == "::/0") && !new[] { "", "0.0.0.0", "::" }.Contains(Json.Str(r, "NextHop")));
                string label = Label(text);
                string why = null;
                if (full && (virt || label != null || only || (runningLabels.Count > 0 && !gateway))) why = virt ? "virtual-full-route" : label != null ? "known-vpn-full-route" : only ? "ip-only-tunnel" : "vpn-process-without-gateway";
                // Неизвестный поднятый TUN без маршрута проверять нельзя: как раньше, закрываем включение.
                else if (Match(text, "TUN|Wintun|WireGuard|TAP") && !(partial && Match(text, "OpenVPN|WireGuard|Tailscale")) && !Match(text, "OpenVPN|Tailscale")) why = "tun-adapter";
                if (why != null) {
                    string friendly = Friendly(label ?? runningLabels.Select(r => r.Key).FirstOrDefault(), name);
                    // Имя берём от интерфейса, если процессы нашли другое имя, чем адаптер без метки.
                    if (label == null && !only && !virt) friendly = Friendly(null, name);
                    result.Conflicts.Add(new VpnConflictItem { Name = friendly, Iface = name, IfIndex = index, Route = route, Metric = metric, Why = why });
                    named.Add(label ?? friendly);
                } else if (label != null) {
                    if (named.Add(label)) result.Suspects.Add(new VpnSuspectItem { Name = label, Kind = "iface" });
                }
            }
            foreach (var running in runningLabels.GroupBy(r => r.Key + "|" + r.Value).Select(g => g.First())) {
                if (result.Conflicts.Any(c => c.Name == running.Key || Label(c.Iface) == running.Key)) continue;
                if (result.Suspects.Any(s => s.Name == running.Key && s.Kind == running.Value)) continue;
                result.Suspects.Add(new VpnSuspectItem { Name = running.Key, Kind = running.Value });
            }
            return result;
        }

        // Одна строка для журнала: что было в сети (до/после включения).
        internal static string[] Describe(Dictionary<string, object> snapshot)
        {
            var adapters = Json.Array(Json.Get(snapshot, "Adapters")).Select(Json.Map)
                .Select(a => Json.Str(a, "Name") + "[" + Json.Str(a, "ifIndex") + "," + (Json.Bool(a, "Virtual") ? "virt" : "phys") + "," + (Json.Bool(a, "HardwareInterface") ? "hw" : "nohw") + "," + Json.Str(a, "Status").ToLowerInvariant() + "]");
            var routes = Json.Array(Json.Get(snapshot, "Routes")).Select(Json.Map).Where(r => FullPrefixes.Contains(Json.Str(r, "DestinationPrefix")))
                .Select(r => Json.Str(r, "DestinationPrefix") + "@" + Json.Str(r, "InterfaceIndex") + "/" + Json.Str(r, "RouteMetric"));
            var dns = Json.Array(Json.Get(snapshot, "DnsServers")).Select(Json.Map).Where(d => Json.Strings(Json.Get(d, "ServerAddresses")).Length > 0)
                .Select(d => Json.Str(d, "InterfaceIndex") + ":" + string.Join(",", Json.Strings(Json.Get(d, "ServerAddresses"))));
            var procs = Json.Array(Json.Get(snapshot, "Procs")).Select(NameOf).Distinct();
            var services = Json.Array(Json.Get(snapshot, "Services")).Select(NameOf).Distinct();
            var ipOnly = Json.Array(Json.Get(snapshot, "IpInterfaces")).Select(Json.Map).Select(i => Json.Str(i, "InterfaceAlias") + "[" + Json.Str(i, "InterfaceIndex") + "]");
            return new[] { "adapters", string.Join("|", adapters), "fullroutes", string.Join("|", routes), "dns", string.Join("|", dns),
                "ipif", string.Join("|", ipOnly), "procs", string.Join(",", procs), "services", string.Join(",", services), "errors", string.Join(",", Json.Strings(Json.Get(snapshot, "errors"))) };
        }
    }
}
