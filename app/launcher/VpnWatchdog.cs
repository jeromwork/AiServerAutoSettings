using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace RemoteAgents.Launcher
{
    // Pure policy, shared by the host and portable tests. Scheduling uses Stopwatch;
    // wall clock is used only to reject stale/future transport evidence and resume gaps.
    internal sealed class VpnWatchdog
    {
        internal const int IntervalMs = 2000, ProbeTimeoutMs = 900, PollMs = 50;
        internal int Failures { get; private set; }
        internal bool Sample(bool transportOk, bool probeOk)
        { Failures = transportOk && probeOk ? 0 : Failures + 1; return Failures >= 2; }
        internal static bool TransportReady(Dictionary<string, object> status, DateTime now, string tag = null)
        {
            DateTime stamp;
            if (!Json.Bool(status, "ok") || !DateTime.TryParse(Json.Str(status, "updatedAt"), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out stamp)) return false;
            double age = (now - stamp.ToUniversalTime()).TotalSeconds;
            string active = Json.Str(status, "active");
            return age >= 0 && age <= 3 && active.Length > 0 && (tag == null || active == tag)
                && StatusView.Candidates(status).Any(c => Json.Str(c, "tag") == active && Json.Str(c, "state") == "ok" && Json.Bool(c, "enabled", true));
        }
        internal static string FailureSummary(string state)
        {
            switch (state) {
                case "server-unreachable": return "VPN выключен: сервер не отвечает";
                case "network-changed": return "VPN выключен: сеть изменилась";
                case "resumed": return "VPN выключен после сна: включите снова";
                case "watchdog-stalled": return "VPN выключен: проверка соединения остановилась";
                case "core-exited": return "VPN выключен: соединение прервано";
                case "conflict": return "Отключите другой VPN перед включением VPN RemoteAgents";
                case "no-path": return "VPN не включён: нет живого пути к серверу";
                case "rollback-error": return "Не удалось подтвердить выключение VPN. Откройте диагностику";
                case "error": return "VPN не включён: проверьте настройки и разрешение Windows";
                default: return "";
            }
        }
    }
}
