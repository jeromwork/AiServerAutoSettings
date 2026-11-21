using System;
using System.Collections.Generic;
using System.Globalization;

namespace RemoteAgents.Launcher
{
    // Причины отказа VPN простыми словами для владельца (шаг V4). Коды те же в журнале, статусе и тексте.
    internal static class VpnReasons
    {
        internal const string CoreNotReady = "core-not-ready", RoutesNotOurs = "route-not-ours", E2eFail = "e2e-fail",
            BrokeTransport = "broke-transport", BrokeDisk = "broke-disk", BrokeBridge = "broke-bridge";

        internal static bool Known(string code)
        { return Text(code).Length > 0; }

        internal static string Text(string code)
        {
            switch (code) {
                case CoreNotReady: return "Ядро VPN не подтвердило запуск";
                case RoutesNotOurs: return "Трафик не пошёл через VPN (маршрут чужой)";
                case E2eFail: return "VPN выключен: проверка интернета через него не прошла";
                case BrokeTransport: return "VPN выключен: он нарушил связь с сервером (транспорт)";
                case BrokeDisk: return "VPN выключен: он нарушил работу Диска";
                case BrokeBridge: return "VPN выключен: он нарушил работу моста управления";
                default: return "";
            }
        }

        // Заметка в трее при автоматическом откате: только простые слова, сырой detail остаётся в журнале.
        internal static string RollbackNote(string reason, int stage)
        {
            string text = Text(reason);
            if (reason == E2eFail || reason == RoutesNotOurs) {
                string why = stage == 6 ? "трафик идёт мимо VPN" : stage == 7 ? "не определяются адреса сайтов" : stage == 8 ? "сайты не открываются" : "проверка не прошла";
                return "VPN выключен автоматически: интернет через него не шёл (" + why + "). Подробности в журнале.";
            }
            return (text.Length > 0 ? text : "VPN выключен автоматически") + ". Подробности в журнале.";
        }

        // Блок, который VPN не имеет права ронять, -> причина; пусто, если блок не наш предмет.
        internal static string ForBlock(string block)
        {
            switch (block) {
                case "transport": return BrokeTransport;
                case "disk": return BrokeDisk;
                case "control": return BrokeBridge;
                default: return "";
            }
        }
    }

    // Итог одной попытки включения (шаг V4): vpn.state on -> e2e -> итог; провал стадий 6-8, сбой транспорта/диска/моста
    // за время попытки -> один откат. Только события шины, таймеров нет. Вызовы действий — из потока шины/UI, под замком только состояние.
    internal sealed class VpnAttemptGuard : IDisposable
    {
        readonly object gate = new object();
        readonly Action<string> startE2E;
        readonly Action<string, int, string, string> rollback; // att, stage, reason, detail
        readonly Action<string, string[]> log;
        readonly Action<string> note;
        readonly EventBus bus;
        readonly List<IDisposable> subs = new List<IDisposable>();
        string att = ""; bool e2eStarted, rolledBack;

        internal VpnAttemptGuard(EventBus bus, Action<string> startE2E, Action<string, int, string, string> rollback, Action<string, string[]> log, Action<string> note)
        {
            this.bus = bus; this.startE2E = startE2E; this.rollback = rollback; this.log = log; this.note = note;
            subs.Add(bus.Subscribe(BusTopics.VpnState, OnVpnState));
            subs.Add(bus.Subscribe(BusTopics.NetE2E, OnE2E));
            subs.Add(bus.Subscribe(BusTopics.TransportStatus, OnTransport));
            subs.Add(bus.Subscribe(BusTopics.BlockFailed, e => OnBlock(e, true)));
            subs.Add(bus.Subscribe(BusTopics.BlockDegraded, e => OnBlock(e, false)));
        }

        internal bool Active { get { lock (gate) return att.Length > 0 && !rolledBack; } }

        // Нажали «Включить»: новая попытка (прежняя, если была, закрыта).
        internal void Begin(string attempt)
        {
            lock (gate) { att = attempt ?? ""; e2eStarted = rolledBack = false; }
            Log("vpn.attempt.begin", "att", attempt);
        }

        // Эту попытку уже откатывали (откат выключил VPN): intent=true писать нельзя.
        internal bool RolledBack(string attempt)
        { lock (gate) return att == attempt && rolledBack; }

        // Выключение кнопкой: текущая попытка больше не нужна, какой бы она ни была.
        internal void EndCurrent(string why)
        {
            string a; lock (gate) { a = att; att = ""; }
            if (a.Length > 0) Log("vpn.attempt.end", "att", a, "why", why);
        }

