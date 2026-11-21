using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net.NetworkInformation;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace RemoteAgents.Launcher
{
    // A snapshot seam: tests provide profiles; production reads Windows only on network events.
    internal sealed class NetClassProfile
    {
        internal string Id = "", CostType = "Unknown";
        internal int IfIndex;
        internal NetworkInterfaceType AdapterType;
        internal bool Wwan, Wlan, Metered, Roaming, ApproachingDataLimit, OverDataLimit;
    }

    internal static class NetClass
    {
        internal static string Classify(NetClassProfile p)
        {
            if (p == null) return "unknown";
            if (p.Wwan || p.AdapterType == NetworkInterfaceType.Wwanpp || p.AdapterType == NetworkInterfaceType.Wwanpp2) return "mobile";
            if (p.Wlan || p.AdapterType == NetworkInterfaceType.Wireless80211)
                return p.Metered || p.CostType == "Fixed" || p.CostType == "Variable" || p.Roaming || p.ApproachingDataLimit || p.OverDataLimit ? "mobile-hotspot" : "wifi";
            return p.AdapterType == NetworkInterfaceType.Ethernet || p.AdapterType == NetworkInterfaceType.GigabitEthernet ||
                p.AdapterType == NetworkInterfaceType.FastEthernetFx || p.AdapterType == NetworkInterfaceType.FastEthernetT ? "fixed" : "unknown";
        }

        [DllImport("iphlpapi.dll")] static extern uint GetIpForwardTable(IntPtr table, ref int size, bool order);
        // MIB_IPFORWARDROW has 14 DWORD fields; metric1 includes the interface metric.
        static int DefaultInterface(HashSet<int> physical)
        {
            int size = 0;
            if (GetIpForwardTable(IntPtr.Zero, ref size, false) != 122 || size < 4) return -1;
            var data = Marshal.AllocHGlobal(size);
            try {
                if (GetIpForwardTable(data, ref size, false) != 0) return -1;
                int count = Marshal.ReadInt32(data), best = -1; uint metric = uint.MaxValue;
                for (int i = 0; i < count && 4L + (i + 1L) * 56 <= size; i++) {
                    var row = IntPtr.Add(data, 4 + i * 56);
                    int index = Marshal.ReadInt32(row, 16);
                    uint cost = unchecked((uint)Marshal.ReadInt32(row, 36));
                    if (Marshal.ReadInt32(row) == 0 && Marshal.ReadInt32(row, 4) == 0 && physical.Contains(index) && cost < metric) { best = index; metric = cost; }
                }
                return best;
            } finally { Marshal.FreeHGlobal(data); }
        }
        static object Property(object value, string name) { return value == null ? null : value.GetType().GetProperty(name)?.GetValue(value, null); }
        static bool Flag(object value, string name) { return true.Equals(Property(value, name)); }
        static string Fingerprint(string text)
        {
            using (var sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(text))).Replace("-", "").ToLowerInvariant();
        }
        internal static bool IsOwnTun(string name)
        {
            return string.Equals(name, VpnTun.InterfaceName, StringComparison.OrdinalIgnoreCase) ||
                string.Equals(name, LanTun.InterfaceName, StringComparison.OrdinalIgnoreCase);
        }
        internal static NetClassProfile ReadWindows()
        {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT) return null;
            try {
                var adapters = new Dictionary<int, NetworkInterface>();
                foreach (var n in NetworkInterface.GetAllNetworkInterfaces()) {
                    if (IsOwnTun(n.Name) || n.OperationalStatus != OperationalStatus.Up || Classify(new NetClassProfile { AdapterType = n.NetworkInterfaceType }) == "unknown") continue;
                    string desc = (n.Name + " " + n.Description).ToLowerInvariant();
                    if (new[] { "wintun", "tailscale", "openvpn", "hyper-v", "happ", "tunnel", "tap-" }.Any(desc.Contains)) continue;
                    try { adapters[n.GetIPProperties().GetIPv4Properties().Index] = n; } catch { }
                }
                int index = DefaultInterface(new HashSet<int>(adapters.Keys));
                NetworkInterface adapter;
                if (!adapters.TryGetValue(index, out adapter)) return null;
                var p = new NetClassProfile { IfIndex = index, AdapterType = adapter.NetworkInterfaceType };
                string profileName = "";
                // Late binding keeps the launcher net48/portable build free of a WinRT SDK dependency.
                try {
                    var type = Type.GetType("Windows.Networking.Connectivity.NetworkInformation, Windows, ContentType=WindowsRuntime", false);
                    var profiles = type?.GetMethod("GetConnectionProfiles", BindingFlags.Public | BindingFlags.Static)?.Invoke(null, null) as System.Collections.IEnumerable;
                    if (profiles != null) foreach (var profile in profiles) {
                        var netAdapter = Property(profile, "NetworkAdapter");
                        if (!string.Equals(Convert.ToString(Property(netAdapter, "NetworkAdapterId"), CultureInfo.InvariantCulture), adapter.Id.Trim('{', '}'), StringComparison.OrdinalIgnoreCase)) continue;
                        p.Wwan = Flag(profile, "IsWwanConnectionProfile"); p.Wlan = Flag(profile, "IsWlanConnectionProfile");
                        profileName = Convert.ToString(Property(profile, "ProfileName"), CultureInfo.InvariantCulture);
                        var cost = profile.GetType().GetMethod("GetConnectionCost")?.Invoke(profile, null);
                        p.CostType = Convert.ToString(Property(cost, "NetworkCostType"), CultureInfo.InvariantCulture);
                        p.Roaming = Flag(cost, "Roaming"); p.ApproachingDataLimit = Flag(cost, "ApproachingDataLimit"); p.OverDataLimit = Flag(cost, "OverDataLimit");
                        p.Metered = p.CostType == "Fixed" || p.CostType == "Variable";
                        break;
                    }
                } catch { } // Adapter classification remains available if WinRT is unavailable.
                string gateways = string.Join(",", adapter.GetIPProperties().GatewayAddresses.Select(g => g.Address.ToString()).OrderBy(s => s, StringComparer.Ordinal));
                p.Id = Fingerprint(adapter.Id + "\n" + gateways + "\n" + profileName);
                return p;
            } catch { return null; }
        }
    }

    internal sealed class NetClassPublisher : IDisposable
    {
        readonly EventBus bus;
        readonly Func<NetClassProfile> read;
        readonly Action<Action> queueWork;
        readonly IDisposable subscription;
        readonly object gate = new object();
        bool running, dirty, replay, disposed;
        string pendingId = "", lastId = "", lastClass = "";
        readonly Dictionary<string, string> canonicalIds = new Dictionary<string, string>(StringComparer.Ordinal);
        internal NetClassPublisher(EventBus bus, Func<NetClassProfile> read = null, Action<Action> queueWork = null)
        {
            this.bus = bus; this.read = read ?? NetClass.ReadWindows;
            this.queueWork = queueWork ?? (work => ThreadPool.QueueUserWorkItem(_ => work()));
            subscription = bus.Subscribe("*", OnEvent);
        }
        void OnEvent(BusEvent e)
        {
            if (e.Topic == BusTopics.NetChange && e.Get("classifier") == "q") return;
            if (e.Topic != BusTopics.WinIfaceChanged && e.Topic != BusTopics.WinRouteChanged && e.Topic != BusTopics.WinAddrChanged && e.Topic != BusTopics.NetChange && e.Topic != BusTopics.TransportReady) return;
            lock (gate) {
                if (disposed) return;
                dirty = true;
                replay |= e.Topic == BusTopics.TransportReady;
                // Coalesce bursts in one slot, retaining the latest explicit network identity.
                if (e.Topic == BusTopics.NetChange && e.Get("id").Length > 0) pendingId = e.Get("id");
                if (running) return;
                running = true;
            }
            queueWork(Refresh);
        }
        void Refresh()
        {
            while (true) {
                string requestedId; bool force;
                lock (gate) {
                    if (disposed || !dirty) { running = false; return; }
                    dirty = false; requestedId = pendingId; pendingId = ""; force = replay; replay = false;
                }
                // Windows/WinRT may block: never read in the EventBus dispatch thread.
                NetClassProfile p;
                try { p = read(); } catch { p = null; }
                lock (gate) {
                    if (disposed) { running = false; return; }
                    string physicalId = p?.Id ?? "", id = physicalId;
                    if (requestedId.Length > 0) {
                        id = requestedId;
                        if (physicalId.Length > 0) {
                            if (canonicalIds.Count >= 32 && !canonicalIds.ContainsKey(physicalId)) canonicalIds.Clear();
                            canonicalIds[physicalId] = id;
                        }
                    } else {
                        string canonical; if (canonicalIds.TryGetValue(physicalId, out canonical)) id = canonical;
                    }
                    string cls = NetClass.Classify(p);
                    if (!force && id == lastId && cls == lastClass) continue;
                    lastId = id; lastClass = cls;
                    bus.Publish(BusTopics.NetChange, BusTopics.Sources.Tray, "id", id, "class", cls, "ifIndex", (p?.IfIndex ?? 0).ToString(CultureInfo.InvariantCulture), "classifier", "q");
                }
            }
        }
        public void Dispose()
        {
            lock (gate) { disposed = true; dirty = false; pendingId = ""; canonicalIds.Clear(); }
            subscription.Dispose();
        }
    }
}
