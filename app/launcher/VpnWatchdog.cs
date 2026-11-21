using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace RemoteAgents.Launcher
{
    // Transport evidence is status only; it never grants or revokes the core lifetime.
    internal sealed class VpnWatchdog
    {
        internal const string OwnerMutex = @"Global\RemoteAgents-VpnHost";
        internal const int ProbeTimeoutMs = 3000, PollMs = 50;
        internal static bool TransportReady(Dictionary<string, object> status, DateTime now, string tag = null)
        {
            DateTime stamp;
            if (!Json.Bool(status, "ok") || !DateTime.TryParse(Json.Str(status, "updatedAt"), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out stamp)) return false;
            double age = (now - stamp.ToUniversalTime()).TotalSeconds;
            string active = Json.Str(status, "active");
            return age >= 0 && age <= 3 && active.Length > 0 && (tag == null || active == tag)
                && StatusView.Candidates(status).Any(c => Json.Str(c, "tag") == active && Json.Str(c, "state") == "ok" && Json.Bool(c, "enabled", true));
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
                    if (VpnReasons.Known(stage)) return VpnReasons.Text(stage); // core-not-ready, routes-not-ours, e2e-fail, broke-*
                    return !string.IsNullOrEmpty(stage)
                        ? "VPN не включён: ошибка на шаге «" + stage + "». Скопируйте диагностику"
                        : "VPN не включён: проверьте настройки и разрешение Windows";
                default: return VpnReasons.Text(state);
            }
        }
    }
}