        // Попытка закончилась без e2e (отказ, ошибка): больше ничего не ждём.
        internal void End(string attempt, string why)
        {
            lock (gate) { if (att != attempt) return; att = ""; }
            Log("vpn.attempt.end", "att", attempt, "why", why);
        }

        // vpn.on.ok или vpn.state on — что пришло раньше; e2e запускается один раз на попытку.
        internal void VpnOn(string attempt)
        {
            lock (gate) { if (att != attempt || e2eStarted || rolledBack) return; e2eStarted = true; }
            Log("vpn.attempt.e2e-start", "att", attempt);
            startE2E(attempt);
        }

        void OnVpnState(BusEvent e)
        {
            string state = e.Get("state"), current;
            lock (gate) current = rolledBack ? "" : att;
            if (current.Length == 0) return;
            if (state == "on") { VpnOn(current); return; }
            if (state == "starting" || state == "searching") return;
            // off — это и снимок сохранённого состояния при подключении помощника (helper-start/button): не провал попытки.
            // Выключение кнопкой закрывает попытку явно (EndCurrent из DisableVpn).
            if (state == "off") { Log("vpn.attempt.state-off.ignored", "att", current, "reason", e.Get("reason")); return; }
            // off / error / conflict / ...: попытка не удалась, причина — простыми словами (если код известен).
            string reason = e.Get("reason"), text = VpnReasons.Text(reason);
            Log("vpn.attempt.failed", "att", current, "state", state, "reason", reason);
            if (text.Length > 0 && note != null) note(text);
            End(current, "state-" + state);
        }

        void OnE2E(BusEvent e)
        {
            string a = e.Get("att"), current;
            lock (gate) current = att;
            if (current.Length == 0 || a != current) { if (a.Length > 0) Log("vpn.attempt.e2e-stale", "att", a, "current", current); return; }
            string result = e.Get("result"); int stage;
            int.TryParse(e.Get("stage"), NumberStyles.Integer, CultureInfo.InvariantCulture, out stage);
            if (result == "fail" && stage >= 6 && stage <= 8) {
                string reason = e.Get("reason") == VpnReasons.RoutesNotOurs ? VpnReasons.RoutesNotOurs : VpnReasons.E2eFail;
                Rollback(current, stage, reason, e.Get("detail"));
                return;
            }
            // ok, пропуск (занято), ошибка пробы, провал стадии 9 (egress): на откат не влияет.
            Log("vpn.attempt.e2e-done", "att", current, "result", result, "stage", stage.ToString(CultureInfo.InvariantCulture));
            End(current, "e2e-" + result);
        }

        void OnTransport(BusEvent e)
        {
            // Сбой транспорта: ok=false или state=fail.
            bool bad = e.Get("ok") == "false" || e.Get("state") == "fail";
            if (!bad) return;
            string current; lock (gate) current = att;
            if (current.Length == 0) return;
            Rollback(current, 0, VpnReasons.BrokeTransport, e.Get("reason"));
        }

        void OnBlock(BusEvent e, bool failed)
        {
            string block = e.Get("block");
            // block.degraded важен только для транспорта (блок публикует «не готов» именно так); диск и мост — при block.failed.
            string reason = VpnReasons.ForBlock(block);
            if (reason.Length == 0 || !failed && block != "transport") return;
            string current; lock (gate) current = att;
            if (current.Length == 0) return;
            Rollback(current, 0, reason, e.Get("reason"));
        }

        // Один откат на попытку: повторные сигналы только в журнал.
        void Rollback(string current, int stage, string reason, string detail)
        {
            bool first;
            lock (gate) { first = att == current && !rolledBack; if (first) rolledBack = true; } // att остаётся: повторные сигналы этой попытки попадут в журнал как ignored
            if (!first) { Log("vpn.rollback.ignored", "att", current, "reason", reason, "note", "после отката"); return; }
            Log("vpn.rollback", "att", current, "stage", stage.ToString(CultureInfo.InvariantCulture), "reason", reason, "detail", detail);
            try { bus.Publish(BusTopics.VpnRollback, BusTopics.Sources.Tray, "att", current, "stage", stage.ToString(CultureInfo.InvariantCulture), "reason", reason); } catch { }
            if (note != null) note(VpnReasons.RollbackNote(reason, stage));
            rollback(current, stage, reason, detail);
        }

        void Log(string evt, params string[] kv)
        { try { if (log != null) log(evt, kv); } catch { } }

        public void Dispose()
        { foreach (var s in subs) try { s.Dispose(); } catch { } subs.Clear(); }
    }
}
