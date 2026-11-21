using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;

namespace RemoteAgents.Launcher
{
    internal static class VpnStatus
    {
        internal static string DnsSummary(Dictionary<string, object> status)
        {
            var policy = Json.Map(Json.Get(status, "dnsPolicy"));
            if (!Json.Bool(status, "enabled") || Json.Get(policy, "strictRoute") == null || Json.Bool(policy, "strictRoute")) return "";
            return "DNS: защита частичная из-за " + string.Join(", ", Json.Array(Json.Get(policy, "networks")).Select(n => Json.Str(Json.Map(n), "name")).Distinct());
        }
        internal static string DnsDetail(Dictionary<string, object> status)
        {
            var policy = Json.Map(Json.Get(status, "dnsPolicy"));
            if (!Json.Bool(status, "enabled") || Json.Get(policy, "strictRoute") == null) return "";
            if (Json.Bool(policy, "strictRoute")) return "DNS: strict_route=true. WFP блокирует DNS вне TUN; перехваченные запросы идут через DoH.";
            var text = new StringBuilder(DnsSummary(status));
            text.AppendLine(". strict_route=false: сохранён DNS частичных сетей. Windows может принять ответ другого адаптера в обход DoH.");
            foreach (var item in Json.Array(Json.Get(policy, "networks"))) {
                var network = Json.Map(item);
                text.AppendLine(Json.Str(network, "name") + " (ifIndex " + Json.Str(network, "interfaceIndex") + ")");
                text.AppendLine("  DNS-серверы: " + string.Join(", ", Json.Strings(Json.Get(network, "servers"))));
                text.AppendLine("  DNS-суффиксы: " + string.Join(", ", Json.Strings(Json.Get(network, "suffixes"))));
                foreach (var rule in Json.Array(Json.Get(network, "nrpt"))) {
                    var nrpt = Json.Map(rule);
                    text.AppendLine("  Эффективная NRPT (владелец не определён): " + string.Join(", ", Json.Strings(Json.Get(nrpt, "namespaces"))) + " → " + string.Join(", ", Json.Strings(Json.Get(nrpt, "servers"))));
                }
            }
            return text.ToString().TrimEnd();
        }
        // Terminal results are events, not health heartbeats. Keep the reason
        // until the next explicit action; both tray and card read this same file.
        internal static Dictionary<string, object> Read(string home, DateTime? utcNow = null)
        {
            DateTime now = utcNow ?? DateTime.UtcNow;
            try {
                var status = Json.Read(Path.Combine(home, "status/vpn.json"));
                if (!Json.Bool(status, "enabled")) return status;
                if (Json.Str(status, "owner") == "net-helper") {
                    DateTime updated;
                    if (DateTime.TryParse(Json.Str(status, "updatedAt"), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out updated)) {
                        double age = (now - updated.ToUniversalTime()).TotalSeconds;
                        if (age >= 0 && age <= VpnWatchdog.TransportStatusMaxAgeSec) return status;
                    }
                    // File age cannot prove that the service or its core stopped (a long
                    // LAN request can delay publication). Keep the last enabled intent.
                    var stale = new Dictionary<string, object>(status);
                    stale["ok"] = false; stale["statusStale"] = true;
                    stale["summary"] = "Статус VPN устарел: помощник не отвечает";
                    return stale;
                }
                if (Json.Str(status, "state") == "awaiting-uac") {
                    // No host exists yet during UAC. Tie the pending action to the
                    // launcher's identity, so killing it cannot lock the next launch forever.
                    if (!File.Exists(Path.Combine(home, "state/vpn.stop")) && IdentityAlive(home, "state/vpn-session.json")) return status;
                    Files.Atomic(Path.Combine(home, "state/vpn.stop"), "stop\n");
                    status = new Dictionary<string, object> { { "ok", false }, { "enabled", false }, { "state", "off" }, { "summary", "VPN выключен" }, { "stage", "" }, { "errorType", "" }, { "updatedAt", now.ToString("o") } };
                    Files.Atomic(Path.Combine(home, "status/vpn.json"), Json.Encode(status)); return status;
                }
                bool alive = IdentityAlive(home, "state/vpn-host.json"); DateTime stamp;
                if (alive && DateTime.TryParse(Json.Str(status, "updatedAt"), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out stamp)) {
                    double age = (now - stamp.ToUniversalTime()).TotalSeconds;
                    if (age >= 0 && age <= VpnWatchdog.TransportStatusMaxAgeSec) return status;
                }
                string state = alive ? "watchdog-stalled" : "core-exited";
                // The host's independent lease has already closed the core Job at 2.5 s.
                // Also request host exit when it returns from a stalled system call.
                Files.Atomic(Path.Combine(home, "state/vpn.stop"), "stop\n");
                status = new Dictionary<string, object> { { "ok", false }, { "enabled", false }, { "state", state }, { "summary", VpnWatchdog.FailureSummary(state) }, { "stage", "" }, { "errorType", "" }, { "updatedAt", now.ToString("o") } };
                Files.Atomic(Path.Combine(home, "status/vpn.json"), Json.Encode(status)); return status;
            } catch { return Json.Map(null); }
        }
        static bool IdentityAlive(string home, string receipt)
        {
            try {
                var owner = Json.Read(Path.Combine(home, receipt));
                using (var process = Process.GetProcessById(Json.Int(owner, "pid", 0)))
                    // net48 HasExited opens PROCESS_QUERY_INFORMATION, denied across UAC.
                    // WaitForExit(0) needs SYNCHRONIZE; StartTime uses QUERY_LIMITED_INFORMATION.
                    return !process.WaitForExit(0) && process.StartTime.ToUniversalTime().Ticks.ToString(CultureInfo.InvariantCulture) == Json.Str(owner, "startedTicks");
            } catch { return false; }
        }
    }
}
