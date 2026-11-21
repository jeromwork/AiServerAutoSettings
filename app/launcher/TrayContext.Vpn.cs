using System;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    // Итог попытки включения VPN на шине (шаг V4): vpn.state on -> e2e -> итог; провал стадий 6-8 или сбой транспорта/диска/моста
    // за попытку -> один откат (vpn.off). Логика — в VpnAttemptGuard; здесь только связка с трей-действиями. Таймеров нет.
    internal sealed partial class TrayContext
    {
        VpnAttemptGuard vpnGuard;

        void StartVpnGuard()
        {
            if (bus == null) return;
            vpnGuard = new VpnAttemptGuard(bus,
                att => { var l = ladder; if (l != null) l.RunE2E(att); else VpnAttemptEnd(att, "no-ladder"); },
                (att, stage, reason, detail) => PostUi(() => RollbackVpn(att, stage, reason, detail)),
                (evt, kv) => log.Write(evt.Contains("rollback") || evt.Contains("failed") ? LogLevel.Warn : LogLevel.Info, "vpn", evt, kv),
                text => { vpnError = text; PostUi(() => { if (!closing) RefreshMain(); }); });
            busParts.Add(vpnGuard);
        }

        void VpnAttemptBegin(string att) { var g = vpnGuard; if (g != null) g.Begin(att); }
        void VpnAttemptEnd(string att, string why) { var g = vpnGuard; if (g != null) g.End(att, why); }
        // Ответ vpn.on ok (или vpn.state on): e2e стартует один раз. Без шины — прежний прямой запуск.
        void VpnAttemptOn(string att)
        {
            var g = vpnGuard;
            if (g != null) g.VpnOn(att); else if (ladder != null) ladder.RunE2E(att);
        }

        // Помощник ответил не «on»: причина простыми словами — в журнал, в баннер и (для быстрой кнопки трея) в окно.
        void VpnRefused(string att, System.Collections.Generic.Dictionary<string, object> status, bool fromCard)
        {
            string state = Json.Str(status, "state"), stage = Json.Str(status, "stage");
            string why = VpnRefusalText(status);
            log.Write(LogLevel.Warn, "vpn", "vpn.on.refused", "att", att, "state", state, "stage", stage, "text", MainScreenModel.CleanSecrets(why));
            VpnAttemptEnd(att, "refused-" + state);
            vpnError = why;
            if (!fromCard) MessageBox.Show(why, Product.Name);
        }

        internal static string VpnRefusalText(System.Collections.Generic.Dictionary<string, object> status)
        {
            string text = Json.Str(status, "summary");
            if (text.Length == 0) text = VpnWatchdog.FailureSummary(Json.Str(status, "state"), Json.Str(status, "stage"));
            return text.Length > 0 ? text : "VPN не включён: соединение не подтверждено";
        }

        // Автоматический откат: тот же путь, что кнопка «Выключить», но без окна занятости. Каждый шаг — в журнал сразу.
        async void RollbackVpn(string att, int stage, string reason, string detail)
        {
            var watch = System.Diagnostics.Stopwatch.StartNew();
            log.Write(LogLevel.Warn, "vpn", "vpn.rollback.start", "att", att, "stage", stage.ToString(), "reason", reason, "detail", MainScreenModel.CleanSecrets(detail ?? ""));
            if (closing) { log.Write("vpn.rollback.skipped att=" + att + " msg=closing"); return; }
            vpnActionWanted = false;
            try {
                if (netHelper == null) throw new System.IO.IOException(HelperClient.PermissionRequired);
                await netHelper.VpnOff();
                log.Write("vpn.rollback.off.ok att=" + att + " reason=" + reason + " ms=" + watch.ElapsedMilliseconds);
                var vpn = runtimes.FirstOrDefault(r => r.Definition.Name == "vpn");
                config.SetVpnIntent(false); if (vpn != null) config.SetEnabled(vpn.Definition, false);
                if (mirror != null) Task.Run(() => { try { mirror.Pull(); } catch { } });
                LogNetSnapshot("vpn.rollback.after", att);
            } catch (Exception error) {
                log.Write("vpn.rollback.failed att=" + att + " reason=" + reason + " " + TickFailureLog.HelperFailure("vpn-off", error));
                vpnError = "VPN не удалось выключить автоматически. Выключите его кнопкой в трее и откройте журналы.";
            } finally { if (!closing) { RefreshMenu(); RefreshMain(); } }
        }
    }
}
