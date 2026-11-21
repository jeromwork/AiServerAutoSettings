using System;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;

namespace RemoteAgents.Launcher
{
    // Факт маршрута: какой адаптер Windows выберет для адреса (V3, vpn-events-plan 1.4). Без повторов и опроса:
    // перепроверку запускают уведомления Windows (win.route.changed / win.iface.changed), см. VpnReadyGate.AwaitRoute.
    internal static class NetRoute
    {
        [DllImport("iphlpapi.dll")] static extern uint GetBestInterface(uint destination, out uint index);

        // Индекс лучшего интерфейса для IPv4-адреса; -1, если Windows не ответила.
        internal static int BestInterface(IPAddress address)
        {
            try {
                uint index;
                if (address == null || address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork) return -1;
                return GetBestInterface(BitConverter.ToUInt32(address.GetAddressBytes(), 0), out index) == 0 ? (int)index : -1;
            } catch { return -1; }
        }
        // ifIndex адаптера по имени (IPv4); -1, если адаптера нет.
        internal static int IndexByName(string name)
        {
            try {
                foreach (var n in NetworkInterface.GetAllNetworkInterfaces())
                    try { if (string.Equals(n.Name, name, StringComparison.OrdinalIgnoreCase)) return n.GetIPProperties().GetIPv4Properties().Index; } catch { }
            } catch { }
            return -1;
        }
        internal static string NameOf(int index)
        {
            try {
                return NetworkInterface.GetAllNetworkInterfaces().Where(n => { try { return n.GetIPProperties().GetIPv4Properties().Index == index; } catch { return false; } })
                    .Select(n => n.Name).FirstOrDefault() ?? "";
            } catch { return ""; }
        }
    }

    // Результат одной проверки маршрута на TUN.
    internal sealed class VpnRouteResult
    {
        internal int TunIf, Best1111, BestProbe;
        internal string Best1111Name = "", BestProbeName = "";
        internal bool Ok { get { return TunIf > 0 && Best1111 == TunIf && BestProbe == TunIf; } }
        internal string[] Fields() { return new[] { "tunIf", TunIf.ToString(System.Globalization.CultureInfo.InvariantCulture), "best1111", Best1111 + ":" + Best1111Name, "bestProbe", BestProbe + ":" + BestProbeName }; }
        internal string Describe() { return "tunIf=" + TunIf + " best1111=" + Best1111 + ":" + Best1111Name + " bestProbe=" + BestProbe + ":" + BestProbeName; }
    }
}
