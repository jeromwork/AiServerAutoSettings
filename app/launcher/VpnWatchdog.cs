using System;
using System.Collections.Generic;
using System.Globalization;
using System.Diagnostics;
using System.Linq;

namespace RemoteAgents.Launcher
{
    // Transport evidence is status only; it never grants or revokes the core lifetime.
    internal sealed class VpnWatchdog
    {
        internal const string OwnerMutex = @"Global\RemoteAgents-VpnHost";
        internal const int ProbeTimeoutMs = 3000, PollMs = 50;
        // Только совместимость VpnStatus (W3): транспорт эту величину не читает.
        internal const int TransportStatusMaxAgeSec = 15;
        // Pure readiness policy; the process check is injectable and never reads file age.
        internal static bool TransportReady(Dictionary<string, object> status, Func<int, DateTime, bool> processAlive = null, string tag = null)
        { return TransportProblem(status, processAlive, tag).Length == 0; }
        internal static string TransportProblem(Dictionary<string, object> status, Func<int, DateTime, bool> processAlive = null, string tag = null)
        {
            int pid = Json.Int(status, "pid", 0);
            if (pid <= 0) return "old-daemon"; // Старый демон: нет идентификатора владельца статуса.
            DateTime started;
            if (!DateTime.TryParse(Json.Str(status, "startedAt"), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out started)
                || started.Kind == DateTimeKind.Unspecified) return "invalid-process-start";
            string active = Json.Str(status, "active");
            if (!Json.Bool(status, "ok") || active.Length == 0 || tag != null && active != tag
                || !StatusView.Candidates(status).Any(c => Json.Str(c, "tag") == active && Json.Str(c, "state") == "ok" && Json.Bool(c, "enabled"))) return "no-path";
            try { return (processAlive ?? ProcessAlive)(pid, started.ToUniversalTime()) ? "" : "daemon-exited"; }
            catch { return "daemon-exited"; }
        }
        internal static bool ProcessStartMatches(DateTime actual, DateTime expected)
        {
            // Допуск 2 с — точность округления времени старта процесса, а не ожидание готовности.
            return Math.Abs((actual.ToUniversalTime() - expected.ToUniversalTime()).TotalMilliseconds) <= 2000;
        }
        internal static bool ProcessAlive(int pid, DateTime started)
        {
            try { using (var process = Process.GetProcessById(pid)) return !process.HasExited && ProcessStartMatches(process.StartTime, started); }
            catch { return false; }
        }
        internal static string FailureSummary(string state, string stage = "")
        {
            switch (state) {
                case "server-unreachable": return "VPN выключен: сервер не отвечает";
                case "network-changed": return "VPN выключен: сеть изменилась";
                case "resumed": return "VPN выключен после сна: включите снова";
                case "watchdog-stalled": return "VPN выключен: служба перестала отвечать";
                case "searching": return "Нет связи, ищу путь";
                case "core-exited": return "VPN выключен: соединение прервано";
                case "conflict": return stage.Length == 0 ? "Отключите другой VPN перед включением VPN RemoteAgents" : "Сейчас работает " + stage + ". Отключите его, чтобы продолжить работу VPN RemoteAgents";
                case "no-udp": return "Текущий путь " + (stage.Length == 0 ? "к серверу" : stage) + " не передаёт UDP — выберите другой путь";
                case "no-path": return "VPN не включён: нет живого пути к серверу";
                case "rollback-error": return "Не удалось подтвердить выключение VPN. Откройте диагностику";
                case "uac-denied": return "Вы не подтвердили запрос Windows. Нажмите «Включить снова» и выберите «Да»";
                case "legacy-adapter": return "Остался адаптер прошлой версии VPN. Выполните предложенную очистку";
                case "prepare-timeout": return "Подготовка VPN заняла больше 30 секунд";
                case "exclusions-dns": return "Не удалось узнать адрес узла связи. Проверьте интернет";
                case "error":
                    if (VpnReasons.Known(stage)) return VpnReasons.Text(stage); // core-not-ready, route-not-ours (лестница) / routes-not-ours (помощник V3), e2e-fail, broke-*
                    return !string.IsNullOrEmpty(stage)
                        ? "VPN не включён: ошибка на шаге «" + stage + "». Скопируйте диагностику"
                        : "VPN не включён: проверьте настройки и разрешение Windows";
                default: return VpnReasons.Text(state);
            }
        }
    }
}
